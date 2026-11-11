$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
foreach ($path in @('stage_logging.ps1', 'join-domain.ps1', 'bootstrap.ps1.tftpl')) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source $path), [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "PowerShell syntax errors in $path" }
}
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('oci-stage-timing-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
try {
    $tokens = $null
    $parseErrors = $null
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'bootstrap.ps1.tftpl'), [ref]$tokens, [ref]$parseErrors)
    $expandFunction = $bootstrapAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-BootstrapFile' }, $true)
    . ([scriptblock]::Create($expandFunction.Extent.Text))
    $root = $testRoot
    $originalBytes = [IO.File]::ReadAllBytes((Join-Path $source 'stage_logging.ps1'))
    $compressed = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Compress, $true)
    $gzip.Write($originalBytes, 0, $originalBytes.Length)
    $gzip.Dispose()
    Write-BootstrapFile 'expanded.ps1' ([Convert]::ToBase64String($compressed.ToArray()))
    $compressed.Dispose()
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $testRoot 'expanded.ps1'))) -eq [Convert]::ToBase64String($originalBytes)) 'Embedded gzip payload must expand to the exact original script'
    . (Join-Path $source 'stage_logging.ps1')
    Initialize-StageLogging -Root $testRoot
    Set-Stage 'sdk-install'
    Start-Sleep -Milliseconds 50
    Set-Stage 'vault-retrieval'
    Start-Sleep -Milliseconds 20
    try { throw 'FAKE_SENSITIVE_VALUE_MUST_NOT_BE_LOGGED' } catch { Write-FailureCode $_ }
    Write-Status 'retrying' 'vault-retrieval'
    Complete-RunTiming
    Complete-RunTiming
    $firstRun = $script:runId
    $records = @(Get-Content (Join-Path $testRoot 'timings.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $ends = @($records | Where-Object { $_.event -eq 'stage_end' })
    Assert-True ($ends.Count -eq 2) 'Each entered stage must have one terminal timing record'
    Assert-True ($ends[0].stage -eq 'sdk-install' -and $ends[0].duration_ms -ge 40) 'SDK stage must measure elapsed milliseconds'
    Assert-True ($ends[1].outcome -eq 'retrying' -and $ends[1].duration_ms -ge 10) 'Failed/retrying stages must retain timings'
    Assert-True (@($records | Where-Object { $_.event -eq 'run_end' }).Count -eq 1) 'Run completion must be idempotent'
    foreach ($row in $ends) {
        Assert-True ($row.run_id -eq $firstRun) 'Stages must correlate to their invocation'
        Assert-True ([DateTime]::Parse($row.ended_utc) -ge [DateTime]::Parse($row.started_utc)) 'Stages need UTC start and end timestamps'
    }
    foreach ($name in @('worker.log', 'timings.jsonl', 'status.json')) {
        Assert-True (-not (Get-Content (Join-Path $testRoot $name) -Raw).Contains('FAKE_SENSITIVE_VALUE')) 'Raw exception content must not leak'
    }
    Initialize-StageLogging -Root $testRoot
    Set-Stage 'task-cleanup'
    Write-Status 'complete' 'domain-verified-tag-removed-vault-denied'
    Complete-RunTiming
    Assert-True ($script:runId -ne $firstRun) 'Retries/reboots must receive distinct run IDs'
    $status = Get-Content (Join-Path $testRoot 'status.json') -Raw | ConvertFrom-Json
    Assert-True ($status.state -eq 'complete' -and $status.active_stage -eq 'task-cleanup') 'Status must retain current timing context'

    # A real child PowerShell exit must flush the last stage via finally.
    $childRoot = Join-Path $testRoot 'child'
    New-Item -ItemType Directory $childRoot | Out-Null
    $loggerPath = (Join-Path $source 'stage_logging.ps1').Replace("'", "''")
    $safeChildRoot = $childRoot.Replace("'", "''")
    $childScript = Join-Path $testRoot 'child.ps1'
    @"
. '$loggerPath'
Initialize-StageLogging -Root '$safeChildRoot'
try {
    Set-Stage 'cloudbase-init'
    Write-Status 'waiting' 'cloudbase-init'
    exit 0
} finally {
    Complete-RunTiming
}
"@ | Set-Content $childScript -Encoding UTF8
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $childScript
    Assert-True ($LASTEXITCODE -eq 0) 'Child logging fixture must exit successfully'
    $childRecords = @(Get-Content (Join-Path $childRoot 'timings.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($childRecords | Where-Object { $_.event -eq 'stage_end' -and $_.outcome -eq 'waiting' }).Count -eq 1) 'Early exits must flush stage timing'
    Assert-True (@($childRecords | Where-Object { $_.event -eq 'run_end' -and $_.outcome -eq 'waiting' }).Count -eq 1) 'Early exits must flush run timing'
    # Exercise the real worker's initialization failure and finally block without
    # running Windows/AD commands. Invalid config deliberately contains a marker.
    $workerParent = Join-Path $testRoot 'worker'
    $workerRoot = Join-Path $workerParent 'OCI-ADJoin'
    New-Item -ItemType Directory $workerRoot -Force | Out-Null
    Copy-Item (Join-Path $source 'stage_logging.ps1') $workerRoot
    'FAKE_SENSITIVE_VALUE_INVALID_CONFIG' | Set-Content (Join-Path $workerRoot 'config.json') -Encoding UTF8
    $workerPath = (Join-Path $source 'join-domain.ps1').Replace("'", "''")
    $safeWorkerParent = $workerParent.Replace("'", "''")
    $workerFixture = Join-Path $testRoot 'worker-fixture.ps1'
    @"
`$env:ProgramData = '$safeWorkerParent'
& '$workerPath'
exit `$LASTEXITCODE
"@ | Set-Content $workerFixture -Encoding UTF8
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $workerFixture
    Assert-True ($LASTEXITCODE -eq 1) 'The worker fixture must report initialization failure'
    $workerRows = @(Get-Content (Join-Path $workerRoot 'timings.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($workerRows | Where-Object { $_.event -eq 'stage_end' -and $_.stage -eq 'initialization' -and $_.outcome -eq 'retrying' }).Count -eq 1) 'The real worker must time initialization failures'
    Assert-True (@($workerRows | Where-Object { $_.event -eq 'run_end' }).Count -eq 1) 'The real worker must flush run duration on failure'
    foreach ($name in @('worker.log', 'timings.jsonl', 'status.json')) {
        Assert-True (-not (Get-Content (Join-Path $workerRoot $name) -Raw).Contains('FAKE_SENSITIVE_VALUE')) 'The real worker must not log config or exception contents'
    }
    Write-Output 'PowerShell timing tests passed: syntax, elapsed time, failure redaction, run correlation and early-exit cleanup.'
} finally {
    Remove-Item $testRoot -Recurse -Force
}
