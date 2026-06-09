#!/bin/bash
# 로컬 서버만 실행한다 (앱은 ./run_app.sh 로 따로 실행).
# npm run dev 는 NODE_ENV=development 로 동작해서 DB 호스트를
# duo-db → localhost(:5432) 로 자동 치환한다. (server/src/config/database.ts)
# 그래서 Homebrew Postgres(:5432, duo DB)가 떠 있어야 한다.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

# 로컬 Postgres(Homebrew) 보장
if ! brew services list 2>/dev/null | grep -qE '^postgresql@16\s+started'; then
  echo "▶ Starting postgresql@16…"
  brew services start postgresql@16
  sleep 2
fi

cd "$ROOT/server"

# 의존성 미설치 시 한 번 설치
if [ ! -d node_modules ]; then
  echo "▶ Installing server deps (npm install)…"
  npm install
fi

echo "▶ Server → http://localhost:3000  (DB: localhost:5432/duo)"
exec npm run dev
