# Fixed stage/state labels and numeric diagnostics only. Never log command output,
# exception messages, config contents, or the credential helper's stdout.
function Write-TimingEvent([string]$Event, [System.Collections.IDictionary]$Fields) {
    $record = [ordered]@{
        event = $Event
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        run_id = $script:runId
        process_id = $PID
    }
    foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
    $record | ConvertTo-Json -Compress -Depth 4 | Add-Content $script:timingsFile -Encoding UTF8
}

function Initialize-StageLogging([string]$Root) {
    $script:statusFile = Join-Path $Root 'status.json'
    $script:logFile = Join-Path $Root 'worker.log'
    $script:timingsFile = Join-Path $Root 'timings.jsonl'
    $script:runId = [Guid]::NewGuid().ToString('N')
    $script:runStartedUtc = [DateTime]::UtcNow.ToString('o')
    $script:runWatch = [Diagnostics.Stopwatch]::StartNew()
    $script:activeStage = $null
    $script:stageWatch = $null
    $script:stageOutcome = 'succeeded'
    $script:runOutcome = 'running'
    Write-TimingEvent 'run_start' @{ started_utc = $script:runStartedUtc }
}

function Complete-StageTiming {
    if ($script:activeStage) {
        $script:stageWatch.Stop()
        $duration = [Math]::Round($script:stageWatch.Elapsed.TotalMilliseconds, 3)
        $ended = [DateTime]::UtcNow.ToString('o')
        Write-TimingEvent 'stage_end' @{
            stage = $script:activeStage
            started_utc = $script:stageStartedUtc
            ended_utc = $ended
            duration_ms = $duration
            outcome = $script:stageOutcome
        }
        Add-Content $script:logFile -Value "$ended run_id=$script:runId stage=$script:activeStage event=stage_end duration_ms=$duration outcome=$script:stageOutcome" -Encoding UTF8
        $script:activeStage = $null
    }
}

function Complete-RunTiming {
    Complete-StageTiming
    if ($script:runWatch) {
        $script:runWatch.Stop()
        Write-TimingEvent 'run_end' @{
            started_utc = $script:runStartedUtc
            ended_utc = [DateTime]::UtcNow.ToString('o')
            duration_ms = [Math]::Round($script:runWatch.Elapsed.TotalMilliseconds, 3)
            outcome = $script:runOutcome
        }
        $script:runWatch = $null
    }
}

function Write-Status([string]$State, [string]$Stage) {
    $now = [DateTime]::UtcNow.ToString('o')
    $status = [ordered]@{
        state = $State
        stage = $Stage
        updated_utc = $now
        run_id = $script:runId
    }
    if ($script:activeStage) {
        $status['active_stage'] = $script:activeStage
        $status['stage_started_utc'] = $script:stageStartedUtc
        $status['stage_elapsed_ms'] = [Math]::Round($script:stageWatch.Elapsed.TotalMilliseconds, 3)
    }
    $status | ConvertTo-Json | Set-Content $script:statusFile -Encoding UTF8
    Add-Content $script:logFile -Value "$now run_id=$script:runId state=$State stage=$Stage" -Encoding UTF8
    if ($State -eq 'running') {
        $script:stageOutcome = 'succeeded'
        $script:runOutcome = 'running'
    } else {
        $script:stageOutcome = $State
        $script:runOutcome = $State
    }
}

function Set-Stage([string]$Stage) {
    Complete-StageTiming
    $script:stage = $Stage
    $script:activeStage = $Stage
    $script:stageStartedUtc = [DateTime]::UtcNow.ToString('o')
    $script:stageWatch = [Diagnostics.Stopwatch]::StartNew()
    $script:stageOutcome = 'succeeded'
    Write-TimingEvent 'stage_start' @{ stage = $Stage; started_utc = $script:stageStartedUtc }
    Write-Status 'running' $Stage
}

function Write-FailureCode($Failure) {
    $exception = $Failure.Exception
    $depth = 0
    while ($exception -and $depth -lt 5) {
        $typeName = $exception.GetType().FullName
        $code = $exception.HResult
        $native = $null
        if ($exception -is [System.ComponentModel.Win32Exception]) { $native = $exception.NativeErrorCode }
        Write-TimingEvent 'error' @{ stage = $script:stage; exception_type = $typeName; hresult = $code; native_error = $native }
        Add-Content $script:logFile -Value "$([DateTime]::UtcNow.ToString('o')) run_id=$script:runId stage=$script:stage exception_type=$typeName hresult=$code native_error=$native" -Encoding UTF8
        $exception = $exception.InnerException
        $depth++
    }
}
