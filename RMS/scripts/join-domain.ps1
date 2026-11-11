$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:ProgramData 'OCI-ADJoin'
$config = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$stateFile = Join-Path $root 'progress.json'
$statusFile = Join-Path $root 'status.json'
$taskName = 'OCI-ADJoin'

function Write-Status([string]$State, [string]$Stage) {
    @{ state = $State; stage = $Stage; updated_utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content $statusFile -Encoding UTF8
}
function Stop-JoinTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Save-Progress {
    $script:progress | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
}

$stage = 'initialization'
try {
    if (Test-Path $stateFile) {
        $script:progress = Get-Content $stateFile -Raw | ConvertFrom-Json
    } else {
        $script:progress = [pscustomobject]@{
            deadline = [DateTime]::UtcNow.AddHours(6).ToString('o')
            attempts = 0
            pending_boot = ''
        }
        Save-Progress
    }
    if ([DateTime]::UtcNow -gt [DateTime]::Parse($progress.deadline).ToUniversalTime() -or $progress.attempts -ge 72) {
        Write-Status 'failed' 'retry-window-expired'
        Stop-JoinTask
        exit 1
    }
    $progress.attempts++
    Save-Progress

    # Never reboot while the cloud initialization service is still executing.
    $cloudbase = Get-Service -Name 'cloudbase-init*' -ErrorAction SilentlyContinue
    if (@($cloudbase | Where-Object { $_.Status -eq 'Running' }).Count -gt 0) {
        Write-Status 'waiting' 'cloudbase-init'
        exit 0
    }

    $computer = Get-CimInstance Win32_ComputerSystem
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    if ($progress.pending_boot -eq $boot) {
        Write-Status 'joined_pending_reboot' 'reboot'
        & shutdown.exe /r /t 60 /d p:2:4 /c 'Complete OCI Active Directory join'
        exit 0
    }
    if ($computer.PartOfDomain) {
        if ($computer.Domain -ine $config.domain -or $env:COMPUTERNAME -ine $config.computer_name) {
            Write-Status 'failed' 'existing-membership-or-name-mismatch'
            Stop-JoinTask
            exit 1
        }
        $stage = 'secure-channel-verification'
        if (-not (Test-ComputerSecureChannel -ErrorAction Stop)) { throw 'Secure channel unavailable' }
        Write-Status 'complete' 'verified-after-reboot'
        Stop-JoinTask
        exit 0
    }

    $stage = 'dns'
    if ($config.override_dns) {
        if (@($config.dns_servers).Count -eq 0) { throw 'DNS override requires at least one server' }
        $nic = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if (-not $nic) { throw 'No primary network interface' }
        Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses @($config.dns_servers)
        Clear-DnsClientCache
    }
    Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + $config.domain) -Type SRV -DnsOnly -ErrorAction Stop | Out-Null

    $stage = 'sdk-install'
    # Reuse the runtime shipped with OCI Windows Cloudbase-Init, installing SDK
    # packages into a separate directory so its own environment is not modified.
    $python = @(
        "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\Python\python.exe",
        "${env:ProgramFiles(x86)}\Cloudbase Solutions\Cloudbase-Init\Python\python.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $python) { throw 'Cloudbase-Init Python runtime missing' }
    $sdk = Join-Path $root 'sdk'
    $ready = Join-Path $sdk '.ready-2.191.0'
    if (-not (Test-Path $ready)) {
        & $python -m pip --version *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Bundled Python must include pip; use a prepared image as documented' }
        & $python -m pip install --disable-pip-version-check --no-input --no-cache-dir --upgrade --target $sdk 'oci==2.191.0' *> $null
        if ($LASTEXITCODE -ne 0) { throw 'OCI SDK install failed' }
        New-Item -ItemType File -Path $ready -Force | Out-Null
    }

    $stage = 'vault-retrieval'
    # Never run this helper interactively or redirect its stdout to a file.
    $secretJson = & $python (Join-Path $root 'read_secret.py') 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Vault retrieval unavailable' }
    $secret = $secretJson | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString -String $secret.password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($secret.username, $securePassword)
    $secretJson = $null
    $secret = $null

    $stage = 'domain-join'
    $join = @{
        DomainName = $config.domain
        Credential = $credential
        Force = $true
        ErrorAction = 'Stop'
    }
    if ($env:COMPUTERNAME -ine $config.computer_name) { $join.NewName = $config.computer_name }
    if ($config.ou_path) { $join.OUPath = $config.ou_path }
    # No -Restart: persist progress before explicitly scheduling the reboot.
    Add-Computer @join | Out-Null
    $progress.pending_boot = $boot
    Save-Progress
    Write-Status 'joined_pending_reboot' 'reboot'
    & shutdown.exe /r /t 60 /d p:2:4 /c 'Complete OCI Active Directory join'
} catch {
    # Intentionally omit exception messages, invocation details and transcripts.
    if ($stage -eq 'domain-join') {
        # Do not repeatedly submit a potentially invalid password and lock the account.
        Write-Status 'failed' $stage
        Stop-JoinTask
    } else {
        Write-Status 'retrying' $stage
    }
    exit 1
} finally {
    $secretJson = $null
    $secret = $null
    $credential = $null
    if ($securePassword) { $securePassword.Dispose() }
}
