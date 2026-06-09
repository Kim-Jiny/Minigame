# Minigame 리포 — 두 제품이 공존하는 모노리포

이 리포에는 **두 개의 독립 제품**이 같은 서버(Express+TS+PostgreSQL, Render 배포)를 공유한다.

| 제품 | 프리픽스 | 앱 소스 위치 | 약관 경로 |
|------|----------|--------------|-----------|
| 듀오 아레나 (DUO) | `dm_` | 이 리포 `app/` (Flutter) | `/duo/*` |
| CatchTheRule (규칙찾기) | `ctr_` | **별도 리포** `~/Documents/Jiny/CatchTheRule` (iOS Swift / Android Kotlin) | `/ctr/*` |

서버 DB 테이블·라우트·정적페이지는 **프리픽스로 소유권을 구분**한다. `dm_` = 듀오, `ctr_` = 규칙찾기.

---

## ⚠️ CatchTheRule(ctr) 자산 — 삭제·리팩터링 금지

> **듀오 아레나 작업 중 아래 파일/구역을 "안 쓰는 것 같다"고 지우지 말 것.**
> CatchTheRule 앱(별도 리포)이 운영 중 호출하는 라이브 백엔드다. 삭제 후 배포되면 서비스가 깨진다.
> CatchTheRule 관련 변경이 필요하면 먼저 사용자에게 확인할 것.

### CTR 전용 파일 (파일 전체가 CTR 소유)

| 파일 | 용도 |
|------|------|
| `server/src/routes/catchtherule.ts` | 앱용 공개 API — 랭킹(`scores`/`leaderboard`), 문의(`inquiries`), 통계(`devices/ping`), 서버 제공 추가 스테이지, IAP 검증. 로그인 없이 deviceId 기반. |
| `server/src/services/ctrIap.ts` | 인앱결제 영수증 검증 (iOS StoreKit2 JWS / Android Play 서명). |
| `server/src/services/ctrPuzzleValidate.ts` | 서버 제공 추가 스테이지 검증 (번들 puzzles.json 과 동일 스키마, 7개국어). |
| `server/public/ctr/terms.html` `privacy.html` `support.html` | 약관·개인정보·고객지원 페이지 (7개국어). 앱 설정 탭이 `https://duo.jiny.shop/ctr/*` 로 연다. |

### 공용 파일 안의 CTR 구역 (해당 줄/블록만 CTR 소유)

| 파일 | CTR 구역 |
|------|----------|
| `server/src/index.ts` | `import catchTheRuleRouter`, `app.use('/api/catchtherule', ...)`, `app.use('/ctr', static ...)` |
| `server/src/config/database.ts` | `ctr_rankings` · `ctr_inquiries` · `ctr_devices` · `ctr_device_daily` 등 `ctr_` 테이블 생성 블록 |
| `server/src/routes/admin.ts` | `/api/admin/ctr/*` 엔드포인트 + `ctrPuzzleValidate` import |
| `server/public/admin/index.html` | `GAMES` 배열의 `{ id: 'ctr', ... }` 카드 + `#ctrDashboard` 섹션 + 관련 표시/숨김 로직 |
| `server/.env.example` | `CTR_PLAY_PUBLIC_KEY`, `CTR_APPLE_ROOT_SHA256` |

각 위치에는 `[CTR]` 마커 주석이 달려 있다. `git grep -n "\[CTR\]"` 로 전체를 확인할 수 있다.
