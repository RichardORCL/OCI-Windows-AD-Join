$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../scripts'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'join-domain.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Worker syntax errors' }
$fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-WindowsFeatures' }, $true)
Invoke-Expression $fn.Extent.Text
. (Join-Path $source 'configuration.ps1')
function Save-Progress { $script:saves++ }
function Set-Stage($name) { $script:stage = $name }
function Write-Status($state, $name) { $script:state = $state }
function Write-TimingEvent($event, $fields) { }
function Import-Module { }
function Get-WindowsFeature($Name) {
    foreach ($n in $Name) { [pscustomobject]@{ Name = $n; Installed = $script:installed } }
}
function Install-WindowsFeature($Name, [switch]$IncludeManagementTools, [switch]$Restart, $LogPath) {
    if ($Restart) { throw 'Unexpected uncontrolled restart' }
    $script:requested = @($Name)
    $script:installs++
    if ($script:failInstall) { return [pscustomobject]@{ Success = $false; RestartNeeded = 'No'; ExitCode = 'Failed' } }
    $script:installed = $true
    [pscustomobject]@{ Success = $true; RestartNeeded = 'Yes'; ExitCode = 'SuccessRestartRequired' }
}
function shutdown.exe { $script:reboots++; $global:LASTEXITCODE = 0 }
function Reset-Test {
    $script:progress = [pscustomobject]@{ feature_deadline = ''; feature_pending_boot = ''; feature_install_started = $false }
    $script:installed = $false; $script:installs = 0; $script:reboots = 0; $script:saves = 0; $script:failInstall = $false
}
$root = 'unused'
Reset-Test
if (-not (Complete-WindowsFeatures ([pscustomobject]@{}) 'boot1') -or $installs -or $reboots) { throw 'Defaults must do nothing' }
foreach ($flags in @(
    @{install_rds_session_host=$true; install_remote_assistance=$false},
    @{install_rds_session_host=$false; install_remote_assistance=$true},
    @{install_rds_session_host=$true; install_remote_assistance=$true}
)) {
    Reset-Test
    $settings = [pscustomobject]$flags
    if (Complete-WindowsFeatures $settings 'boot1') { throw 'Must wait for feature reboot' }
    if ($installs -ne 1 -or $reboots -ne 1 -or $progress.feature_pending_boot -ne 'boot1') { throw 'Installation/reboot state not saved' }
    if (($requested -contains 'RDS-RD-Server') -ne $flags.install_rds_session_host -or ($requested -contains 'Remote-Assistance') -ne $flags.install_remote_assistance) { throw 'Wrong role selection' }
    if (Complete-WindowsFeatures $settings 'boot1') { throw 'Must not complete before reboot' }
    if ($installs -ne 1) { throw 'Must not reinstall while awaiting reboot' }
    if (-not (Complete-WindowsFeatures $settings 'boot2')) { throw 'Must finish after reboot verification' }
    if ($installs -ne 1) { throw 'Must not reinstall installed features' }
}
Reset-Test
$installed = $true
if (-not (Complete-WindowsFeatures ([pscustomobject]@{install_rds_session_host=$true}) 'boot1') -or $reboots) { throw 'Preinstalled feature should need no reboot' }
Reset-Test
$installed = $true; $progress.feature_install_started = $true
if (Complete-WindowsFeatures ([pscustomobject]@{install_rds_session_host=$true}) 'boot1') { throw 'Interrupted install must reboot before verification' }
Reset-Test
$failInstall = $true
$caught = $false
try { Complete-WindowsFeatures ([pscustomobject]@{install_rds_session_host=$true}) 'boot1' } catch { $caught = $true }
if (-not $caught -or $reboots) { throw 'Failed install must fail without rebooting' }
Reset-Test
$progress.feature_deadline = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
$caught = $false
try { Complete-WindowsFeatures ([pscustomobject]@{install_rds_session_host=$true}) 'boot1' } catch { $caught = $true }
if (-not $caught -or $installs) { throw 'Expired deadline must stop servicing' }
$config = [pscustomobject]@{secret_id='ocid1.vaultsecret.oc1.test';region='eu-amsterdam-1';computer_name='WINTEST';tag_namespace='ADJoinBootstrap';tag_key='State';tag_value='pending';install_rds_session_host=$true;install_remote_assistance=$true}
$resolved = Resolve-VaultConfiguration $config ([pscustomobject]@{domain='corp.example.com'})
if (-not $resolved.install_rds_session_host -or -not $resolved.install_remote_assistance) { throw 'Vault resolution must preserve feature settings' }
$caught = $false
try { Resolve-VaultConfiguration $config ([pscustomobject]@{domain='corp.example.com';install_rds_session_host=$true}) } catch { $caught=$true }
if (-not $caught) { throw 'Feature choices belong in the stack, not secret' }
Write-Output 'Windows feature tests passed: selections, reboot resume, interruption recovery, preinstalled roles, failures, deadlines and Vault configuration preservation.'
