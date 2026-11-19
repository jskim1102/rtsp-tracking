# rtsp-tracking 설치 (윈도우) — git clone 한 폴더에서 setup.cmd 를 더블클릭하면 설치·실행까지 끝.
# 다시 실행해도 안전하다: 이미 채운 .env 값은 그대로 두고, 새 버전 이미지를 받아 다시 켠다.
# 리눅스·맥에서는 ./setup.sh 를 실행한다 (같은 순서로 같은 일을 한다).
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
Set-Location -LiteralPath $Root

function Step($m) { Write-Host ''; Write-Host "> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK $m" }
function Warn($m) { Write-Host "  !  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host ''; Write-Host "X $m" -ForegroundColor Red; exit 1 }

# ── 1. Docker ──
Step 'Docker 확인'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die 'Docker Desktop 이 없어요. https://docs.docker.com/desktop/setup/install/windows-install/ 에서 설치한 뒤 다시 실행하세요.'
}
$null = & docker info 2>&1
if ($LASTEXITCODE -ne 0) { Die 'Docker Desktop 이 꺼져 있어요. Docker Desktop 을 켜고, 다 켜질 때까지 기다린 뒤 다시 실행하세요.' }
$null = & docker compose version 2>&1
if ($LASTEXITCODE -ne 0) { Die 'docker compose 가 없어요. Docker Desktop 을 최신으로 업데이트하세요.' }
Ok 'Docker 사용 가능'

# ── 2. .env ──
$EnvPath = Join-Path $Root '.env'
$ExPath = Join-Path $Root '.env.example'
$Utf8 = New-Object System.Text.UTF8Encoding $false
function EnvGet($k) { $v = $null; foreach ($l in $script:Lines) { if ($l.StartsWith("$k=")) { $v = $l.Substring($k.Length + 1) } }; return $v }
function EnvSet($k, $v) {
  for ($i = 0; $i -lt $script:Lines.Count; $i++) { if ($script:Lines[$i].StartsWith("$k=")) { $script:Lines[$i] = "$k=$v"; return } }
  [void]$script:Lines.Add("$k=$v")
}
function EnvDel($k) { $script:Lines = [Collections.ArrayList]@($script:Lines | Where-Object { -not $_.StartsWith("$k=") }) }
function EnvSave {
  $ErrorActionPreference = 'Stop'
  [IO.File]::WriteAllText($EnvPath, (($script:Lines -join "`n") + "`n"), $Utf8)
}
function Rand { $b = New-Object byte[] 12; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) }
# Hyper-V·WSL 이 막아 둔 포트 구간 — 비어 보여도 Docker 가 못 쓴다
$Excluded = @()
foreach ($l in (& netsh interface ipv4 show excludedportrange protocol=tcp 2>$null)) {
  if ($l -match '^\s*(\d+)\s+(\d+)') { $Excluded += , @([int]$matches[1], [int]$matches[2]) }
}
function PortBusy([int]$p) {
  foreach ($r in $Excluded) { if ($p -ge $r[0] -and $p -le $r[1]) { return $true } }
  if (Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue) { return $true }
  if (Get-NetUDPEndpoint -LocalPort $p -ErrorAction SilentlyContinue) { return $true }
  return $false
}

Step '설정 파일 (.env)'
if (-not (Test-Path -LiteralPath $ExPath)) { Die '.env.example 이 없어요 - 올바른 폴더인지 확인하세요.' }
$fresh = $false
if (Test-Path -LiteralPath $EnvPath) {
  $script:Lines = [Collections.ArrayList]@([IO.File]::ReadAllLines($EnvPath))
} else {
  $script:Lines = [Collections.ArrayList]@([IO.File]::ReadAllLines($ExPath)); $fresh = $true; Ok '.env.example -> .env 복사'
}
$asks = [ordered]@{}; $q = $null; $newKeys = @{}
foreach ($line in [IO.File]::ReadAllLines($ExPath)) {  # .env.example 에 새로 생긴 항목 덧붙이기 + '# 묻기:' 질문 모으기
  if ($line.StartsWith('# 묻기:')) { $q = $line.Substring(5).Trim(); continue }
  if ($line -match '^([A-Za-z0-9_]+)=') {
    $k = $matches[1]
    if ($q) { $asks[$k] = $q }
    if ($null -eq (EnvGet $k)) { [void]$script:Lines.Add($line); $newKeys[$k] = 1; Ok "새 항목 $k" }
  }
  $q = $null
}
$keys = @($script:Lines | Where-Object { $_ -match '^[A-Za-z0-9_]+=' } | ForEach-Object { $_.Split('=')[0] })
$used = @{}
foreach ($k in $keys) { if ($k.EndsWith('_PORT')) { $v = EnvGet $k; if ($v) { $used[$v] = 1 } } }
$next = 18000
foreach ($k in $keys) {
  $v = EnvGet $k
  if ($k.EndsWith('_PORT')) {
    # 빈 칸이거나, 방금 복사한 기본값이 이 PC 에서 이미 쓰이는 중이면 빈 포트를 고른다
    if (-not $v -or ($fresh -and (PortBusy ([int]$v)))) {
      while ((PortBusy $next) -or $used.ContainsKey("$next")) { $next++ }
      EnvSet $k "$next"; $used["$next"] = 1; Ok "$k=$next"; $next++
    }
  } elseif ($k.EndsWith('_PASS') -or $k.EndsWith('_SECRET')) {
    if (-not $v) { EnvSet $k (Rand); Ok "$k 자동 생성" }
  }
}
# 설치하는 사람만 아는 값 — .env.example 에서 바로 윗줄이 '# 묻기: <질문>' 인 칸. 짐작해서 채우지 않고 묻는다.
# 처음 설치할 때와 새로 생긴 칸만 (다시 실행할 때마다 묻지 않음). Enter = 비워 둠.
if ($asks.Count -gt 0) {
  # 참고용 이 PC 주소 — WSL·Hyper-V 가상 어댑터(vEthernet)는 빼고
  $ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
      $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike 'vEthernet*' } |
    ForEach-Object { "$($_.IPAddress)($($_.InterfaceAlias))" }) -join ' '
  foreach ($k in @($asks.Keys)) {
    if (EnvGet $k) { continue }
    if (-not ($fresh -or $newKeys.ContainsKey($k))) { continue }
    if ([Console]::IsInputRedirected) { Warn "$k 비워 둠 (물어볼 화면 없음) - 필요하면 .env 에 직접 쓰고 다시 실행"; continue }
    Write-Host ''; Write-Host "  ? $($asks[$k])"
    if (($k.EndsWith('_HOST') -or $k.EndsWith('_IP')) -and $ips) { Write-Host "    참고 - 이 PC 의 IP: $ips" }
    if ($k -eq 'HF_TOKEN') {
      $secret = Read-Host '  ' -AsSecureString
      $ans = [Net.NetworkCredential]::new('', $secret).Password.Trim()
    } else {
      $ans = "$(Read-Host '  ')".Trim()
    }
    if ($k -eq 'MEDIAMTX_WEBRTC_HOST') {
      $ans = $ans -replace '\s*,\s*', ','
    }
    if ($ans) { EnvSet $k $ans; Ok "$k 저장" } else { Ok "$k 비워 둠" }
  }
}

if (-not (EnvGet 'HF_TOKEN') -and (EnvGet 'TRACKER_DEFAULT') -ceq 'sam3') {
  EnvSet 'TRACKER_DEFAULT' 'yolo-botsort'
  Ok 'HF_TOKEN이 비어 있어 기본 추적기를 YOLO+BoT-SORT로 설정했습니다. SAM3를 쓰려면 .env에 토큰을 넣고 TRACKER_DEFAULT=sam3로 바꾼 뒤 다시 실행하세요.'
}

EnvSave
Step '설정 검사'
& docker compose config -q
if ($LASTEXITCODE -ne 0) { Die '.env 파일의 설정을 확인한 뒤 다시 실행하세요.' }

Step 'MediaMTX와 추론 서버 준비'
& docker compose pull --policy missing mediamtx
if ($LASTEXITCODE -ne 0) { Die 'MediaMTX 이미지를 받지 못했어요. 인터넷 연결을 확인하세요.' }
& docker compose pull backend
if ($LASTEXITCODE -ne 0) {
  Warn '추론 서버 이미지를 받을 수 없어 이 PC에서 만듭니다. 처음에는 시간이 걸릴 수 있어요.'
  & docker compose build backend
  if ($LASTEXITCODE -ne 0) { Die '추론 서버 이미지를 만들지 못했어요.' }
}
Ok '추적 모델은 처음 사용할 때 받습니다.'

Step '시청 화면 만들기'
& docker compose build frontend
if ($LASTEXITCODE -ne 0) { Die '시청 화면을 만들지 못했어요.' }

Step '추론 장치 확인'
# 설치한 추론 이미지에서 CUDA를 확인해야 Docker가 접근할 수 있는 GPU만 선택한다.
$null = & docker run --rm --network none --pull never --gpus all --entrypoint python `
    ghcr.io/jskim1102/rtsp-tracking-backend:latest `
    -c 'import sys, torch; sys.exit(not torch.cuda.is_available())' 2>&1
if ($LASTEXITCODE -eq 0) {
  EnvSet 'COMPOSE_PATH_SEPARATOR' ':'
  EnvSet 'COMPOSE_FILE' 'docker-compose.yml:docker-compose.gpu.yml'
  Ok 'NVIDIA GPU로 실행합니다.'
} else {
  EnvDel 'COMPOSE_FILE'
  EnvDel 'COMPOSE_PATH_SEPARATOR'
  Ok 'Docker에서 사용할 수 있는 NVIDIA GPU가 없어 CPU로 실행합니다.'
}
EnvSave

Step '서비스 시작'
& docker compose up -d --no-build --pull never --wait --wait-timeout 900
if ($LASTEXITCODE -ne 0) {
  & docker compose ps
  Die '서비스 시작에 실패했어요. docker compose logs 로 원인을 확인하세요.'
}

$port = EnvGet 'FRONTEND_PORT'
Write-Host ''
Write-Host "설치 완료 — 브라우저에서 http://localhost:$port 에 접속하세요." -ForegroundColor Green
