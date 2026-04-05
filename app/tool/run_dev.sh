#!/usr/bin/env bash
# Flutter 디버그 실행 래퍼.
# 현재 개발 머신의 Wi-Fi IP를 자동 감지해서 AppConfig에 dart-define으로 주입한다.
#
# 사용법:
#   ./tool/run_dev.sh                       # 기본 3000 포트
#   ./tool/run_dev.sh --port 4000           # 포트 지정
#   ./tool/run_dev.sh -- -d <device_id>     # -- 이후 인자는 flutter run 에 그대로 전달
#
# 서버가 실행 중이어야 한다:
#   cd server && npm run dev

set -euo pipefail

PORT=3000
FLUTTER_ARGS=()

# 인자 파싱
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --)
      shift
      FLUTTER_ARGS+=("$@")
      break
      ;;
    *)
      FLUTTER_ARGS+=("$1")
      shift
      ;;
  esac
done

# 현재 IP 감지: 디폴트 라우트가 나가는 인터페이스를 찾아 그 IP 사용
detect_ip() {
  # macOS: 디폴트 라우트의 인터페이스 찾기
  local iface
  iface=$(route -n get default 2>/dev/null | awk '/interface: / {print $2}') || true
  if [[ -n "${iface:-}" ]]; then
    local ip
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  fi

  # 폴백: en0 (Wi-Fi), 그 다음 en1
  for candidate in en0 en1 en2 en3; do
    local ip
    ip=$(ipconfig getifaddr "$candidate" 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  done

  return 1
}

if ! IP=$(detect_ip); then
  echo "❌ 현재 머신의 IP를 감지하지 못했습니다. Wi-Fi 연결 상태를 확인하세요." >&2
  exit 1
fi

DEV_SERVER_URL="http://${IP}:${PORT}"

echo "🔍 Detected dev machine IP: ${IP}"
echo "🎯 DEV_SERVER_URL=${DEV_SERVER_URL}"
echo "🚀 flutter run --dart-define=DEV_SERVER_URL=${DEV_SERVER_URL} ${FLUTTER_ARGS[*]:-}"
echo ""

# 스크립트 위치 기준으로 app 디렉터리에서 실행
cd "$(dirname "$0")/.."

exec flutter run \
  --dart-define=DEV_SERVER_URL="${DEV_SERVER_URL}" \
  "${FLUTTER_ARGS[@]}"
