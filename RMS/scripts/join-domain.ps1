$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:ProgramData 'OCI-ADJoin'
$stateFile = Join-Path $root 'progress.json'
$taskName = 'OCI-ADJoin'
. (Join-Path $root 'stage_logging.ps1')
Initialize-StageLogging -Root $root
. (Join-Path $root 'configuration.ps1')

function Stop-JoinTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
function Save-Progress {
    $script:progress | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
}

function Wait-CloudbaseInit([int]$PollSeconds = 15, [int]$MaxWaitSeconds = 45) {
    # Poll inside this invocation; the one-minute task trigger handles later retries.
    # Keep this wait shorter than the trigger interval so a prolonged Cloudbase run
    # does not consume the whole 15-minute task budget before SDK installation.
    $waitWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-TimingEvent 'cloudbase_poll_configuration' @{ stage = 'cloudbase-init'; poll_interval_seconds = $PollSeconds; max_wait_seconds = $MaxWaitSeconds }
    do {
        $cloudbase = @(Get-Service -Name 'cloudbase-init*' -ErrorAction Stop)
        if ($cloudbase.Count -eq 0) { throw 'Cloudbase-Init service not found' }
        if (@($cloudbase | Where-Object { $_.Status -ne 'Stopped' }).Count -eq 0) {
            Write-TimingEvent 'cloudbase_ready' @{ stage = 'cloudbase-init'; wait_duration_ms = [Math]::Round($waitWatch.Elapsed.TotalMilliseconds, 3) }
            Write-Status 'running' 'cloudbase-init'
            return $true
        }
        Write-Status 'waiting' 'cloudbase-init'
        $remaining = $MaxWaitSeconds - $waitWatch.Elapsed.TotalSeconds
        if ($remaining -le 0) { return $false }
        Start-Sleep -Milliseconds ([int]([Math]::Min($PollSeconds, $remaining) * 1000))
    } while ($true)
}

function Initialize-OciSdk {
    # Reuse the runtime shipped with OCI Windows Cloudbase-Init, installing SDK
    # packages into a separate directory so its own environment is not modified.
    $python = @(
        "$env:ProgramFiles\Cloudbase Solutions\Cloudbase-Init\Python\python.exe",
        "${env:ProgramFiles(x86)}\Cloudbase Solutions\Cloudbase-Init\Python\python.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $python) { throw 'Cloudbase-Init Python runtime missing' }
    $sdk = Join-Path $root 'sdk'
    $ready = Join-Path $sdk '.ready-2.191.0'
    $sdkReady = Test-Path $ready
    Write-TimingEvent 'sdk_configuration' @{ stage = 'sdk-install'; sdk_version = '2.191.0'; no_compile = $true; cache_hit = $sdkReady }
    if (-not $sdkReady) {
        & $python -m pip --version *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Bundled Python must include pip; use a prepared image as documented' }
        $pipLog = Join-Path $root 'sdk-install.log'
        & $python -m pip install --disable-pip-version-check --no-input --no-cache-dir --no-compile --upgrade --log $pipLog --target $sdk 'oci==2.191.0' *> $null
        if ($LASTEXITCODE -ne 0) { throw 'OCI SDK install failed' }
        New-Item -ItemType File -Path $ready -Force | Out-Null
    }

    return $python
}

$stage = 'initialization'
try {
    Set-Stage 'initialization'
    $config = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (Test-Path $stateFile) {
        $script:progress = Get-Content $stateFile -Raw | ConvertFrom-Json
    } else {
        $script:progress = [pscustomobject]@{
            deadline = [DateTime]::UtcNow.AddHours(6).ToString('o')
            attempts = 0
            pending_boot = ''
            cleanup_deadline = ''
            tag_removed = $false
        }
        Save-Progress
    }
    if (-not $progress.cleanup_deadline -and ([DateTime]::UtcNow -gt [DateTime]::Parse($progress.deadline).ToUniversalTime() -or $progress.attempts -ge 360)) {
        Write-Status 'failed' 'retry-window-expired'
        Stop-JoinTask
        exit 1
    }
    if ($progress.cleanup_deadline -and [DateTime]::UtcNow -gt [DateTime]::Parse($progress.cleanup_deadline).ToUniversalTime()) {
        Write-Status 'failed' 'access-cleanup-window-expired'
        Stop-JoinTask
        exit 1
    }
    $progress.attempts++
    Save-Progress

    # Never reboot while the cloud initialization service is still executing.
    Set-Stage 'cloudbase-init'
    if (-not (Wait-CloudbaseInit)) { exit 0 }

    if ($config.manual_metadata) {
        Set-Stage 'metadata-configuration'
        $config = Resolve-ManualConfiguration $config
        $config | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
    }

    Set-Stage 'instance-inspection'
    $computer = Get-CimInstance Win32_ComputerSystem
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    if ($progress.pending_boot -eq $boot) {
        Set-Stage 'reboot-scheduling'
        Write-Status 'joined_pending_reboot' 'reboot'
        & shutdown.exe /r /t 10 /d p:2:4 /c 'Complete OCI Active Directory join'
        if ($LASTEXITCODE -ne 0) { throw 'Reboot scheduling failed' }
        exit 0
    }
    if ($computer.PartOfDomain) {
        if ($computer.Domain -ine $config.domain -or $env:COMPUTERNAME -ine $config.computer_name) {
            Write-Status 'failed' 'existing-membership-or-name-mismatch'
            Stop-JoinTask
            exit 1
        }
        Set-Stage 'secure-channel-verification'
        if (-not (Test-ComputerSecureChannel -ErrorAction Stop)) { throw 'Secure channel unavailable' }
        if (-not $progress.cleanup_deadline) {
            $progress.cleanup_deadline = [DateTime]::UtcNow.AddHours(2).ToString('o')
            Save-Progress
        }
        Set-Stage 'sdk-install'
        $python = Initialize-OciSdk
        if (-not $progress.tag_removed) {
            Set-Stage 'bootstrap-tag-removal'
            & $python (Join-Path $root 'cleanup_access.py') 'remove-tag' *> $null
            if ($LASTEXITCODE -ne 0) { throw 'Bootstrap tag removal failed' }
            $progress.tag_removed = $true
            Save-Progress
        }
        Set-Stage 'vault-revocation'
        & $python (Join-Path $root 'cleanup_access.py') 'verify-revocation' *> $null
        $probeResult = $LASTEXITCODE
        if ($probeResult -eq 10) {
            Write-Status 'revocation_pending' 'vault-access-still-active'
            exit 0
        }
        if ($probeResult -ne 0) { throw 'Vault access denial could not be verified' }
        Set-Stage 'task-cleanup'
        Write-Status 'complete' 'domain-verified-tag-removed-vault-denied'
        Stop-JoinTask
        exit 0
    }

    if (-not $config.config_from_vault) {
        Set-Stage 'dns'
        Set-DomainDns $config
    }

    Set-Stage 'sdk-install'
    $python = Initialize-OciSdk

    Set-Stage 'vault-retrieval'
    # Never run this helper interactively or redirect its stdout to a file.
    $secretJson = & $python (Join-Path $root 'read_secret.py') 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Vault retrieval unavailable' }
    $secret = $secretJson | ConvertFrom-Json
    if ($config.config_from_vault) {
        Set-Stage 'vault-configuration'
        $config = Resolve-VaultConfiguration $config $secret.ad_join
        $config | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Set-Stage 'dns'
        Set-DomainDns $config
    }
    $securePassword = ConvertTo-SecureString -String $secret.password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($secret.username, $securePassword)
    $secretJson = $null
    $secret = $null

    Set-Stage 'domain-join'
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
    $progress.cleanup_deadline = [DateTime]::UtcNow.AddHours(2).ToString('o')
    $progress.pending_boot = $boot
    Save-Progress
    Set-Stage 'reboot-scheduling'
    Write-Status 'joined_pending_reboot' 'reboot'
    & shutdown.exe /r /t 10 /d p:2:4 /c 'Complete OCI Active Directory join'
    if ($LASTEXITCODE -ne 0) { throw 'Reboot scheduling failed' }
} catch {
    Write-FailureCode $_
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
    Complete-RunTiming
}
