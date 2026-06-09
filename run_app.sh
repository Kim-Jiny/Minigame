#!/bin/bash
# Flutter 앱만 실행하되, 이 머신의 LAN IP 를 감지해 로컬 서버를 바라보게 한다
# (서버는 ./run_server.sh 로 따로 띄워야 함). 같은 Wi-Fi 의 실기기에서도 접속 가능.
#
# 그냥 `flutter run` (스크립트 없이) 하면 디버그 폴백 IP 를 쓴다.
# 릴리즈 빌드는 영향 없음 — 프로덕션 API(https://duo.jiny.shop)를 유지한다.
#
# 사용법:
#   ./run_app.sh                 # 연결된 기기/시뮬레이터로 실행
#   ./run_app.sh -d <device_id>  # flutter run 인자는 그대로 전달
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SERVER_PORT=3000

# --- LAN IP 감지: 디폴트 라우트 인터페이스 → en0/en1 폴백 ---
detect_ip() {
  local iface
  iface=$(route -n get default 2>/dev/null | awk '/interface: / {print $2}') || true
  if [ -n "${iface:-}" ]; then
    local ip
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  for candidate in en0 en1 en2 en3; do
    local ip
    ip=$(ipconfig getifaddr "$candidate" 2>/dev/null || true)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  return 1
}

if ! IP=$(detect_ip); then
  echo "✗ LAN IP 감지 실패 (en0/en1). Wi-Fi 연결 후 다시 시도하세요." >&2
  exit 1
fi

DEV_SERVER_URL="http://${IP}:${SERVER_PORT}"
echo "▶ App → $DEV_SERVER_URL  (서버 실행 필요: ./run_server.sh)"

cd "$ROOT/app"
exec flutter run --dart-define=DEV_SERVER_URL="$DEV_SERVER_URL" "$@"
