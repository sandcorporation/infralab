# infralab 실습 시작 스크립트 — compose.yml 을 받고, docker compose up -d 로 띄우고,
# agent 의 응시 전 점검(GET /api/preflight)이 실패면 안내 링크를 연다.
param(
  [string]$ComposeUrl = "",
  [string]$DashboardUrl = "",
  [string]$DataDir = (Join-Path $env:APPDATA "infralab"),
  [int]$WaitSeconds = 60,
  [string]$AgentUrl = "http://127.0.0.1:7777"
)

$ErrorActionPreference = "Stop"
$EngineHelp = "https://docs.docker.com/desktop/"

function Open-Help([string]$url, [string]$why) {
  Write-Host $why
  Write-Host "안내 페이지를 엽니다: $url"
  Start-Process $url
}

# 설치 화면에서 넣은 값(settings.json) — 인자가 우선
$settingsPath = Join-Path $DataDir "settings.json"
if (Test-Path $settingsPath) {
  $s = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $ComposeUrl) { $ComposeUrl = [string]$s.compose_url }
  if (-not $DashboardUrl) { $DashboardUrl = [string]$s.dashboard_url }
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$compose = Join-Path $DataDir "compose.yml"

# 1. compose.yml 받기
if ($ComposeUrl) {
  try {
    Invoke-WebRequest -Uri $ComposeUrl -OutFile $compose -UseBasicParsing
    Write-Host "compose.yml 을 받았습니다: $compose"
  } catch {
    if (-not (Test-Path $compose)) {
      Write-Host "compose.yml 을 받지 못했습니다: $($_.Exception.Message)"
      Write-Host "브라우저로 받은 compose.yml 을 $DataDir 에 저장한 뒤 다시 실행하세요."
      Read-Host "Enter 로 닫기"; exit 1
    }
    Write-Host "받지 못해 기존 compose.yml 을 씁니다."
  }
}
if (-not (Test-Path $compose)) {
  Write-Host "compose.yml 이 없습니다. 학생 화면의 설치 안내에서 받아 $DataDir 에 저장하세요."
  Read-Host "Enter 로 닫기"; exit 1
}

# 2. docker compose up -d
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Open-Help $EngineHelp "docker 명령을 찾지 못했습니다 — Docker Desktop 을 설치하세요."
  Read-Host "Enter 로 닫기"; exit 1
}
& docker compose -f $compose up -d
if ($LASTEXITCODE -ne 0) {
  Open-Help $EngineHelp "docker compose up 이 실패했습니다 — Docker Desktop 이 켜져 있고 Linux 컨테이너 모드인지 확인하세요."
  Read-Host "Enter 로 닫기"; exit 1
}

# 3. 응시 전 점검 — compose.yml 의 AGENT_TOKEN 으로 agent 에 묻는다
$token = ""
$m = [regex]::Match((Get-Content $compose -Raw -Encoding UTF8), 'AGENT_TOKEN\s*[:=]\s*"?([^"\s]+)"?')
if ($m.Success) { $token = $m.Groups[1].Value }
$headers = @{ Authorization = "Bearer $token" }

$result = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  try {
    $result = Invoke-RestMethod -Uri "$AgentUrl/api/preflight" -Headers $headers -TimeoutSec 15
    break
  } catch {
    Start-Sleep -Seconds 2
  }
}

if (-not $result) {
  Open-Help $EngineHelp "agent 가 응답하지 않습니다($WaitSeconds 초) — Docker Desktop 상태를 확인하세요."
  Read-Host "Enter 로 닫기"; exit 1
}

if (-not $result.ok) {
  $opened = @{}
  foreach ($c in $result.checks) {
    if (-not $c.ok) {
      Write-Host "[$($c.id)] $($c.message)"
      if ($c.help_url -and -not $opened.ContainsKey($c.help_url)) {
        $opened[$c.help_url] = $true
        Open-Help $c.help_url "점검 실패: $($c.id)"
      }
    }
  }
  Read-Host "문제를 해결한 뒤 다시 실행하세요. Enter 로 닫기"; exit 1
}

Write-Host "응시 전 점검을 모두 통과했습니다."
if ($DashboardUrl) { Start-Process $DashboardUrl }
