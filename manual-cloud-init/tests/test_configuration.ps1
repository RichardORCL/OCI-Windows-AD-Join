$ErrorActionPreference = 'Stop'
$manual = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path (Split-Path $manual -Parent) 'RMS/scripts'
foreach ($path in @((Join-Path $runtime 'configuration.ps1'), (Join-Path $manual 'oci-windows-ad-cloud-init.ps1'))) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw 'PowerShell configuration/bootstrap syntax error' }
}
. (Join-Path $runtime 'configuration.ps1')
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Invalid configuration must be rejected'
}
$seed = '{"secret_id":"ocid1.vaultsecret.oc1.eu-amsterdam-1.test","domain":"corp.example.com","computer_name":"OCI-WIN01"}' | ConvertFrom-Json
$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","metadata":{}}' | ConvertFrom-Json
function Get-InstanceMetadata {
    if (-not $script:fakeMetadata.PSObject.Properties['definedTags']) {
        $script:fakeMetadata | Add-Member -NotePropertyName definedTags -NotePropertyValue ('{"ADJoinBootstrap":{"State":"pending"}}' | ConvertFrom-Json)
    }
    return $script:fakeMetadata
}
$result = Resolve-ManualConfiguration $seed
Assert-True ($result.domain -eq 'corp.example.com' -and $result.region -eq 'eu-amsterdam-1' -and -not $result.override_dns) 'Editable script settings must support default DHCP DNS'
$script:fakeMetadata.metadata | Add-Member -NotePropertyName ad_join_config -NotePropertyValue '{"domain":"ad.example.com","override_dns":true,"dns_servers":["10.0.0.10","10.0.0.11"],"region":"wrong"}'
$result = Resolve-ManualConfiguration $seed
Assert-True ($result.domain -eq 'ad.example.com' -and $result.dns_servers.Count -eq 2 -and $result.region -eq 'eu-amsterdam-1') 'Metadata must override script settings while region comes from the actual instance'
$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","extendedMetadata":{"ad_join_config":{"domain":"extended.example.com"}}}' | ConvertFrom-Json
Assert-True ((Resolve-ManualConfiguration $seed).domain -eq 'extended.example.com') 'Structured extended metadata must be supported'
$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","metadata":{"ad_join_config":{"domain":"object.example.com"}}}' | ConvertFrom-Json
Assert-True ((Resolve-ManualConfiguration $seed).domain -eq 'object.example.com') 'Structured metadata values must be supported'
$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","metadata":{"ad_join_config":{"domain":"","config_from_vault":true,"override_dns":true,"dns_servers":["ignored-in-vault-mode"]}}}' | ConvertFrom-Json
$pending = Resolve-ManualConfiguration $seed
Assert-True ($pending.config_from_vault -and -not $pending.domain -and -not $pending.override_dns) 'Vault profile mode must defer AD domain validation until the secret is fetched'
$profile = '{"domain":"vault.example.com","override_dns":true,"dns_servers":"10.0.0.10, 10.0.0.11","ou_path":"OU=Servers,DC=vault,DC=example,DC=com"}' | ConvertFrom-Json
$resolved = Resolve-VaultConfiguration $pending $profile
Assert-True ($resolved.domain -eq 'vault.example.com' -and -not $resolved.config_from_vault -and $resolved.dns_servers[1] -eq '10.0.0.11') 'Vault AD settings must normalize before use and persist for post-reboot cleanup'
Assert-True (-not ($resolved | ConvertTo-Json).Contains('password')) 'Nonsecret configuration must never contain credential fields'
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","password":"secret"}' | ConvertFrom-Json) }
Assert-Rejected { Resolve-VaultConfiguration $pending $null }
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","ou_path":{"password":"must-not-persist"}}' | ConvertFrom-Json) }
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","override_dns":"false"}' | ConvertFrom-Json) }
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","override_dns":true,"dns_servers":[]}' | ConvertFrom-Json) }
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","override_dns":true,"dns_servers":["999.0.0.1"]}' | ConvertFrom-Json) }
Assert-Rejected { Resolve-VaultConfiguration $pending ('{"domain":"corp.example.com","override_dns":true,"dns_servers":["010.0.0.1"]}' | ConvertFrom-Json) }
$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","metadata":{"ad_join_config":{"username":"should-not-be-in-metadata"}}}' | ConvertFrom-Json
Assert-Rejected { Resolve-ManualConfiguration $seed }

$script:fakeMetadata = '{"canonicalRegionName":"eu-amsterdam-1","metadata":{},"definedTags":{}}' | ConvertFrom-Json
Assert-Rejected { Resolve-ManualConfiguration $seed }

$script:dnsActions = @()
function Get-NetIPConfiguration { [pscustomobject]@{ IPv4DefaultGateway = '10.0.0.1'; NetAdapter = [pscustomobject]@{ Status = 'Up' }; InterfaceIndex = 4 } }
function Set-DnsClientServerAddress($InterfaceIndex, $ServerAddresses) { $script:dnsActions += 'set-dns' }
function Clear-DnsClientCache { $script:dnsActions += 'clear-cache' }
function Resolve-DnsName($Name, $Type, [switch]$DnsOnly, $ErrorAction) { $script:dnsActions += 'resolve-domain' }
Set-DomainDns $resolved
Assert-True (($script:dnsActions -join ',') -eq 'set-dns,clear-cache,resolve-domain') 'DNS override must precede domain discovery'
$script:dnsActions = @()
$resolved.override_dns = $false
Set-DomainDns $resolved
Assert-True (($script:dnsActions -join ',') -eq 'resolve-domain') 'DHCP DNS must be retained when override is disabled'
Write-Output 'Manual configuration tests passed: metadata/inline/Vault modes, validation, nonsecret persistence and DNS ordering.'
