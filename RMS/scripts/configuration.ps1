# Configuration helpers accept only nonsecret enrollment fields. Credential
# values are read by read_secret.py and never passed to these persistence helpers.
function Get-InstanceMetadata {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $response = $null
        $reader = $null
        try {
            $request = [Net.HttpWebRequest]::Create('http://169.254.169.254/opc/v2/instance/')
            $request.Proxy = $null
            $request.Timeout = 10000
            $request.ReadWriteTimeout = 10000
            $request.Headers.Add('Authorization', 'Bearer Oracle')
            $response = $request.GetResponse()
            $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } catch {
            if ($attempt -eq 2) { throw 'Instance metadata is unavailable' }
            Start-Sleep -Seconds 3
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

function ConvertTo-NonsecretConfiguration($InputConfig, [bool]$RequireDomain = $true) {
    $allowed = @('secret_id', 'region', 'computer_name', 'domain', 'override_dns', 'dns_servers', 'ou_path', 'tag_namespace', 'tag_key', 'tag_value', 'config_from_vault', 'manual_metadata', 'install_rds_session_host', 'install_remote_assistance')
    foreach ($property in $InputConfig.PSObject.Properties) {
        if ($allowed -notcontains $property.Name) { throw 'Unknown configuration field; keep credentials in Vault' }
    }
    foreach ($name in @('secret_id', 'region', 'computer_name', 'domain', 'ou_path', 'tag_namespace', 'tag_key', 'tag_value')) {
        if ($null -ne $InputConfig.$name -and $InputConfig.$name -isnot [string]) { throw 'Text settings must be JSON strings' }
    }
    $result = [ordered]@{
        secret_id = [string]$InputConfig.secret_id
        region = [string]$InputConfig.region
        computer_name = [string]$InputConfig.computer_name
        domain = [string]$InputConfig.domain
        override_dns = $false
        dns_servers = @()
        ou_path = [string]$InputConfig.ou_path
        tag_namespace = 'ADJoinBootstrap'
        tag_key = 'State'
        tag_value = 'pending'
        config_from_vault = $false
        manual_metadata = $false
    }
    foreach ($name in @('install_rds_session_host', 'install_remote_assistance')) {
        $result[$name] = $false
        if ($InputConfig.PSObject.Properties[$name]) {
            if ($InputConfig.$name -isnot [bool]) { throw 'Feature settings must be JSON booleans' }
            $result[$name] = $InputConfig.$name
        }
    }
    if ($result.secret_id -notmatch '^ocid1\.vaultsecret\.[A-Za-z0-9._-]+$') { throw 'A Vault secret OCID is required' }
    if ($result.region -notmatch '^[a-z0-9-]+$') { throw 'A valid OCI region is required' }
    if (-not $result.computer_name) { $result.computer_name = $env:COMPUTERNAME }
    if ($result.computer_name -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' -or $result.computer_name -match '^[0-9]+$') { throw 'Invalid Windows computer name' }
    $result.computer_name = $result.computer_name.ToUpperInvariant()
    if ($InputConfig.PSObject.Properties['config_from_vault']) {
        if ($InputConfig.config_from_vault -isnot [bool]) { throw 'config_from_vault must be a JSON boolean' }
        $result.config_from_vault = $InputConfig.config_from_vault
    }
    foreach ($name in @('tag_namespace', 'tag_key', 'tag_value')) {
        if ($InputConfig.PSObject.Properties[$name]) { $result[$name] = [string]$InputConfig.$name }
        if ($result[$name] -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { throw 'Invalid bootstrap tag setting' }
    }
    if ($InputConfig.PSObject.Properties['override_dns']) {
        if ($InputConfig.override_dns -isnot [bool]) { throw 'override_dns must be a JSON boolean' }
        $result.override_dns = $InputConfig.override_dns
    }
    if ($InputConfig.dns_servers -is [string]) { $addresses = $InputConfig.dns_servers.Split(',') }
    else { $addresses = @($InputConfig.dns_servers) }
    if ($result.override_dns) {
        foreach ($address in $addresses) {
            if ($address -isnot [string]) { throw 'DNS servers must be IPv4 strings' }
            $text = $address.Trim()
            $parsed = $null
            if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($text, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.ToString() -ne $text) { throw 'Invalid DNS server IPv4 address' }
            $result.dns_servers += $text
        }
        if ($result.dns_servers.Count -eq 0) { throw 'DNS override requires at least one server' }
    }
    if ($RequireDomain) {
        if ($result.domain.Length -gt 253 -or $result.domain -notmatch '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') { throw 'An AD DNS domain is required' }
        $result.domain = $result.domain.ToLowerInvariant()
    }
    return [pscustomobject]$result
}

function Resolve-ManualConfiguration($Seed) {
    $instance = Get-InstanceMetadata
    $merged = [ordered]@{}
    foreach ($property in $Seed.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    $metadata = $instance.metadata
    if (-not ($metadata -and $metadata.PSObject.Properties['ad_join_config']) -and $instance.extendedMetadata) { $metadata = $instance.extendedMetadata }
    if ($metadata -and $metadata.PSObject.Properties['ad_join_config']) {
        $custom = $metadata.ad_join_config
        if ($custom -is [string]) { $custom = $custom | ConvertFrom-Json }
        if ($custom -isnot [pscustomobject]) { throw 'ad_join_config must be a JSON object or encoded JSON object' }
        foreach ($property in $custom.PSObject.Properties) { $merged[$property.Name] = $property.Value }
    }
    # Always derive the service region from the actual instance, not caller input.
    $merged.region = [string]$instance.canonicalRegionName
    if (-not $merged.region) { $merged.region = [string]$instance.regionInfo.regionIdentifier }
    $merged.manual_metadata = $false
    $inputObject = [pscustomobject]$merged
    if ($inputObject.config_from_vault -is [bool] -and $inputObject.config_from_vault) {
        # These fields belong exclusively to the Vault profile in this mode.
        foreach ($entry in @{ domain = ''; ou_path = ''; override_dns = $false; dns_servers = @() }.GetEnumerator()) {
            $inputObject | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
        }
    }
    $resolved = ConvertTo-NonsecretConfiguration $inputObject (-not ($inputObject.config_from_vault -eq $true))
    $namespace = $null
    if ($instance.definedTags) { $namespace = $instance.definedTags.PSObject.Properties[$resolved.tag_namespace] }
    if (-not $namespace -or -not $namespace.Value.PSObject.Properties[$resolved.tag_key] -or [string]$namespace.Value.($resolved.tag_key) -ine $resolved.tag_value) { throw 'The required bootstrap defined tag must be applied at launch' }
    return $resolved
}

function Resolve-VaultConfiguration($Existing, $Profile) {
    if ($Profile -isnot [pscustomobject]) { throw 'The credential secret must contain an ad_join object' }
    foreach ($property in $Profile.PSObject.Properties) {
        if (@('domain', 'ou_path', 'override_dns', 'dns_servers') -notcontains $property.Name) { throw 'Unknown ad_join profile setting' }
    }
    # Build a fresh allowlisted object: never persist the parent secret object.
    $settings = [ordered]@{
        secret_id = $Existing.secret_id
        region = $Existing.region
        computer_name = $Existing.computer_name
        tag_namespace = $Existing.tag_namespace
        tag_key = $Existing.tag_key
        tag_value = $Existing.tag_value
        config_from_vault = $false
        install_rds_session_host = ($Existing.install_rds_session_host -eq $true)
        install_remote_assistance = ($Existing.install_remote_assistance -eq $true)
    }
    foreach ($property in $Profile.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    return ConvertTo-NonsecretConfiguration ([pscustomobject]$settings) $true
}

function Set-DomainDns($Settings) {
    if ($Settings.override_dns) {
        if (@($Settings.dns_servers).Count -eq 0) { throw 'DNS override requires at least one server' }
        $nic = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if (-not $nic) { throw 'No primary network interface' }
        Set-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -ServerAddresses @($Settings.dns_servers)
        Clear-DnsClientCache
    }
    Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + $Settings.domain) -Type SRV -DnsOnly -ErrorAction Stop | Out-Null
}
