# Real client <-> server E2E orchestration.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 using the
# ANSI code page (GBK on a zh-CN box) unless the file has a UTF-8 BOM, so
# non-ASCII text here breaks the parser before the script even runs.
# (Same lesson as server/alembic.ini.)
#
# Why an orchestrator: the E2E must cover "offline -> recover -> backfill ->
# device revoked", which requires stopping and starting the server BETWEEN two
# client runs. A single test process cannot do that. Each stage below is a
# separate `flutter test` invocation sharing one SQLite file, which is exactly
# equivalent to "close the client and open it again".
#
# Usage (from the project root):
#   pwsh -ExecutionPolicy Bypass -NoProfile -File tools/e2e_client_sync.ps1
#
# Localhost only. Never touches the public network.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $root 'server'
$workDir = Join-Path $root 'build\e2e'
$port = if ($env:PETLIFE_E2E_PORT) { $env:PETLIFE_E2E_PORT } else { '8010' }
$baseUrl = "http://127.0.0.1:$port"

$flutter = 'C:\src\flutter\bin\flutter.bat'
$python = Join-Path $serverDir '.python\python.exe'

$env:NO_PROXY = 'localhost,127.0.0.1,::1'

function Set-ServerEnv {
  $env:PYTHONUTF8 = '1'
  $env:PETLIFE_JWT_SECRET = 'e2e-local-secret-0123456789abcdefghijkl'
  $env:PETLIFE_ENVIRONMENT = 'development'
  $env:PETLIFE_DATABASE_URL = "sqlite+pysqlite:///$($script:serverDb -replace '\\','/')"
}

function Start-PetLifeServer {
  Set-ServerEnv
  $log = Join-Path $workDir 'uvicorn.log'
  $proc = Start-Process -FilePath $python `
    -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', $port, '--log-level', 'warning') `
    -WorkingDirectory $serverDir -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -PassThru -NoNewWindow
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    try {
      $r = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 3
      if ($r.status -eq 'ok') {
        Write-Host "  server ready (pid=$($proc.Id), db=$script:serverDb)"
        return $proc
      }
    } catch { }
  }
  throw "server did not become ready within 30s; see $log"
}

function Stop-PetLifeServer($proc) {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    Write-Host '  server stopped'
  }
}

function Invoke-Stage([string]$stage) {
  Write-Host ''
  Write-Host "=== stage: $stage ===" -ForegroundColor Cyan
  $env:PETLIFE_E2E_STAGE = $stage
  $env:PETLIFE_E2E_BASE_URL = $baseUrl
  $out = Join-Path $workDir "stage_$stage.txt"
  # Same PowerShell 5.1 caveat as the migration step: `flutter test` writes
  # warnings to stderr, which becomes a NativeCommandError under
  # $ErrorActionPreference='Stop'. Relax it locally; judge by exit code.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $flutter test test/e2e_real_server_test.dart --no-pub --reporter compact 2>&1 |
      Out-File -Encoding utf8 $out
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $prevEap
  }
  Select-String -Path $out -Pattern '\[e2e\]' | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
  if ($code -ne 0) {
    Write-Host "  FAILED (exit=$code); full output: $out" -ForegroundColor Red
    Get-Content $out -Tail 30
    $serverLog = Join-Path $workDir 'uvicorn.log'
    if (Test-Path $serverLog) {
      Write-Host '  --- server log (tail) ---' -ForegroundColor Yellow
      Get-Content $serverLog -Tail 30
    }
    throw "stage $stage failed"
  }
  Write-Host '  OK' -ForegroundColor Green
}

# --- prepare a clean environment ---
Write-Host '=== prepare ===' -ForegroundColor Cyan
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$script:serverDb = Join-Path $workDir 'server.db'
Set-ServerEnv
Write-Host '  running server migrations...'
# alembic.ini lives in server/, so migrations must run from there.
# NOTE: PowerShell 5.1 turns any stderr write from a native command into a
# NativeCommandError, and $ErrorActionPreference='Stop' then aborts the script
# even when the command succeeded (alembic logs INFO to stderr). Relax the
# preference locally and rely on $LASTEXITCODE instead.
$migrationOutput = @()
$migrationExit = 0
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $serverDir
try {
  & $python -m alembic upgrade head 2>&1 | Tee-Object -Variable migrationOutput |
    Out-Null
  $migrationExit = $LASTEXITCODE
}
finally {
  Pop-Location
  $ErrorActionPreference = $prevEap
}
if ($migrationExit -ne 0) {
  $migrationOutput | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
  throw 'server migration failed'
}
Write-Host "  server test db ready: $($script:serverDb)"

$proc = $null
try {
  $proc = Start-PetLifeServer
  Invoke-Stage 'online'

  # simulate a network outage by stopping the server
  Stop-PetLifeServer $proc
  $proc = $null
  Invoke-Stage 'offline'

  # network is back
  $proc = Start-PetLifeServer
  Invoke-Stage 'recover'

  Invoke-Stage 'revoked'
  Invoke-Stage 'signout'

  Write-Host ''
  Write-Host '=== ALL STAGES PASSED ===' -ForegroundColor Green
  Write-Host "server log: $(Join-Path $workDir 'uvicorn.log')"
  Write-Host "stage output: $workDir\stage_*.txt"
}
finally {
  Stop-PetLifeServer $proc
  Remove-Item Env:PETLIFE_E2E_STAGE -ErrorAction SilentlyContinue
}
