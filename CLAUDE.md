# Minigame 리포 — 여러 제품이 공존하는 모노리포

이 리포에는 **여러 독립 제품**이 같은 서버(Express+TS+PostgreSQL, self-host 배포)를 공유한다.

| 제품 | 프리픽스 | 앱 소스 위치 | 약관 경로 |
|------|----------|--------------|-----------|
| 듀오 아레나 (DUO) | `dm_` | 이 리포 `app/` (Flutter) | `/duo/*` |
| CatchTheRule (규칙찾기) | `ctr_` | **별도 리포** `~/Documents/Jiny/CatchTheRule` (iOS Swift / Android Kotlin) | `/ctr/*` |
| 사자툰 (SajaToon) | `sj_` | **별도 리포** `~/Documents/Jiny/SajaToon` (Android Kotlin / 추후 iOS) | `/saja/*` |
| 성인의 수학 (MathForAdults) | `mfa_` | **별도 리포** `~/Documents/Jiny/MathForAdults` | `/mfa/*` |
| 라비린스 (Labyrinth) | `lab_` | **별도 리포 + 별도 서버** `~/Documents/Jiny/LabyrinthOnline` (서버 독립 컨테이너 / iOS SwiftUI / Android Compose) | 라비린스 서버가 자체 제공 |
| PerlerPixel (비즈픽셀) | `pp_` | **별도 리포** `~/Documents/Jiny/PerlerPixel` (iOS SwiftUI / 추후 Android) | `/pp/*` |
| PokerStyle (홀덤 성향 테스트) | `ps_` | **별도 리포** `~/Documents/Jiny/JinyShop` 의 `/pokerstyle/` 웹도구 (정적 HTML/JS, 브라우저에서 이 서버 호출) | 없음 (웹도구가 자체 안내) |

서버 DB 테이블·라우트·정적페이지는 **프리픽스로 소유권을 구분**한다. `dm_` = 듀오, `ctr_` = 규칙찾기, `sj_` = 사자툰, `mfa_` = 성인의 수학, `lab_` = 라비린스, `pp_` = 비즈픽셀, `ps_` = PokerStyle.
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

---

## ⚠️ PerlerPixel(pp) 자산 — 삭제·리팩터링 금지

> **다른 제품 작업 중 아래 파일/구역을 "안 쓰는 것 같다"고 지우지 말 것.**
> 비즈픽셀 앱(별도 리포 `~/Documents/Jiny/PerlerPixel`, iOS SwiftUI)이 호출하는 라이브 백엔드다.
> 도안 공유 커뮤니티 게시판(소셜 로그인 + UGC). PerlerPixel 관련 변경은 먼저 사용자에게 확인할 것.

### PP 전용 파일 (파일 전체가 PerlerPixel 소유)

| 파일 | 용도 |
|------|------|
| `server/src/routes/perlerpixel.ts` | 앱 API — 소셜 로그인(`pp_users`), 게시판 리스트(비로그인)·상세/업로드/다운로드/신고/차단(로그인). 오리지널만 정책 + 사후 신고 모더레이션. |
| `server/src/services/ppAuth.ts` | Apple/Google/Kakao 토큰 검증 + `scope:'pp'` JWT + `pp_users` upsert/밴 조회. |
| `server/src/services/ppModeration.ts` | 금지어 필터, 신고 자동 비공개 임계치, unlisted 공유코드. |
| `server/public/pp/` | 약관·개인정보·커뮤니티 가이드라인·문의 정적 페이지 + 업로드 프리뷰(`/pp/uploads/*`). |

### 공용 파일 안의 PP 구역 (해당 줄/블록만 PerlerPixel 소유)

| 파일 | PP 구역 |
|------|----------|
| `server/src/index.ts` | `import perlerPixelRouter`, `app.use('/api/perlerpixel', ...)`, `app.use('/pp', static ...)` |
| `server/src/config/database.ts` | `pp_users`·`pp_posts`·`pp_likes`·`pp_downloads`·`pp_reports`·`pp_blocks`·`pp_hidden`·`pp_user_bans`·`pp_admin_logs`·`pp_banned_keywords` 생성 블록 |
| `server/src/routes/admin.ts` | `/api/admin/pp/*` 엔드포인트 (예정) |
| `server/public/admin/index.html` | `GAMES` 배열의 `{ id: 'pp', ... }` 카드 + `#ppDashboard` 섹션 (예정) |
| `server/.env.example` | `PP_GOOGLE_CLIENT_IDS`, `PP_APPLE_BUNDLE_IDS` |

각 위치에는 `[PP]` 마커 주석이 달려 있다. `git grep -n "\[PP\]"` 로 전체를 확인할 수 있다.

---

## ⚠️ PokerStyle(ps) 자산 — 삭제·리팩터링 금지

> **다른 제품 작업 중 아래 파일/구역을 "안 쓰는 것 같다"고 지우지 말 것.**
> jiny.shop 의 PokerStyle 웹도구(별도 리포 `~/Documents/Jiny/JinyShop`, `/pokerstyle/`)가 브라우저에서 직접 호출하는 라이브 백엔드다.
> 홀덤 성향 테스트 결과를 링크로 공유하고, 링크를 받은 사람이 "남들이 본 나"를 평가하는 기능이다.
> PokerStyle 관련 변경이 필요하면 먼저 사용자에게 확인할 것.

### 프리픽스 (이 제품이 소유하는 이름 공간)

| 종류 | 소유 범위 |
|------|-----------|
| DB 테이블 | `ps_profiles`, `ps_ratings` (그리고 앞으로 추가되는 `ps_*`) |
| API 라우트 | `/api/pokerstyle/*` |
| 환경변수 | `PS_*` (`PS_HASH_SALT`) |
| 코드 마커 | `[PS]` — `git grep -n "\[PS\]"` 로 전체 확인 |

`ps_` 로 시작하지 않는 테이블·라우트를 PokerStyle 이 만들거나 건드려서는 안 된다. 반대로 다른 제품이 `ps_*` 를 건드려서도 안 된다.
기존 공용 테이블(`dm_*` 듀오 / `ctr_*` / `sj_*` / `mfa_*` / `pp_*`)과 FK·조인 없이 **완전히 독립**이다 — 유저 테이블 참조 없음(로그인 없는 제품).

### PS 전용 파일 (파일 전체가 PokerStyle 소유)

| 파일 | 용도 |
|------|------|
| `server/src/routes/pokerstyle.ts` | 프로필 생성, 평가 제출, 오너 집계 조회, 삭제. 권한 모델과 한계가 파일 상단 주석에 있다. |

### 공용 파일 안의 PS 구역 (해당 줄/블록만 PokerStyle 소유)

| 파일 | PS 구역 |
|------|----------|
| `server/src/index.ts` | `import pokerStyleRouter`, `app.use('/api/pokerstyle', ...)` |
| `server/src/config/database.ts` | `ps_profiles` · `ps_ratings` 생성 블록 (메인 SQL 안, `[LAB]` 참고 주석 바로 위) |
| `server/.env.example` | `PS_HASH_SALT` |

각 위치에는 `[PS]` 마커 주석이 달려 있다.

### 권한 모델 (로그인 없음 — 토큰 기반)

| 역할 | 자격 | 할 수 있는 것 | 할 수 없는 것 |
|------|------|---------------|----------------|
| **OWNER** | 프로필 생성 응답의 `ownerToken` (64hex). 서버에는 SHA-256 해시만 저장. `X-Owner-Token` 헤더로 전달 | 본인 프로필 집계 결과 조회, 프로필 삭제 | 개별 평가자의 원본 응답 보기 (집계값만) |
| **RATER** | 프로필 공개 코드(`id`, 10자)만 알면 됨 | 프로필 존재 확인, 프로필당 **1회** 평가 제출 | 본인(오너) 응답·유형·평가 수·다른 평가 보기 |
| **그 외** | — | 아무것도 못 읽음 | — |

| 엔드포인트 | 역할 | 비고 |
|------------|------|------|
| `POST /api/pokerstyle/profiles` | (생성자 → OWNER 부여) | 유형 코드는 서버가 `pcts` 로 직접 계산. IP당 시간당 10회 |
| `GET /api/pokerstyle/profiles/:id` | RATER | `{id, exists}` 만 반환 |
| `POST /api/pokerstyle/profiles/:id/ratings` | RATER | `raterKey` 해시로 프로필당 1회(중복 409). 같은 IP는 프로필당 3회까지. IP당 시간당 40회. 프로필당 최대 200건 |
| `GET /api/pokerstyle/profiles/:id/results` | OWNER | 평가자 **3명 미만이면 `others: null`**. 축별 응답자가 3명 미만이면 그 축 `pct: null` |
| `DELETE /api/pokerstyle/profiles/:id` | OWNER | `ps_ratings` 는 CASCADE 로 함께 삭제 |

- 토큰이 틀리거나 프로필이 없으면 동일하게 `404` (존재 여부를 흘리지 않음). 헤더 자체가 없거나 형식이 틀리면 `401`.
- 프로필은 생성 후 **90일** 뒤 자동 삭제(`expires_at`, 새 프로필 생성 시 만료분 정리).

### 개인정보 · 데이터 규칙

- 이름·연락처·**자유 입력 텍스트는 받지 않는다**(추가하지 말 것 — 모더레이션·개인정보 이슈가 생긴다).
- 저장하는 것: 축별 점수(숫자), 관계(고정 선택지 `friend|table|family|online|other`), 평가자 키 해시, IP 해시. **원문 IP·원문 키는 저장하지 않는다.**
- 해시 솔트는 `PS_HASH_SALT`(없으면 `JWT_SECRET`). 바꾸면 기존 평가자 중복 판정이 리셋된다.
- 클라이언트(JinyShop `pokerstyle/pokerstyle-data.js`)의 축 개수(4)·축당 문항 수(8)와 이 라우트의 `AXES`/`QUESTIONS_PER_AXIS` 상수는 **같아야 한다**. 한쪽을 바꾸면 다른 쪽도 같이 바꿀 것.

### 운영 메모

- 브라우저(`https://jiny.shop`)에서 직접 호출하므로 **`ALLOWED_ORIGINS` 에 `https://jiny.shop` 포함**(미설정이면 `*`).
- 레이트 리미터는 메모리 기반이라 재시작하면 초기화된다. IP는 `X-Forwarded-For` 의 **마지막** 값을 사용한다(nginx 가 뒤에 덧붙이는 값; 앞쪽은 클라이언트가 위조 가능).
- 알려진 한계: 평가자 3명 공개 이후 평가가 추가될 때마다 오너가 조회하면 평균 변화로 새 평가자 값을 역산할 수 있다.
