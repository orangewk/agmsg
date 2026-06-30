param(
  [string]$Project = (Get-Location).Path,
  [int]$WaitAfterStartMs = 10000,
  [string]$PromptText = "",
  [switch]$RequireCompleted,
  [switch]$RequireIdleAfterActive
)

$ErrorActionPreference = 'Stop'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Node = (Get-Command node).Source
$Owner = Join-Path $Repo 'scripts\poc\codex-app-server-owner.js'
$Supervisor = Join-Path $Repo 'scripts\poc\delivery-supervisor.js'
$Adapter = Join-Path $Repo 'scripts\poc\codex-idle-wake-adapter.js'
$RunDir = Join-Path $env:TEMP ('agmsg-supervisor-remote-' + [guid]::NewGuid().ToString('N'))
$CodexExe = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'

if (-not (Test-Path -LiteralPath $CodexExe)) {
  throw "native codex.exe not found: $CodexExe"
}

function Quote-CommandArg([string]$Value) {
  '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-NodeJson {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NodeArgs)
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $raw = & $Node @NodeArgs 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "node command failed ($exitCode): $($NodeArgs -join ' ')`n$($raw -join "`n")"
  }
  ($raw -join "`n") | ConvertFrom-Json
}

function Wait-SupervisorReady([string]$Dir) {
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    $portFile = Get-ChildItem -LiteralPath $Dir -Filter 'supervisor.*.port' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($portFile) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "supervisor port file was not created under $Dir"
}

function Stop-Tree([int]$ProcessId) {
  if ($ProcessId -gt 0) {
    try { taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null } catch {}
  }
}

$summary = [ordered]@{
  ok = $false
  runDir = $RunDir
  project = (Resolve-Path $Project).Path
}
$remoteProcess = $null
$supervisorProcess = $null

try {
  New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

  $ownerStart = Invoke-NodeJson $Owner 'start' '--run-dir' $RunDir
  $summary.endpoint = $ownerStart.endpoint
  $summary.ownerPid = $ownerStart.pid

  $remoteCommand = "& '$CodexExe' --remote '$($ownerStart.endpoint)' --cd '$Project' --no-alt-screen"
  $remoteProcess = Start-Process powershell.exe -ArgumentList @('-NoExit', '-Command', $remoteCommand) -PassThru
  $summary.remotePid = $remoteProcess.Id
  Start-Sleep -Seconds 8

  $adapterArgs = @(
    (Quote-CommandArg $Node),
    (Quote-CommandArg $Adapter),
    '--project', (Quote-CommandArg $Project),
    '--app-server', $ownerStart.endpoint,
    '--thread', 'loaded',
    '--skip-resume',
    '--request-timeout-ms', '30000',
    '--wait-after-start-ms', [string]$WaitAfterStartMs
  )
  if ($PromptText) {
    $adapterArgs += @('--prompt-text', (Quote-CommandArg $PromptText))
  }
  $adapterCmd = $adapterArgs -join ' '
  $summary.adapterCmd = $adapterCmd

  $supervisorOut = Join-Path $RunDir 'supervisor.stdout.log'
  $supervisorErr = Join-Path $RunDir 'supervisor.stderr.log'
  $supervisorArgs = @(
    $Supervisor, 'start', '--run-dir', $RunDir, '--project', $Project,
    '--heartbeat-timeout-ms', '30000', '--poll-ms', '100', '--adapter-cmd', $adapterCmd
  )
  $supervisorArgLine = ($supervisorArgs | ForEach-Object { Quote-CommandArg $_ }) -join ' '
  $supervisorProcess = Start-Process -FilePath $Node -ArgumentList $supervisorArgLine -RedirectStandardOutput $supervisorOut -RedirectStandardError $supervisorErr -PassThru
  $summary.supervisorPid = $supervisorProcess.Id
  Wait-SupervisorReady $RunDir

  Invoke-NodeJson $Supervisor 'attach' '--run-dir' $RunDir '--project' $Project '--team' 'mathdesk-desktop' '--name' 'Eiji' '--session' 'visible-remote-smoke' | Out-Null
  Invoke-NodeJson $Supervisor 'send' '--run-dir' $RunDir '--project' $Project '--team' 'mathdesk-desktop' '--from' 'Anna' '--to' 'Eiji' '--body' 'supervisor to visible codex remote smoke' | Out-Null

  $status = Invoke-NodeJson $Supervisor 'status' '--run-dir' $RunDir '--project' $Project
  $summary.cursor = $status.cursor
  $eventLogFile = Get-ChildItem -LiteralPath $RunDir -Filter 'supervisor.*.events.log' | Select-Object -First 1
  if (-not $eventLogFile) { throw "supervisor event log was not created under $RunDir" }
  $summary.eventLog = $eventLogFile.FullName
  $events = Get-Content -LiteralPath $eventLogFile.FullName | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
  $adapterOk = @($events | Where-Object { $_.event -eq 'adapter-ok' } | Select-Object -Last 1)[0]
  if (-not $adapterOk) { throw 'adapter-ok event was not recorded' }
  $summary.adapterStdout = $adapterOk.stdout
  $adapterOutput = $adapterOk.stdout | ConvertFrom-Json
  $active = @($adapterOutput.observed | Where-Object { $_.method -eq 'thread/status/changed' -and $_.status -eq 'active' })
  if ($active.Count -lt 1) { throw "no active status observed in adapter stdout: $($adapterOk.stdout)" }
  if ($RequireCompleted) {
    $completed = @($adapterOutput.observed | Where-Object { $_.method -eq 'turn/completed' })
    if ($completed.Count -lt 1) { throw "no turn/completed observed in adapter stdout: $($adapterOk.stdout)" }
  }
  if ($RequireIdleAfterActive) {
    $idle = @($adapterOutput.observed | Where-Object { $_.method -eq 'thread/status/changed' -and $_.status -eq 'idle' })
    if ($idle.Count -lt 1) { throw "no idle status observed after active in adapter stdout: $($adapterOk.stdout)" }
  }
  $summary.threadId = $adapterOutput.threadId
  $summary.observed = $adapterOutput.observed
  $summary.requireCompleted = [bool]$RequireCompleted
  $summary.requireIdleAfterActive = [bool]$RequireIdleAfterActive
  $summary.ok = $true
} finally {
  try { Invoke-NodeJson $Supervisor 'stop' '--run-dir' $RunDir '--project' $Project | Out-Null } catch {}
  try { Invoke-NodeJson $Owner 'stop' '--run-dir' $RunDir | Out-Null } catch {}
  if ($remoteProcess) { Stop-Tree $remoteProcess.Id }
  if ($supervisorProcess) { Stop-Tree $supervisorProcess.Id }
}

$summary | ConvertTo-Json -Depth 8
if (-not $summary.ok) { exit 1 }