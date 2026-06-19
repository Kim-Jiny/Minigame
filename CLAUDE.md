# Minigame 리포 — 여러 제품이 공존하는 모노리포

이 리포에는 **여러 독립 제품**이 같은 서버(Express+TS+PostgreSQL, self-host 배포)를 공유한다.

| 제품 | 프리픽스 | 앱 소스 위치 | 약관 경로 |
|------|----------|--------------|-----------|
| 듀오 아레나 (DUO) | `dm_` | 이 리포 `app/` (Flutter) | `/duo/*` |
| CatchTheRule (규칙찾기) | `ctr_` | **별도 리포** `~/Documents/Jiny/CatchTheRule` (iOS Swift / Android Kotlin) | `/ctr/*` |
| 사자툰 (SajaToon) | `sj_` | **별도 리포** `~/Documents/Jiny/SajaToon` (Android Kotlin / 추후 iOS) | `/saja/*` |
| 성인의 수학 (MathForAdults) | `mfa_` | **별도 리포** `~/Documents/Jiny/MathForAdults` | `/mfa/*` |
| 라비린스 (Labyrinth) | `lab_` | **별도 리포 + 별도 서버** `~/Documents/Jiny/LabyrinthOnline` (서버 독립 컨테이너 / iOS SwiftUI / Android Compose) | 라비린스 서버가 자체 제공 |

서버 DB 테이블·라우트·정적페이지는 **프리픽스로 소유권을 구분**한다. `dm_` = 듀오, `ctr_` = 규칙찾기, `sj_` = 사자툰, `mfa_` = 성인의 수학, `lab_` = 라비린스.
단, **라비린스만 서버 코드가 이 리포에 없다** — 별도 리포의 독립 컨테이너로 배포되고, 이 리포와는 같은 PostgreSQL(`lab_*` 테이블)과 `JWT_SECRET` 만 공유한다. 아래 [LAB] 섹션 참고.

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

---

## ⚠️ SajaToon(saja) 자산 — 삭제·리팩터링 금지

> **듀오 아레나/다른 제품 작업 중 아래 파일/구역을 "안 쓰는 것 같다"고 지우지 말 것.**
> 사자툰 앱(별도 리포 `~/Documents/Jiny/SajaToon`)이 운영 중 호출하는 라이브 백엔드다.
> 삭제 후 배포되면 서비스가 깨진다. SajaToon 관련 변경이 필요하면 먼저 사용자에게 확인할 것.

### SAJA 전용 파일 (파일 전체가 SajaToon 소유)

| 파일 | 용도 |
|------|------|
| `server/src/routes/sajatoon.ts` | 앱용 공개 API — 사자성어 콘텐츠(`idioms`), 익명 통계(`devices/ping`), 학습 진도 동기화(`progress`). 로그인 없이 deviceId 기반. |

### 공용 파일 안의 SAJA 구역 (해당 줄/블록만 SajaToon 소유)

| 파일 | SAJA 구역 |
|------|----------|
| `server/src/index.ts` | `import sajatoonRouter`, `app.use('/api/sajatoon', ...)`, `app.use('/saja', static ...)` |
| `server/src/config/database.ts` | `sj_idioms`(컬럼 `images` 포함) · `sj_devices` · `sj_device_daily` · `sj_progress` 등 `sj_` 테이블 생성 블록 + `seedSajatoonIdioms()` 함수 |
| `server/src/routes/admin.ts` | `/api/admin/saja/*` 엔드포인트(사자성어 등록·수정·삭제·통계) |
| `server/public/admin/index.html` | `GAMES` 배열의 `{ id: 'saja', ... }` 카드 + `#sajaDashboard` 섹션 + `saja*` JS 함수 + `.saja-*` CSS |
| `server/public/saja/` | 만화 이미지(`/saja/comics/*`)·약관 정적 자산. SajaToon 소유. |

각 위치에는 `[SAJA]` 마커 주석이 달려 있다. `git grep -n "\[SAJA\]"` 로 전체를 확인할 수 있다.

---

## ⚠️ MathForAdults(mfa) 자산 — 삭제·리팩터링 금지

> **듀오 아레나/다른 제품 작업 중 아래 파일/구역을 "안 쓰는 것 같다"고 지우지 말 것.**
> 성인의 수학 앱(별도 리포 `~/Documents/Jiny/MathForAdults`)이 운영 중 호출하는 라이브 백엔드다.
> 삭제 후 배포되면 서비스가 깨진다. 성인의 수학 관련 변경이 필요하면 먼저 사용자에게 확인할 것.

### MFA 전용 파일 (파일 전체가 성인의 수학 소유)

| 파일 | 용도 |
|------|------|
| `server/src/routes/mathforadults.ts` | 앱용 공개 API — 문의 등록/조회(`inquiries`), 답변 읽음 처리(`inquiries/read`). 로그인 없이 deviceId 기반. |

### 공용 파일 안의 MFA 구역 (해당 줄/블록만 성인의 수학 소유)

| 파일 | MFA 구역 |
|------|----------|
| `server/src/index.ts` | `import mathForAdultsRouter`, `app.use('/api/mathforadults', ...)`, `app.use('/mfa', static ...)` |
| `server/src/config/database.ts` | `mfa_inquiries` 등 `mfa_` 테이블 생성 블록 |
| `server/src/routes/admin.ts` | `/api/admin/mfa/*` 엔드포인트(문의 목록·답변·삭제) |
| `server/public/admin/index.html` | `GAMES` 배열의 `{ id: 'mfa', ... }` 카드 + `#mfaDashboard` 섹션 + `#mfaInquiryModal` 모달 + `loadMfaInquiries`/`replyMfaInquiry` 등 `mfa*` JS 함수 |
| `server/public/mfa/` | 약관·개인정보·고객지원 정적 페이지(`/mfa/privacy`, `/mfa/support`). 성인의 수학 소유. |

각 위치에는 `[MFA]` 마커 주석이 달려 있다. `git grep -n "\[MFA\]"` 로 전체를 확인할 수 있다.

---

## ⚠️ Labyrinth(lab) — 코드는 별도 리포·별도 서버, 그러나 DB는 공유

> **라비린스 서버 코드는 이 리포에 없다.** 별도 리포 `~/Documents/Jiny/LabyrinthOnline`
> (서버: `server/`, 클라이언트: `ios/` SwiftUI · `android/` Compose)에 있고, **독립 도커
> 컨테이너로 따로 배포**된다(배포 격리 — 라비린스 배포가 듀오/CTR/사자툰에 영향 없음).

**이 리포(듀오)와 공유하는 것은 딱 2가지:**

1. **PostgreSQL 인스턴스(`duo-db`)** — 라비린스가 같은 DB 안에 자기 소유의 `lab_*` 테이블
   (`lab_matches`, `lab_match_players`, `lab_user_stats`)을 둔다. **그 테이블은 라비린스
   서버가 직접 생성·관리한다.** 듀오 서버(`config/database.ts`)는 lab_* 를 만들지도 지우지도
   않는다. DB 정리 중 `lab_*` 가 보여도 "안 쓰는 테이블"이 아니다 — 운영 중인 라비린스
   서비스 데이터다. **드롭 금지.**
2. **`JWT_SECRET`** — 라비린스 서버가 듀오 발급 토큰의 `userId` 를 검증하는 데 쓴다(전적
   귀속용). 라비린스는 `dm_users` 등 남의 테이블을 **읽지도 쓰지도 않는다**(닉네임은
   클라이언트 제공값 사용).

### 이 리포에서 라비린스 관련으로 남아있는 것

| 파일 | LAB 구역 |
|------|----------|
| `server/src/config/database.ts` | `sj_progress` 인덱스 다음의 `[LAB] 참고` 주석(공유 DB에 lab_* 가 있으니 드롭 말라는 안내). 테이블 생성 코드는 **없음**(라비린스 서버가 만듦). |

`git grep -n "\[LAB\]"` 로 확인. 라비린스 자체 코드/스키마 변경이 필요하면 이 리포가 아니라
`~/Documents/Jiny/LabyrinthOnline` 에서 작업할 것.
