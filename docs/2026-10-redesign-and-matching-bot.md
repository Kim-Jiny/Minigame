# 듀오 아레나 전면 리디자인 + 매칭 봇 (2026-10-23, `dev` 브랜치)

> 작업 브랜치: `dev` (main 미반영). 이 문서는 "무엇을 / 왜 / 어떻게 운영하나 / 아직 확인 안 된 것"을 한 곳에 정리한다.
> **중요: 앱 화면은 실제 기기·시뮬레이터에서 아직 한 번도 눈으로 확인하지 않았다.** `flutter analyze`(0 issue)와 `flutter test`(통과)만 확인했다. 머지 전에 직접 돌려볼 것.

## 1. 앱 리디자인 ("캔디 카툰")

### 디자인 시스템 (공통 위젯 — 새 화면은 이것만 쓴다)
| 파일 | 역할 |
|---|---|
| `app/lib/theme/candy_theme.dart` | `CandyColors`(잉크 #3A2D5C 아웃라인, 핑크/스카이/선/민트/그레이프/탠저린, 크림 배경) + `CandyTheme.light()`(Card·Dialog·Input·버튼·AppBar에 두꺼운 아웃라인 일괄 적용) + `displayFont`(주아체) |
| `widgets/cartoon/chunky_button.dart` | `ChunkyButton` 눌리면 푹 꺼지는 3D 버튼(햅틱 포함). 앱의 모든 주요 CTA |
| `widgets/cartoon/cartoon_card.dart` | `CartoonCard` 아웃라인+하드 섀도우 카드(탭 시 눌림) |
| `widgets/cartoon/pop_in.dart` | `PopIn` 통통 튀는 순차 등장(타이머는 dispose 에서 취소) |
| `widgets/cartoon/floating_bg.dart` | `FloatingBackground` 떠다니는 도형 배경 |
| `widgets/cartoon/duo_mascot.dart` | `DuoMascot` 코드로 그린 마스코트(숨쉬기·깜빡임, 표정 happy/cheer/wink/sad) |
| `widgets/cartoon/duo_logo.dart` | `DuoLogo` 마스코트 2마리 + 워드마크 |
| `widgets/cartoon/confetti_burst.dart` | `ConfettiBurst` 승리 컨페티 |
| `assets/fonts/Jua-Regular.ttf` | 주아체(OFL, admin 테마와 동일 파일). 제목·버튼·결과 텍스트에만 사용 |

색 변경: 기존 보라 `0xFF6C5CE7` → 핑크 `0xFFFF6B9D` 일괄 치환(`AppColors`는 `CandyColors` 별칭으로 유지해 기존 참조가 깨지지 않음).

### 적용 범위
- 로비 / 로그인 / 모드 게임 목록 / 서버 로딩 / 점검·연결 실패 / 초대 다이얼로그
- 친구 · 채팅 · 프로필 · 문의 · 리더보드 · 최근 전적 · 레벨 관리 · 상점 · 마일리지 상점 · 랭크 · 티어 뱃지
- 게임 공통(`games/common/*`): 인트로, 대기, 매칭 중/성사, 대결 헤더, 스테이지 패널, 타이머, 결과(승리 시 컨페티+마스코트, 패배 시 슬픈 마스코트), 결과 버튼, 재대결 패널·준비 화면
- 게임 17종 화면 전부(틱택토/무한/오목/가위바위보/반응속도/스피드탭/숫자배틀/사칙연산/방향/타이밍/카드/스트룹/시퀀스/헥사곤/피라미드/훈민정음/세트): 두꺼운 아웃라인 + 하드섀도우, 정답 팝/오답 셰이크, 카드 3D 플립, 말 놓기 탄성 등
- 동작(소켓 이벤트·프로바이더·규칙)은 바꾸지 않았다. 예외: 스트룹의 라운드 결과 SnackBar → 화면 내 배너, 훈민정음 결과 토스트 → 오버레이.

### 알려진 후속 과제
- **앱 아이콘/스플래시는 아직 옛 것** (`DUOIcon.png`). 마스코트 PNG를 뽑아 `flutter_launcher_icons`로 교체 필요.
- 시각 검증 필요 항목: 360px 폭·큰 글씨 오버플로, 주아체 폭, Android 텍스트 0.85배 스케일과의 조합, 저사양 기기 애니메이션 성능(오목·타이밍·카드플립).
- 일부 친구초대 시트(arrowdash/timing/stroop)에 옛 회색 텍스트가 조금 남아 있음.

## 2. 매칭 봇 (서버)

### 동작
1. 일반 매칭 대기열(`find_match`)에서 유저가 혼자 대기 → `대기시간(기본 5초) + 0~1.5초 지터` 후에도 대기 중이면 봇 투입.
2. 봇은 **서버 자신에게 loopback socket.io 로 접속하는 가짜 클라이언트**다(`join_lobby` → `find_match` → `game_action`). 게임 로직은 한 줄도 건드리지 않았고, 실제 유저와 같은 프로토콜을 쓴다.
3. 봇 계정 = `dm_users.is_bot = TRUE` (풀 30개, 사람 같은 닉네임 자동 생성). 게임이 끝나면 3~7초 뒤 퇴장, 상대가 나가면 즉시 퇴장(연결 끊김은 30초 유예), 최대 수명 15분, 매칭이 안 잡히면 15초 뒤 철수.
- 코드: `server/src/services/botService.ts`, 훅: `server/src/socket/index.ts`(`find_match` 대기열 push 직후, `[BOT]` 표식), 설정/통계 API: `server/src/routes/admin.ts`.

### 지원 범위 (그 외는 봇이 붙지 않고 계속 대기)
틱택토·오목(하드코어 가능), 무한 틱택토, 가위바위보, 반응속도, 스피드탭, 숫자배틀(일반), 사칙연산, 방향맞추기, 스트룹, 순서 기억, 타이밍 맞추기, 카드 뒤집기 (총 13종). 미지원: 헥사곤·수식피라미드·Set·훈민정음(풀이/사전 로직 필요).
**미지원**: 무한 모드, 랭크전, 3·4인, 훈민정음/SET/헥사곤/피라미드/시퀀스/스트룹/타이밍/카드플립 (프로토콜이 복잡 — 필요하면 `STRATEGIES` 에 추가).
실력(`skill` 0~1): 틱택토는 미니맥스+실수, 오목은 패턴 점수+상위 후보 흔들림, 나머지는 사람 같은 반응속도·오답 확률. 기본 0.5.

### 관리자 대시보드 (듀오 아레나 → Settings 탭 상단 "매칭 봇")
ON/OFF, 투입까지 대기시간(3~30초), 실력(0~100%), 동시 봇 수, 오늘/7일 봇 대전 수, 봇 승률, 지원 게임 목록.
**기본값은 OFF** (마이그레이션 직후 아무 일도 일어나지 않음. 켜야 동작).

### 봇이 통계를 오염시키지 않도록 한 처리
- 랭킹(`rankedService.getLeaderboard`)·유저 목록·신규가입/전체 유저 수·게임 수/인기도 집계에서 봇 제외(`NO_BOT_GAME`).
- 봇에게는 친구 요청 불가("이 상대에게는 친구 요청을 보낼 수 없어요").
- 봇과 둔 대전은 **사람의 전적·코인·연승에는 정상 반영**된다(의도적 — 보상 체계를 바꾸지 않음).

### ⚠ 운영 전 꼭 확인할 것
- **서버 통합 테스트를 못 했다.** 로컬에 Postgres/Docker 가 없었고 `.env` 의 DB가 운영일 수 있어 서버를 띄우지 않았다. 검증한 것: `tsc` 통과, 전략 로직 단위 검증(가짜 소켓: 틱택토 skill1 vs 랜덤 293승 0패, 오목 승리/방어 수, 숫자배틀·사칙연산·방향 액션 포맷). **dev 서버에서 봇 ON 후 혼자 매칭해 보고(게임 13종) 로그 `[bot]` 를 확인할 것.**
- 코인 파밍: 봇이 약하면 사람이 봇에게 이겨 코인을 벌 수 있다. 실력 40~60% 권장, 7일 봇 승률을 관리자에서 확인.
- **정책/고지**: 봇이 사람처럼 보이도록 한 설계다. 스토어 심사·소비자 고지·개인정보처리방침(상대가 봇일 수 있다는 안내) 검토 필요. 요구에 따라 구현했지만 법무/스토어 정책 판단은 별도다.
- `package.json`: `socket.io-client` 를 devDependencies → dependencies 로 이동(Dockerfile 이 `npm prune --omit=dev` 하므로 필수). lock 파일 갱신됨.
- DB 변경(자동 마이그레이션, 멱등): `dm_users.is_bot`, `dm_bot_settings`(단일 행).

## 3. 관리자 대시보드 개선 (듀오)
`GET /api/admin/duo/overview` + `server/public/admin/duo.js`, `duo.css` (index.html 은 컨테이너 3개와 로드 태그만 추가).
- 실시간: 접속 유저, 진행 중 대전(봇 대전 별도), 매칭 대기(게임별), 미답변 문의 + 가장 오래된 건 경과 시간
- D1 리텐션, 오늘 코인 지급/소비/순증, 제재 중 유저 수
- 최근 14일 추이(대전·활성·신규), 시간대별 대전(KST, 피크 강조), 게임별 이용(7일), 이번 주 열혈 유저 TOP5(클릭→유저 상세)
- 기존 stats 의 게임 수/인기도/신규 가입 수에서 봇 제외

## 4. 수정한 버그
- 채팅 `dispose` 에서 `context.read` (비활성 element 에서 예외 가능) → initState 에서 보관
- `match_found` 에서 `_myPlayerIndex == -1` 이면 점수/진행 조회 크래시 (숫자배틀·카드플립·스트룹·가위바위보·스피드탭) → 방어
- 스트룹 `correctAnswer` null 캐스팅 예외, 숫자배틀 `_tapCell` 범위 검사
- 가위바위보·반응속도·스피드탭: post-frame 콜백/소켓 setState 의 `mounted` 누락, 반응속도 `_roomId == null` 로 `game_action` 전송
- 오목: 보드 테두리 때문에 그려진 격자와 탭 셀이 최대 4px 어긋남, 종료 후 미리보기 돌 잔상
- 가위바위보: 공용 컨트롤러 하나로 3개 버튼이 동시에 눌리던 문제
- 시퀀스/SET: `_reset` 이 타이머를 안 끊어 "다시 찾기" 후 stale 콜백이 화면을 바꾸던 문제, SET 솔로 스톱워치가 100ms 마다 화면 전체 setState
- 훈민정음: 검색 중 뒤로가기 시 `cancel_match` 미전송(대기열에 남음)
- 헥사곤/피라미드: `_handleRoomInvalid` 후 타이머 지속, 배열 인덱스 범위 미검사
- `PopIn` 의 `Future.delayed` → 취소 가능한 `Timer` (테스트에서 pending timer 로 실패하던 것)
- 서버: 관리자 게임 수 집계 중복(플레이어 단위로 2배), 봇 대전이 집계/랭킹에 섞이는 문제
- `app/test/widget_test.dart` 갱신(로고 문구 변경) — 통과

## 5. 의심되지만 고치지 않은 것 (후속 확인)
- 반응속도: "내 부정출발" 판정이 닉네임 비교(`_pressedPlayerNickname != _opponentNickname`) → 닉네임 동일 시 오판
- 스피드탭 로비 버튼이 `leaveGameAndReturnToLobby` 대신 `Navigator.pop`
- 타이밍: `opponent_reconnected` 후 게이지 재시작 여부(서버 `timing_resumed` 에 의존), `rejoin_game_state` 에서 이미 멈춘 경우 게이지가 0에 머묾
- 헥사곤 `game_start` 가 종료 후 재대결 요청 없이도 처리됨(시퀀스는 무시)
- 친구 화면 Consumer 가 rebuild 마다 SnackBar 예약(중복 표시 가능)
- 랭크 화면 `_onRankedProviderChanged` 리스너가 post-frame 에 붙어 빠른 pop 시 null, dispose 시 `finished` 상태 미초기화
- 상점 닉네임 변경 다이얼로그의 `TextEditingController` 미dispose, 마일리지 상점 문구("마일리지" vs "코인") 불일치, "패배 삭제권"·"랭크 보상" 은 미완성 스텁

## 6. 머지 체크리스트 (dev → main)
1. dev 서버 배포 후: 봇 OFF 상태에서 기존 매칭 정상 확인 → 봇 ON → 게임 13종 혼자 매칭 → 관리자 패널에서 통계 확인.
2. 앱 실기기 확인(위 "시각 검증 필요 항목"), 앱 아이콘 교체.
3. 개인정보처리방침/스토어 고지 검토(봇).
4. `dev` 는 `main` 을 한 번 머지해 둔 상태(MFA 관리자 개편 포함) — 충돌 없음.


## 추가 수정 (2026-10-26)
- **"연결 종료 · 연결이 끊어져 게임이 종료되었습니다" 팝업**: 게임이 끝난 방에 늦게 도착한 `game_action`(마지막 탭·타이머 경합)에 서버가 `Invalid room or game not in progress` 에러를 돌려주고, 클라이언트(`GameEventHelper.registerInvalidRoomHandler`)가 이를 '연결 종료'로 처리해 결과 화면 대신 로비로 보냈다. 서버가 `room.status === 'finished'` 인 방의 늦은 입력은 에러 없이 무시하도록 수정(`server/src/socket/index.ts` game_action 핸들러). 봇전은 게임이 빨리 끝나 경합이 더 자주 났을 가능성이 있다. dev 에서 재현 여부 확인 필요.
- 로비 개편: 게임 그리드 + 시작 시트 + 바로 대전(인트로 자동 매칭). `GameLaunchArgs`(game_intro_view.dart) 참고.
- 봇 게임 5종 추가(스트룹·순서 기억·타이밍·카드 뒤집기·무한 틱택토). 봇이 find_match 에 isInfinite 를 그대로 전달하며, 무한 틱택토는 `gameType:'infinite_tictactoe'` 와 `tictactoe+isInfinite` 두 경로 모두 처리. 가짜 소켓으로 액션 포맷·카드 기억·승리/방어 수만 확인했고 실서버 매칭은 미확인. 앱 빠른 시작 후보(`_quickStartGames`)도 같은 13종으로 갱신 — `botService.ts` 의 SUPPORTED_GAMES 와 같게 유지할 것.

## 상점 개편 + 봇 17종 (2026-10-26)
**상점(서버)** — `dm_shop_items` 에 sale_percent/sale_ends_at/badge/is_featured/available_until 추가, 신규 `dm_shop_purchases`(구매 로그, 기존 `purchase_%` 이력 백필)·`dm_shop_meta`, `dm_user_profile_settings.active_mascot_id`. 구매는 트랜잭션(코인 이중 차감 방지). **기간제**: frame/title/theme/avatar/mascot 의 duration_days 를 등급별(일반·레어 30, 에픽 21, 전설 14일)로 1회 마이그레이션(`dm_shop_meta.duration_migrated_v1`), 보유 중 재구매는 연장(최대 365일), 만료된 장착은 자동 해제. 기존에 영구로 산 아이템은 영구 유지. 신규 카테고리 `mascot`(13종, `{skinColor, accessory}`).
**운영(admin)** — `/api/admin/shop/stats|items|bulk-sale`, `PATCH /shop/items/:id`(가격·ON/OFF·할인%·종료일·배지·추천·한정종료일·기간). DUO 대시보드 "Shop" 탭(KPI·일별 매출·카테고리/등급 비중·인기/미판매·재구매율·곧 만료·일괄 할인). 기존 대시보드의 `shopRevenue` 는 'shop_%' 필터 오류로 항상 0 이었음 → 구매 로그 기준으로 수정.
**앱** — `AvatarArt`(27종 손그림 CustomPainter, 이모지 대체), 마스코트 스킨·액세서리(`MyMascot`, 로비·프로필), 상점 UI(할인 스티커·신상/한정/추천 배지·추천 스트립·기간 칩·연장하기·만료 임박).
**봇** — 17종 전부 지원(Set·훈민정음·헥사곤·수식피라미드 추가; 무한 Set·하드코어 제외). 훈민정음은 `dm_korean_words` 사전 의존(운영 DB 단어 수가 적으면 봇이 시간초과 탈락 가능). 헥사곤/피라미드의 풀이 지연값은 추정치. 앱 빠른 시작은 17종 전체, 헥사곤/피라미드/Set 도 `GameLaunchArgs` 로 인트로 생략.
**미확인(전부)** — 앱 화면(아바타 그림·상점 카드 레이아웃·카드 비율), 서버 마이그레이션 SQL(실DB 미실행), admin 패널, 봇 4종 실서버 매칭. 타임존: admin 날짜는 DB/Node 시간대가 같다고 가정.

## 관리자 '운영 지표' 탭 (2026-10-26)
- **유저**: DAU/WAU/MAU·신규·고착도, D1/D7 코호트 재방문, 첫 판 퍼널. **매칭**: 게임별 대기시간(평균/p50/p90)·포기율·봇 비중·'봇 켜도 되는 시점' 힌트. **게임 건강도**: 완주/이탈/끊김률·평균 판 길이·문제 게임 순위·에러 카운터. **코인 경제**: 일별 획득/소비/순증, 출처 버킷, 잔액 평균·중앙값·상위 보유자, 인플레이션 지표. **알림**: 대기 p90>20s, 봇 승률 30~70% 이탈, 이탈률>15%, 소켓 에러 급증, DB 풀 에러, 매칭 0건 6h (임계값은 `opsMetrics.ts` 의 `OPS_THRESHOLDS`). 탭 배지는 60초 폴링.
- **계측(신규 테이블)**: `dm_match_events`, `dm_match_abandons`, `dm_game_health` (90일 보관, 최대 6시간마다 lazy 정리). socket/index.ts 의 `[OPS]` 훅은 전부 fire-and-forget·예외 삼킴(게임/매칭 로직 불변). **새 지표는 배포 후부터 쌓이므로 초기엔 비어 있다**(유저 지표·코인 경제는 기존 기록으로 즉시 표시).
- **한계/미확인**: SQL·UI 전부 DB/브라우저 미실행. 날짜는 KST(`Asia/Seoul`) 기준(기존 overview 는 DB `CURRENT_DATE`). game health 는 `find_match` 로 만든 방만 기록(랭크·솔로·친구초대 제외), `forfeit` 은 현재 0. 첫 부팅 때 `dm_game_records`/`dm_mileage_history`/`dm_users` 의 created_at 인덱스를 non-concurrent 로 생성 — 큰 테이블이면 잠깐 쓰기 대기. 에러 카운터는 메모리(재시작 시 초기화).
