#!/usr/bin/env bash
# rtsp-tracking 설치 (리눅스·맥) — git clone 한 폴더에서 `./setup.sh` 한 번이면 설치·실행까지 끝.
# 다시 실행해도 안전하다: 이미 채운 .env 값은 그대로 두고, 새 버전 이미지를 받아 다시 켠다.
# 윈도우 PC 에서는 setup.cmd 를 더블클릭한다 (같은 순서로 같은 일을 한다).
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# ── 1. Docker ──
step "Docker 확인"
command -v docker >/dev/null 2>&1 \
  || die "Docker 가 없어요. https://docs.docker.com/get-docker/ 에서 설치한 뒤 다시 실행하세요."
if ! out=$(docker info 2>&1); then
  case "$out" in
    *"permission denied"*) die "이 사용자는 Docker 권한이 없어요. 'sudo usermod -aG docker \$USER' 실행 후 다시 로그인하세요." ;;
  esac
  die "Docker 가 꺼져 있어요. Docker Desktop(또는 docker 서비스)을 켠 뒤 다시 실행하세요."
fi
docker compose version >/dev/null 2>&1 || die "docker compose 가 없어요. Docker 를 최신으로 업데이트하세요."
ok "Docker 사용 가능"

# ── 2. .env ──
env_get() { sed -n "s/^$1=//p" .env | tail -1; }
env_set() {  # KEY VALUE — 있으면 바꾸고, 없으면 덧붙인다
  if grep -q "^$1=" .env; then
    (umask 077; K="$1" V="$2" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' .env > .env.tmp)
    mv .env.tmp .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
env_del() { (umask 077; awk -v k="$1" 'index($0, k "=") != 1' .env > .env.tmp); mv .env.tmp .env; }
rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
port_busy() {
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then return 0; fi
  if command -v ss >/dev/null 2>&1; then
    ss -Htuln 2>/dev/null | awk '{print $5}' | grep -E "[:.]$1\$" >/dev/null && return 0
  elif command -v lsof >/dev/null 2>&1; then
    # busybox lsof(alpine)는 옵션을 무시하고 늘 0 을 돌려준다 → 모든 포트가 '사용 중' 이 되어 무한 반복했다.
    # 반환값 말고 출력에 그 포트가 실제로 있는지 본다.
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -iUDP:"$1" 2>/dev/null | grep -E "[:.]$1( |\$)" >/dev/null && return 0
  fi
  return 1
}

step "설정 파일 (.env)"
[ -f .env.example ] || die ".env.example 이 없어요 — 올바른 폴더인지 확인하세요."
fresh=0
if [ ! -f .env ]; then cp .env.example .env; chmod 600 .env; fresh=1; ok ".env.example → .env 복사"; fi
if [ -n "$(tail -c1 .env)" ]; then echo >> .env; fi
asks=""; q=""; new_keys=" "
while IFS= read -r line || [ -n "$line" ]; do  # .env.example 에 새로 생긴 항목 덧붙이기 + '# 묻기:' 질문 모으기
  case "$line" in
    '# 묻기:'*) q=$(printf '%s' "${line#"# 묻기:"}" | sed 's/^ *//'); continue ;;
    ''|'#'*) q=""; continue ;;
  esac
  key=${line%%=*}
  if [ -n "$q" ]; then asks="$asks$key|$q
"; q=""; fi
  if ! grep -q "^$key=" .env; then printf '%s\n' "$line" >> .env; new_keys="$new_keys$key "; ok "새 항목 $key"; fi
done < .env.example

keys=$(sed -n 's/^\([A-Za-z0-9_]*\)=.*/\1/p' .env)
used=" "
for key in $keys; do  # 이미 정해진 포트 — 새로 고를 때 피한다
  case "$key" in *_PORT) v=$(env_get "$key"); if [ -n "$v" ]; then used="$used$v "; fi ;; esac
done
next=18000
for key in $keys; do
  v=$(env_get "$key")
  case "$key" in
    *_PORT)
      # 빈 칸이거나, 방금 복사한 기본값이 이 PC 에서 이미 쓰이는 중이면 빈 포트를 고른다
      if [ -z "$v" ] || { [ $fresh = 1 ] && port_busy "$v"; }; then
        tries=0
        while port_busy "$next" || case "$used" in *" $next "*) true ;; *) false ;; esac; do
          next=$((next + 1)); tries=$((tries + 1))
          [ $tries -lt 2000 ] || die "빈 포트를 찾지 못했어요 (2000개가 모두 사용 중으로 보임) — 개발자에게 알려 주세요."
        done
        env_set "$key" "$next"; used="$used$next "; ok "$key=$next"; next=$((next + 1))
      fi ;;
    *_PASS|*_SECRET)
      if [ -z "$v" ]; then env_set "$key" "$(rand)"; ok "$key 자동 생성"; fi ;;
  esac
done

# 설치하는 사람만 아는 값 — .env.example 에서 바로 윗줄이 '# 묻기: <질문>' 인 칸. 짐작해서 채우지 않고 묻는다.
# 처음 설치할 때와 새로 생긴 칸만 (다시 실행할 때마다 묻지 않음). Enter = 비워 둠.
if [ -n "$asks" ]; then
  tty=0; if [ -t 0 ] && [ -r /dev/tty ]; then tty=1; fi
  # 참고용 이 PC 주소 — docker·가상 브리지(br-·docker0·veth·virbr·bridge)는 빼고
  ips=""
  if command -v ip >/dev/null 2>&1; then
    ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|virbr|bridge)/ {split($4, a, "/"); printf "%s(%s) ", a[1], $2}') || ips=""
  fi
  if [ -z "$ips" ] && command -v ifconfig >/dev/null 2>&1; then
    ips=$(ifconfig 2>/dev/null | awk '/^[a-z]/{n=$1; sub(/:$/, "", n)} /inet / && $2 != "127.0.0.1" && n !~ /^(docker|br-|veth|virbr|bridge)/ {printf "%s(%s) ", $2, n}') || ips=""
  fi
  while IFS='|' read -r key q; do
    [ -n "$key" ] || continue
    if [ -n "$(env_get "$key")" ]; then continue; fi
    case "$fresh$new_keys" in 1*|*" $key "*) ;; *) continue ;; esac
    if [ $tty = 0 ]; then warn "$key 비워 둠 (물어볼 화면 없음) — 필요하면 .env 에 직접 쓰고 다시 실행"; continue; fi
    printf '\n  ? %s\n' "$q"
    case "$key" in *_HOST|*_IP) if [ -n "$ips" ]; then printf '    참고 — 이 PC 의 IP: %s\n' "$ips"; fi ;; esac
    printf '  > '
    if [ "$key" = HF_TOKEN ]; then
      IFS= read -rs ans </dev/tty || ans=""
      printf '\n'
    else
      IFS= read -r ans </dev/tty || ans=""
    fi
    ans=$(printf '%s' "$ans" | sed 's/^ *//; s/ *$//')
    if [ "$key" = MEDIAMTX_WEBRTC_HOST ]; then
      ans=$(printf '%s' "$ans" | sed 's/[[:blank:]]*,[[:blank:]]*/,/g')
    fi
    if [ -n "$ans" ]; then env_set "$key" "$ans"; ok "$key 저장"; else ok "$key 비워 둠"; fi
  done <<EOF
$asks
EOF
fi

if [ -z "$(env_get HF_TOKEN)" ] && [ "$(env_get TRACKER_DEFAULT)" = sam3 ]; then
  env_set TRACKER_DEFAULT yolo-botsort
  ok "HF_TOKEN이 비어 있어 기본 추적기를 YOLO+BoT-SORT로 설정했습니다. SAM3를 쓰려면 .env에 토큰을 넣고 TRACKER_DEFAULT=sam3로 바꾼 뒤 다시 실행하세요."
fi

chmod 600 .env  # 비밀번호가 들어 있다 — 나만 읽게 (전부터 있던 .env 도)

step "설정 검사"
docker compose config -q || die ".env 파일의 설정을 확인한 뒤 다시 실행하세요."

step "MediaMTX와 추론 서버 준비"
# --policy 는 Compose 2.22 부터 — 그 전 버전은 이 옵션을 몰라 실패하므로 그때는 그냥 받는다
docker compose pull --policy missing mediamtx || docker compose pull mediamtx || die "MediaMTX 이미지를 받지 못했어요. 인터넷 연결을 확인하세요."
if ! docker compose pull backend; then
  warn "추론 서버 이미지를 받을 수 없어 이 PC에서 만듭니다. 처음에는 시간이 걸릴 수 있어요."
  docker compose build backend || die "추론 서버 이미지를 만들지 못했어요."
fi
ok "추적 모델은 처음 사용할 때 받습니다."

step "시청 화면 만들기"
docker compose build frontend || die "시청 화면을 만들지 못했어요."

step "추론 장치 확인"
# 설치한 추론 이미지에서 CUDA를 확인해야 Docker가 접근할 수 있는 GPU만 선택한다.
if docker run --rm --network none --pull never --gpus all --entrypoint python \
    ghcr.io/jskim1102/rtsp-tracking-backend:latest \
    -c 'import sys, torch; sys.exit(not torch.cuda.is_available())' >/dev/null 2>&1; then
  env_set COMPOSE_PATH_SEPARATOR ":"
  env_set COMPOSE_FILE "docker-compose.yml:docker-compose.gpu.yml"
  ok "NVIDIA GPU로 실행합니다."
else
  env_del COMPOSE_FILE
  env_del COMPOSE_PATH_SEPARATOR
  ok "Docker에서 사용할 수 있는 NVIDIA GPU가 없어 CPU로 실행합니다."
fi

step "서비스 시작"
if ! docker compose up -d --no-build --pull never --wait --wait-timeout 900; then
  docker compose ps
  die "서비스 시작에 실패했어요. docker compose logs 로 원인을 확인하세요."
fi

printf '\n설치 완료 — 브라우저에서 http://localhost:%s 에 접속하세요.\n' "$(env_get FRONTEND_PORT)"
