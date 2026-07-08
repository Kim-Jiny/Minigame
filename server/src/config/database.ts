import { Pool } from 'pg';
import bcrypt from 'bcrypt';

let pool: Pool;

export async function setupDatabase() {
  let databaseUrl = process.env.DATABASE_URL;

  if (!databaseUrl) {
    console.log('⚠️  DATABASE_URL not set, running without database');
    return;
  }

  // 개발 환경에서는 DB 호스트를 localhost로 변경
  if (process.env.NODE_ENV === 'development') {
    databaseUrl = databaseUrl.replace('duo-db', 'localhost');
  }

  pool = new Pool({
    connectionString: databaseUrl,
  });

  try {
    const client = await pool.connect();
    console.log('✅ Connected to PostgreSQL');

    // 테이블 생성
    await client.query(`
      CREATE TABLE IF NOT EXISTS dm_users (
        id SERIAL PRIMARY KEY,
        provider VARCHAR(20) NOT NULL,
        provider_id VARCHAR(255) NOT NULL,
        email VARCHAR(255),
        nickname VARCHAR(50) NOT NULL,
        avatar_url TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(provider, provider_id)
      );

      CREATE TABLE IF NOT EXISTS dm_game_records (
        id SERIAL PRIMARY KEY,
        game_type VARCHAR(50) NOT NULL,
        player1_id INTEGER REFERENCES dm_users(id),
        player2_id INTEGER REFERENCES dm_users(id),
        winner_id INTEGER REFERENCES dm_users(id),
        game_data JSONB,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 친구 코드 테이블
      CREATE TABLE IF NOT EXISTS dm_friend_codes (
        id SERIAL PRIMARY KEY,
        user_id INTEGER UNIQUE REFERENCES dm_users(id),
        code VARCHAR(8) UNIQUE NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 기존 테이블 컬럼 크기 변경 (6자리 -> 8자리)
      ALTER TABLE dm_friend_codes ALTER COLUMN code TYPE VARCHAR(8);

      -- 친구 관계 테이블
      CREATE TABLE IF NOT EXISTS dm_friendships (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        friend_id INTEGER REFERENCES dm_users(id),
        memo VARCHAR(20),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, friend_id)
      );

      -- memo 컬럼 추가 (기존 테이블용)
      ALTER TABLE dm_friendships ADD COLUMN IF NOT EXISTS memo VARCHAR(20);

      -- 친구 요청 테이블
      CREATE TABLE IF NOT EXISTS dm_friend_requests (
        id SERIAL PRIMARY KEY,
        from_user_id INTEGER REFERENCES dm_users(id),
        to_user_id INTEGER REFERENCES dm_users(id),
        status VARCHAR(20) DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(from_user_id, to_user_id)
      );

      -- 게임 초대 테이블
      CREATE TABLE IF NOT EXISTS dm_game_invitations (
        id SERIAL PRIMARY KEY,
        inviter_id INTEGER REFERENCES dm_users(id),
        invitee_id INTEGER REFERENCES dm_users(id),
        game_type VARCHAR(50) NOT NULL,
        is_hardcore BOOLEAN DEFAULT FALSE,
        status VARCHAR(20) DEFAULT 'pending',
        room_id VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- is_hardcore 컬럼 추가 (기존 테이블용)
      ALTER TABLE dm_game_invitations ADD COLUMN IF NOT EXISTS is_hardcore BOOLEAN DEFAULT FALSE;

      -- 게임별 통계 테이블
      CREATE TABLE IF NOT EXISTS dm_user_game_stats (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        game_type VARCHAR(50) NOT NULL,
        wins INTEGER DEFAULT 0,
        losses INTEGER DEFAULT 0,
        draws INTEGER DEFAULT 0,
        level INTEGER DEFAULT 1,
        exp INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, game_type)
      );

      -- 마일리지 테이블
      CREATE TABLE IF NOT EXISTS dm_user_mileage (
        id SERIAL PRIMARY KEY,
        user_id INTEGER UNIQUE REFERENCES dm_users(id),
        mileage INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 마일리지 기록 테이블
      CREATE TABLE IF NOT EXISTS dm_mileage_history (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        amount INTEGER NOT NULL,
        reason VARCHAR(50) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 친구 메시지 테이블
      CREATE TABLE IF NOT EXISTS dm_friend_messages (
        id SERIAL PRIMARY KEY,
        sender_id INTEGER REFERENCES dm_users(id),
        receiver_id INTEGER REFERENCES dm_users(id),
        content TEXT NOT NULL,
        is_read BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 7일 지난 메시지 자동 삭제용 인덱스
      CREATE INDEX IF NOT EXISTS idx_dm_friend_messages_created_at ON dm_friend_messages(created_at);

      -- 연승 추적 테이블
      CREATE TABLE IF NOT EXISTS dm_user_streak (
        user_id INTEGER PRIMARY KEY REFERENCES dm_users(id),
        current_streak INTEGER DEFAULT 0,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 일일 상대별 게임 횟수 (어뷰징 방지)
      CREATE TABLE IF NOT EXISTS dm_daily_match_count (
        user_id INTEGER REFERENCES dm_users(id),
        opponent_id INTEGER REFERENCES dm_users(id),
        match_date DATE NOT NULL,
        count INTEGER DEFAULT 0,
        PRIMARY KEY (user_id, opponent_id, match_date)
      );

      -- 오래된 dm_daily_match_count 자동 정리용 인덱스
      CREATE INDEX IF NOT EXISTS idx_dm_daily_match_count_date ON dm_daily_match_count(match_date);

      -- 상점 아이템 카탈로그
      CREATE TABLE IF NOT EXISTS dm_shop_items (
        id SERIAL PRIMARY KEY,
        category VARCHAR(30) NOT NULL,
        item_key VARCHAR(50) UNIQUE NOT NULL,
        name VARCHAR(50) NOT NULL,
        description TEXT,
        price INTEGER NOT NULL,
        duration_days INTEGER DEFAULT NULL,
        rarity VARCHAR(20) DEFAULT 'common',
        preview_data JSONB,
        sort_order INTEGER DEFAULT 0,
        is_active BOOLEAN DEFAULT TRUE,
        is_default BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 유저 보유 아이템
      CREATE TABLE IF NOT EXISTS dm_user_items (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        item_id INTEGER REFERENCES dm_shop_items(id),
        purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        expires_at TIMESTAMP DEFAULT NULL,
        UNIQUE(user_id, item_id)
      );

      -- 유저 프로필 설정
      CREATE TABLE IF NOT EXISTS dm_user_profile_settings (
        user_id INTEGER PRIMARY KEY REFERENCES dm_users(id),
        active_frame_id INTEGER REFERENCES dm_shop_items(id),
        active_title_id INTEGER REFERENCES dm_shop_items(id),
        active_theme_id INTEGER REFERENCES dm_shop_items(id),
        active_avatar_id INTEGER REFERENCES dm_shop_items(id),
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 아바타 컬럼 추가 (기존 테이블용)
      DO $$ BEGIN
        ALTER TABLE dm_user_profile_settings ADD COLUMN active_avatar_id INTEGER REFERENCES dm_shop_items(id);
      EXCEPTION WHEN duplicate_column THEN NULL;
      END $$;

      -- 인덱스 추가
      CREATE INDEX IF NOT EXISTS idx_dm_user_items_user_id ON dm_user_items(user_id);
      CREATE INDEX IF NOT EXISTS idx_dm_user_items_expires_at ON dm_user_items(expires_at);
      CREATE INDEX IF NOT EXISTS idx_dm_shop_items_category ON dm_shop_items(category);

      -- 랭크 통계 테이블
      CREATE TABLE IF NOT EXISTS dm_user_ranked_stats (
        id SERIAL PRIMARY KEY,
        user_id INTEGER UNIQUE REFERENCES dm_users(id),
        elo INTEGER DEFAULT 1200,
        tier VARCHAR(20) DEFAULT 'Gold',
        wins INTEGER DEFAULT 0,
        losses INTEGER DEFAULT 0,
        win_streak INTEGER DEFAULT 0,
        max_win_streak INTEGER DEFAULT 0,
        season INTEGER DEFAULT 1,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 랭크 매치 기록 테이블
      CREATE TABLE IF NOT EXISTS dm_ranked_matches (
        id SERIAL PRIMARY KEY,
        player1_id INTEGER REFERENCES dm_users(id),
        player2_id INTEGER REFERENCES dm_users(id),
        winner_id INTEGER REFERENCES dm_users(id),
        games_played JSONB,
        player1_elo_before INTEGER,
        player2_elo_before INTEGER,
        player1_elo_after INTEGER,
        player2_elo_after INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 랭크 통계 인덱스
      CREATE INDEX IF NOT EXISTS idx_dm_user_ranked_stats_elo ON dm_user_ranked_stats(elo DESC);
      CREATE INDEX IF NOT EXISTS idx_dm_user_ranked_stats_user_id ON dm_user_ranked_stats(user_id);
      CREATE INDEX IF NOT EXISTS idx_dm_ranked_matches_player1 ON dm_ranked_matches(player1_id);
      CREATE INDEX IF NOT EXISTS idx_dm_ranked_matches_player2 ON dm_ranked_matches(player2_id);

      -- 유저 접속 기록 테이블
      CREATE TABLE IF NOT EXISTS dm_user_sessions (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        ip_address VARCHAR(45),
        platform VARCHAR(20),
        os_version VARCHAR(50),
        device_model VARCHAR(100),
        app_version VARCHAR(20),
        build_number VARCHAR(20),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 접속 기록 인덱스
      CREATE INDEX IF NOT EXISTS idx_dm_user_sessions_user_id ON dm_user_sessions(user_id);
      CREATE INDEX IF NOT EXISTS idx_dm_user_sessions_created_at ON dm_user_sessions(created_at);

      -- 문의 테이블
      CREATE TABLE IF NOT EXISTS dm_inquiries (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES dm_users(id),
        category VARCHAR(30) NOT NULL,
        title VARCHAR(100) NOT NULL,
        content TEXT NOT NULL,
        status VARCHAR(20) DEFAULT 'pending',
        reply TEXT,
        replied_at TIMESTAMP,
        is_read BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- is_read 컬럼 추가 (기존 테이블용)
      ALTER TABLE dm_inquiries ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT FALSE;

      -- 문의 인덱스
      CREATE INDEX IF NOT EXISTS idx_dm_inquiries_user_id ON dm_inquiries(user_id);
      CREATE INDEX IF NOT EXISTS idx_dm_inquiries_status ON dm_inquiries(status);

      -- 관리자 계정 테이블
      CREATE TABLE IF NOT EXISTS dm_admin_accounts (
        id SERIAL PRIMARY KEY,
        username VARCHAR(50) UNIQUE NOT NULL,
        password VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 헥사곤 솔로 랭킹 테이블
      CREATE TABLE IF NOT EXISTS dm_hexagon_rankings (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES dm_users(id),
        score INTEGER NOT NULL,
        nickname VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_dm_hexagon_rankings_score ON dm_hexagon_rankings(score DESC);

      -- 피라미드 솔로 랭킹 테이블
      CREATE TABLE IF NOT EXISTS dm_pyramid_rankings (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES dm_users(id),
        score INTEGER NOT NULL,
        nickname VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_dm_pyramid_rankings_score ON dm_pyramid_rankings(score DESC);

      -- Set(셋) 솔로 랭킹 테이블 — 덱(81장) 전체를 소진하는 데 걸린 시간(ms) 기준.
      -- 점수형(높을수록 좋음)인 다른 솔로 게임과 달리 시간형(낮을수록 좋음)이라
      -- time_ms 오름차순 인덱스를 둔다. sets_found는 참고/표시용.
      CREATE TABLE IF NOT EXISTS dm_set_rankings (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES dm_users(id),
        time_ms INTEGER NOT NULL,
        sets_found INTEGER NOT NULL DEFAULT 0,
        nickname VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_dm_set_rankings_time ON dm_set_rankings(time_ms ASC);

      -- 한국어 단어 사전 (훈민정음 게임용)
      CREATE TABLE IF NOT EXISTS dm_korean_words (
        id SERIAL PRIMARY KEY,
        word VARCHAR(50) NOT NULL UNIQUE,
        chosung VARCHAR(50) NOT NULL,
        pos VARCHAR(20),
        source VARCHAR(20) NOT NULL DEFAULT 'api',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_korean_words_word ON dm_korean_words(word);
      CREATE INDEX IF NOT EXISTS idx_korean_words_chosung ON dm_korean_words(chosung);

      -- 유저 제재 기록
      CREATE TABLE IF NOT EXISTS dm_user_bans (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES dm_users(id),
        ban_type VARCHAR(30) NOT NULL,
        reason TEXT NOT NULL,
        banned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        expires_at TIMESTAMP DEFAULT NULL,
        banned_by INTEGER REFERENCES dm_admin_accounts(id),
        is_active BOOLEAN DEFAULT TRUE,
        revoked_at TIMESTAMP DEFAULT NULL,
        revoked_by INTEGER REFERENCES dm_admin_accounts(id)
      );
      CREATE INDEX IF NOT EXISTS idx_dm_user_bans_user_id ON dm_user_bans(user_id);

      -- 공지사항
      CREATE TABLE IF NOT EXISTS dm_notices (
        id SERIAL PRIMARY KEY,
        title VARCHAR(200) NOT NULL,
        content TEXT NOT NULL,
        type VARCHAR(30) DEFAULT 'general',
        is_active BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        created_by INTEGER REFERENCES dm_admin_accounts(id)
      );

      -- 광고 설정 테이블
      CREATE TABLE IF NOT EXISTS dm_ad_config (
        id SERIAL PRIMARY KEY,
        config_key VARCHAR(50) UNIQUE NOT NULL,
        config_value VARCHAR(200) NOT NULL,
        description VARCHAR(200),
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      INSERT INTO dm_ad_config (config_key, config_value, description) VALUES
        ('reward_coins', '50', '보상형 광고 1회 시청 코인'),
        ('reward_daily_limit', '7', '보상형 광고 일일 최대 횟수'),
        ('reward_enabled', 'true', '보상형 광고 활성화 여부')
      ON CONFLICT (config_key) DO NOTHING;

      -- ================================================================
      -- [CTR] CatchTheRule 소유 — ctr_ 테이블 전체 삭제·리팩터링 금지 (리포 루트 CLAUDE.md).
      -- CatchTheRule (규칙찾기) — 로그인 없는 닉네임 기반 솔로 랭킹.
      -- 프리픽스 ctr_ 로 다른 앱(dm_) 데이터와 분리. dm_users FK 없음.
      -- device_id 로 기기당 1행 upsert(최고점 유지), 없으면 단순 insert.
      -- ================================================================
      CREATE TABLE IF NOT EXISTS ctr_rankings (
        id SERIAL PRIMARY KEY,
        mode VARCHAR(30) NOT NULL DEFAULT 'timeAttack',
        device_id VARCHAR(64),
        nickname VARCHAR(20) NOT NULL,
        country VARCHAR(2),
        score INTEGER NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      -- country 컬럼 추가 (기존 테이블용) — ISO 3166-1 alpha-2 (예: KR)
      ALTER TABLE ctr_rankings ADD COLUMN IF NOT EXISTS country VARCHAR(2);
      -- 기기당 모드별 1행(최고점). device_id 가 있을 때만 유니크.
      CREATE UNIQUE INDEX IF NOT EXISTS uq_ctr_rankings_mode_device
        ON ctr_rankings(mode, device_id) WHERE device_id IS NOT NULL;
      -- 리더보드 정렬용.
      CREATE INDEX IF NOT EXISTS idx_ctr_rankings_mode_score
        ON ctr_rankings(mode, score DESC, created_at ASC);

      -- CatchTheRule 문의 (로그인 없음 → device_id 로 본인 문의/답변 조회).
      CREATE TABLE IF NOT EXISTS ctr_inquiries (
        id SERIAL PRIMARY KEY,
        device_id VARCHAR(64) NOT NULL,
        nickname VARCHAR(20),
        content TEXT NOT NULL,
        status VARCHAR(20) DEFAULT 'pending',   -- pending | replied
        reply TEXT,
        replied_at TIMESTAMP,
        is_read BOOLEAN DEFAULT FALSE,           -- 사용자가 답변을 읽었는지
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_ctr_inquiries_device ON ctr_inquiries(device_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_ctr_inquiries_status ON ctr_inquiries(status, created_at DESC);

      -- CatchTheRule 디바이스(익명) — 로그인 없이 유저 카운팅/통계.
      -- 향후 보상형 광고·광고제거 IAP 데이터의 토대(컬럼 확장).
      CREATE TABLE IF NOT EXISTS ctr_devices (
        device_id VARCHAR(64) PRIMARY KEY,
        platform VARCHAR(10),                     -- ios | android
        country VARCHAR(2),
        app_version VARCHAR(20),
        os_version VARCHAR(30),
        launch_count INTEGER DEFAULT 1,
        first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_ctr_devices_platform ON ctr_devices(platform);
      CREATE INDEX IF NOT EXISTS idx_ctr_devices_last_seen ON ctr_devices(last_seen);

      -- 일자별 활성 디바이스 (DAU/WAU/MAU 산출용).
      CREATE TABLE IF NOT EXISTS ctr_device_daily (
        device_id VARCHAR(64) NOT NULL,
        day DATE NOT NULL,
        platform VARCHAR(10),
        PRIMARY KEY (device_id, day)
      );
      CREATE INDEX IF NOT EXISTS idx_ctr_device_daily_day ON ctr_device_daily(day);

      -- 인앱결제 영수증(검증 결과 포함). transaction_id 로 중복/재지급 방지.
      CREATE TABLE IF NOT EXISTS ctr_purchases (
        id SERIAL PRIMARY KEY,
        device_id VARCHAR(64),
        platform VARCHAR(10) NOT NULL,            -- ios | android
        product_id VARCHAR(80) NOT NULL,
        transaction_id VARCHAR(128) NOT NULL,
        kind VARCHAR(20),                          -- remove_ads | hints
        verified BOOLEAN NOT NULL DEFAULT FALSE,
        status VARCHAR(20) NOT NULL DEFAULT 'unverified', -- verified | failed | unverified
        environment VARCHAR(20),                   -- Production | Sandbox 등
        raw TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE UNIQUE INDEX IF NOT EXISTS uq_ctr_purchases_txn ON ctr_purchases(platform, transaction_id);
      CREATE INDEX IF NOT EXISTS idx_ctr_purchases_created ON ctr_purchases(created_at DESC);

      -- 서버 제공 추가 스테이지(앱 내장 11챕터 외). data = 퍼즐 JSON 전체(번들과 동일 스키마).
      CREATE TABLE IF NOT EXISTS ctr_puzzles (
        id VARCHAR(64) PRIMARY KEY,
        chapter INT NOT NULL,
        ord INT NOT NULL,
        data JSONB NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_ctr_puzzles_order ON ctr_puzzles(chapter, ord);

      -- ================================================================
      -- [SAJA] 사자툰(SajaToon) 소유 — sj_ 테이블 전체 삭제·리팩터링 금지 (리포 루트 CLAUDE.md).
      -- 사자툰(SajaToon) — "매일 한 편의 만화로 배우는 사자성어".
      -- 앱 소스는 별도 리포 ~/Documents/Jiny/SajaToon (Android Kotlin, 추후 iOS).
      -- 로그인 없는 deviceId 기반 공개 API(routes/sajatoon.ts). 프리픽스 sj_ 로
      -- 다른 앱(dm_/ctr_) 데이터와 분리. dm_users FK 없음. 임의로 지우지 말 것.
      -- ================================================================

      -- [SAJA] 사자성어 콘텐츠. 만화 패널·뜻·유래·현대사례·퀴즈를 한 행에 담는다.
      --        comic = 패널 배열 [{ caption, emoji, bg, imageKey }], quiz = { question, options[], answerIndex, explanation }.
      CREATE TABLE IF NOT EXISTS sj_idioms (
        id SERIAL PRIMARY KEY,
        slug VARCHAR(64) UNIQUE NOT NULL,        -- 안정적 식별자 (예: 'oilmujung')
        hanja VARCHAR(20) NOT NULL,              -- 한자 (예: 五里霧中)
        reading VARCHAR(40) NOT NULL,            -- 한글 음 (예: 오리무중)
        meaning TEXT NOT NULL,                   -- 뜻
        origin TEXT,                             -- 유래
        modern_example TEXT,                     -- 현대 사례
        category VARCHAR(30),                    -- 분류 (예: 처세, 노력)
        level INTEGER DEFAULT 1,                 -- 난이도(1~3)
        day_index INTEGER,                       -- 학습 순서(오늘의 사자성어 회차)
        comic JSONB NOT NULL DEFAULT '[]',       -- (폴백) 만화 패널 배열 — 실제 이미지 없을 때 플레이스홀더용
        images JSONB NOT NULL DEFAULT '[]',      -- 실제 만화 이미지 URL 리스트. 4컷=1장, 8컷=2장 식으로 순서대로.
        thumbnail TEXT,                          -- 모아보기/홈 대표 썸네일 이미지 URL(없으면 첫 만화컷으로 폴백)
        chars JSONB NOT NULL DEFAULT '[]',       -- 한자 한 글자씩 풀이 [{ c, hun(뜻), eum(음) }]
        quiz JSONB,                              -- (레거시) 단일 객관식 퀴즈
        quizzes JSONB NOT NULL DEFAULT '[]',     -- 객관식 퀴즈 여러 개(유형 다양). 정답 위치는 앱에서 매번 섞음.
        is_active BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_sj_idioms_day ON sj_idioms(day_index);
      -- [SAJA] images 컬럼 추가 (기존 테이블용). 만화 이미지 URL 리스트.
      ALTER TABLE sj_idioms ADD COLUMN IF NOT EXISTS images JSONB NOT NULL DEFAULT '[]';
      -- [SAJA] thumbnail 컬럼 추가 (기존 테이블용). 모아보기 대표 썸네일.
      ALTER TABLE sj_idioms ADD COLUMN IF NOT EXISTS thumbnail TEXT;
      -- [SAJA] chars 컬럼 추가 (기존 테이블용). 한자 한 글자씩 풀이.
      ALTER TABLE sj_idioms ADD COLUMN IF NOT EXISTS chars JSONB NOT NULL DEFAULT '[]';
      -- [SAJA] quizzes 컬럼 추가 (기존 테이블용). 퀴즈 여러 개.
      ALTER TABLE sj_idioms ADD COLUMN IF NOT EXISTS quizzes JSONB NOT NULL DEFAULT '[]';

      -- [SAJA] 디바이스(익명) — 로그인 없이 유저 카운팅/통계 (ctr_devices 와 동일 패턴).
      CREATE TABLE IF NOT EXISTS sj_devices (
        device_id VARCHAR(64) PRIMARY KEY,
        platform VARCHAR(10),                     -- ios | android
        country VARCHAR(2),
        app_version VARCHAR(20),
        os_version VARCHAR(30),
        launch_count INTEGER DEFAULT 1,
        first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_sj_devices_last_seen ON sj_devices(last_seen);

      -- [SAJA] 일자별 활성 디바이스 (DAU/WAU/MAU 산출용).
      CREATE TABLE IF NOT EXISTS sj_device_daily (
        device_id VARCHAR(64) NOT NULL,
        day DATE NOT NULL,
        platform VARCHAR(10),
        PRIMARY KEY (device_id, day)
      );
      CREATE INDEX IF NOT EXISTS idx_sj_device_daily_day ON sj_device_daily(day);

      -- [SAJA] 학습 진도 (기기별·사자성어별). 학습 완료/퀴즈 정답/북마크 기록. 서버 동기화.
      CREATE TABLE IF NOT EXISTS sj_progress (
        device_id VARCHAR(64) NOT NULL,
        idiom_id INTEGER NOT NULL REFERENCES sj_idioms(id),
        learned BOOLEAN DEFAULT FALSE,
        learned_at TIMESTAMP,
        quiz_correct INTEGER DEFAULT 0,          -- 누적 정답 횟수
        quiz_attempts INTEGER DEFAULT 0,         -- 누적 시도 횟수
        bookmarked BOOLEAN DEFAULT FALSE,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (device_id, idiom_id)
      );
      CREATE INDEX IF NOT EXISTS idx_sj_progress_device ON sj_progress(device_id);

      -- [SAJA] 사자툰 메타(키-값). 'seeded' 플래그로 콘텐츠 시드를 최초 1회만 실행한다.
      CREATE TABLE IF NOT EXISTS sj_meta (
        key VARCHAR(40) PRIMARY KEY,
        value TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- [MFA] 성인의 수학(Math for Adults, 별도 리포 ~/Documents/Jiny/MathForAdults) 소유.
      --       로그인 없는 deviceId 기반 문의. mfa_* 테이블 — 삭제·리팩터링 금지.
      CREATE TABLE IF NOT EXISTS mfa_inquiries (
        id SERIAL PRIMARY KEY,
        device_id VARCHAR(64) NOT NULL,
        nickname VARCHAR(20),
        content TEXT NOT NULL,
        status VARCHAR(20) DEFAULT 'pending',   -- pending | replied
        reply TEXT,
        replied_at TIMESTAMP,
        is_read BOOLEAN DEFAULT FALSE,           -- 사용자가 답변을 읽었는지
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_mfa_inquiries_device ON mfa_inquiries(device_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_mfa_inquiries_status ON mfa_inquiries(status, created_at DESC);

      -- [MFA] 소셜 로그인 사용자 + 진도 동기화 (선택적 로그인). 삭제·리팩터링 금지.
      CREATE TABLE IF NOT EXISTS mfa_users (
        id SERIAL PRIMARY KEY,
        provider VARCHAR(10) NOT NULL,          -- apple | google
        provider_uid VARCHAR(255) NOT NULL,     -- 소셜 고유 식별자(sub)
        email VARCHAR(255),
        nickname VARCHAR(40),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_login TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (provider, provider_uid)
      );
      CREATE TABLE IF NOT EXISTS mfa_progress (
        user_id INTEGER PRIMARY KEY REFERENCES mfa_users(id) ON DELETE CASCADE,
        data JSONB NOT NULL,                    -- 앱 진도/통계 직렬화(JSON)
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- [PP] PerlerPixel(비즈픽셀) 커뮤니티 게시판 — 별도 리포 ~/Documents/Jiny/PerlerPixel 소유.
      --      도안 공유 게시판. 소셜 로그인(pp_users), 오리지널만 정책 + 사후 신고 기반 모더레이션.
      --      pp_* 테이블 — 삭제·리팩터링 금지. 소유권: 리포 루트 CLAUDE.md 의 [PP] 섹션.
      CREATE TABLE IF NOT EXISTS pp_users (
        id SERIAL PRIMARY KEY,
        provider VARCHAR(10) NOT NULL,          -- apple | google | kakao
        provider_uid VARCHAR(255) NOT NULL,     -- 소셜 고유 식별자(sub)
        email VARCHAR(255),
        nickname VARCHAR(40) NOT NULL,
        nickname_set BOOLEAN DEFAULT FALSE,     -- 유저가 닉네임을 직접 정했는지(실명 노출 방지)
        avatar_url TEXT,
        status VARCHAR(10) DEFAULT 'active',    -- active | deleted(탈퇴 익명화)
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (provider, provider_uid)
      );
      ALTER TABLE pp_users ADD COLUMN IF NOT EXISTS nickname_set BOOLEAN DEFAULT FALSE;
      CREATE TABLE IF NOT EXISTS pp_posts (
        id SERIAL PRIMARY KEY,
        author_id INTEGER REFERENCES pp_users(id) ON DELETE SET NULL,  -- NULL=익명화(탈퇴)
        title VARCHAR(120) NOT NULL,
        description TEXT DEFAULT '',
        tags TEXT[] DEFAULT '{}',
        visibility VARCHAR(10) DEFAULT 'public',  -- public | unlisted(링크 전용)
        status VARCHAR(10) DEFAULT 'active',      -- active | pending(신고누적) | hidden(관리자) | deleted
        share_code VARCHAR(16) UNIQUE,            -- unlisted 접근용
        pattern_data BYTEA NOT NULL,              -- PatternCodec compact 바이너리
        preview_path TEXT,                        -- /pp/uploads/<file>.png
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        bead_count INTEGER NOT NULL,
        rights_ack_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,  -- 업로더 권리확인 동의 시각(신고 대응 근거)
        like_count INTEGER DEFAULT 0,
        download_count INTEGER DEFAULT 0,
        report_count INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_pp_posts_public_recent
        ON pp_posts(created_at DESC) WHERE visibility = 'public' AND status = 'active';
      CREATE INDEX IF NOT EXISTS idx_pp_posts_author ON pp_posts(author_id);
      CREATE TABLE IF NOT EXISTS pp_likes (
        user_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        post_id INTEGER REFERENCES pp_posts(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (user_id, post_id)
      );
      CREATE TABLE IF NOT EXISTS pp_downloads (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES pp_users(id) ON DELETE SET NULL,
        post_id INTEGER REFERENCES pp_posts(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      -- 유저별 1회만 집계(다운로드 카운트 부풀리기 방지). 재다운로드는 허용하되 카운트는 그대로.
      CREATE UNIQUE INDEX IF NOT EXISTS idx_pp_downloads_user_post ON pp_downloads(user_id, post_id);
      CREATE TABLE IF NOT EXISTS pp_reports (
        id SERIAL PRIMARY KEY,
        reporter_id INTEGER REFERENCES pp_users(id) ON DELETE SET NULL,
        post_id INTEGER REFERENCES pp_posts(id) ON DELETE CASCADE,
        reason VARCHAR(20) NOT NULL,              -- copyright|illegal|sexual|violence|spam|other
        detail TEXT DEFAULT '',
        status VARCHAR(10) DEFAULT 'open',        -- open | resolved | rejected
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        resolved_at TIMESTAMP,
        resolver VARCHAR(40),
        UNIQUE (reporter_id, post_id)
      );
      CREATE INDEX IF NOT EXISTS idx_pp_reports_status ON pp_reports(status, created_at DESC);
      CREATE TABLE IF NOT EXISTS pp_blocks (
        blocker_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        blocked_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (blocker_id, blocked_id)
      );
      CREATE TABLE IF NOT EXISTS pp_hidden (
        user_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        post_id INTEGER REFERENCES pp_posts(id) ON DELETE CASCADE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (user_id, post_id)
      );
      CREATE TABLE IF NOT EXISTS pp_user_bans (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        ban_type VARCHAR(10) NOT NULL,            -- upload | full
        reason TEXT,
        banned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        expires_at TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_pp_user_bans_user ON pp_user_bans(user_id);
      CREATE TABLE IF NOT EXISTS pp_admin_logs (
        id SERIAL PRIMARY KEY,
        admin VARCHAR(40),
        action VARCHAR(40) NOT NULL,
        target_type VARCHAR(20),
        target_id INTEGER,
        memo TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE TABLE IF NOT EXISTS pp_banned_keywords (
        word VARCHAR(60) PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS pp_inquiries (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        content TEXT NOT NULL,
        status VARCHAR(10) DEFAULT 'pending',   -- pending | replied
        reply TEXT,
        replied_at TIMESTAMP,
        is_read BOOLEAN DEFAULT FALSE,           -- 유저가 답변을 읽었는지
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_pp_inquiries_user ON pp_inquiries(user_id, created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_pp_inquiries_status ON pp_inquiries(status, created_at DESC);
      CREATE TABLE IF NOT EXISTS pp_device_tokens (
        token TEXT PRIMARY KEY,                   -- FCM 등록 토큰
        user_id INTEGER REFERENCES pp_users(id) ON DELETE CASCADE,
        platform VARCHAR(10),                     -- ios | android
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_pp_device_tokens_user ON pp_device_tokens(user_id);

      -- [LAB] 참고: 이 공유 DB 에는 라비린스 온라인 소유의 lab_* 테이블
      --       (lab_matches, lab_match_players, lab_user_stats)도 존재한다.
      --       그러나 그 테이블은 "별도 리포·별도 서버"(~/Documents/Jiny/LabyrinthOnline,
      --       독립 컨테이너)가 직접 생성/관리한다. 여기(듀오 서버)에서는 만들지도, 지우지도
      --       말 것. DB 정리 중 lab_* 가 보여도 "안 쓰는 테이블"이 아니다 — 운영 중인
      --       라비린스 서비스의 데이터다. 소유권: 리포 루트 CLAUDE.md 의 [LAB] 섹션.
    `);

    console.log('✅ Database tables ready');

    await ensureDefaultAdminAccount(client);

    // 초기 상점 아이템 seed
    await seedShopItems(client);

    // [SAJA] 사자툰 시드/백필. 실패해도 코어 서비스(듀오·규칙찾기) 부팅에는 영향 없도록 비치명적 처리.
    try {
      // 콘텐츠 seed (slug 충돌 시 건너뜀 → 관리자 수정 보존).
      await seedSajatoonIdioms(client);
      // 한자 풀이 백필(이미 시드된 사자성어에 chars 채움 — 비어 있을 때만).
      await backfillSajatoonChars(client);
      // 퀴즈 리스트 백필(단일 quiz → quizzes + 한자 의미 퀴즈 자동 생성).
      await backfillSajatoonQuizzes(client);
    } catch (sajaErr) {
      console.error('[SAJA] seed/backfill 실패 — 건너뜀(코어 서비스 영향 없음):', sajaErr);
    }

    client.release();
  } catch (error) {
    console.error('❌ Database connection failed:', error);
    throw error;
  }
}

async function ensureDefaultAdminAccount(client: any) {
  const username = process.env.ADMIN_DEFAULT_USERNAME || 'jiny';
  const password = process.env.ADMIN_DEFAULT_PASSWORD || '1204';
  const passwordHash = await bcrypt.hash(password, 10);

  const existing = await client.query(
    'SELECT id, password FROM dm_admin_accounts WHERE username = $1',
    [username]
  );

  if (existing.rows.length === 0) {
    await client.query(
      'INSERT INTO dm_admin_accounts (username, password) VALUES ($1, $2)',
      [username, passwordHash]
    );
    return;
  }

  const currentPassword = existing.rows[0].password as string;
  if (!currentPassword.startsWith('$2')) {
    await client.query(
      'UPDATE dm_admin_accounts SET password = $1 WHERE username = $2',
      [passwordHash, username]
    );
  }
}

// 상점 아이템 초기 데이터
async function seedShopItems(client: any) {
  // ON CONFLICT DO NOTHING을 사용하므로 항상 실행 (새 아이템만 추가됨)
  const items = [
    // === 프레임 ===
    // 기본 (무료)
    { category: 'frame', item_key: 'frame_default', name: '기본 프레임', description: '심플한 기본 프레임', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { borderColor: '#9E9E9E', glowColor: null, animation: null } },
    // Common
    { category: 'frame', item_key: 'frame_silver', name: '실버 프레임', description: '깔끔한 실버 테두리', price: 50, rarity: 'common', sort_order: 1, preview_data: { borderColor: '#C0C0C0', glowColor: '#E8E8E8', animation: null } },
    { category: 'frame', item_key: 'frame_bronze', name: '브론즈 프레임', description: '단단한 브론즈 테두리', price: 50, rarity: 'common', sort_order: 2, preview_data: { borderColor: '#CD7F32', glowColor: '#DEB887', animation: null } },
    { category: 'frame', item_key: 'frame_sky', name: '스카이 프레임', description: '맑은 하늘빛 테두리', price: 60, rarity: 'common', sort_order: 3, preview_data: { borderColor: '#87CEEB', glowColor: '#E0F7FA', animation: null } },
    // Rare
    { category: 'frame', item_key: 'frame_gold', name: '골드 프레임', description: '빛나는 골드 테두리', price: 150, rarity: 'rare', sort_order: 10, preview_data: { borderColor: '#FFD700', glowColor: '#FFF8DC', animation: 'shimmer' } },
    { category: 'frame', item_key: 'frame_ocean', name: '오션 프레임', description: '시원한 바다 느낌', price: 150, rarity: 'rare', sort_order: 11, preview_data: { borderColor: '#00CED1', glowColor: '#E0FFFF', animation: 'wave' } },
    { category: 'frame', item_key: 'frame_rose', name: '로즈 프레임', description: '우아한 장미빛', price: 150, rarity: 'rare', sort_order: 12, preview_data: { borderColor: '#FF69B4', glowColor: '#FFC0CB', animation: null } },
    { category: 'frame', item_key: 'frame_emerald', name: '에메랄드 프레임', description: '신비로운 초록빛', price: 180, rarity: 'rare', sort_order: 13, preview_data: { borderColor: '#50C878', glowColor: '#98FB98', animation: 'shimmer' } },
    { category: 'frame', item_key: 'frame_sunset', name: '선셋 프레임', description: '노을빛 테두리', price: 180, rarity: 'rare', sort_order: 14, preview_data: { borderColor: '#FF7F50', glowColor: '#FFD700', animation: null } },
    // Epic
    { category: 'frame', item_key: 'frame_diamond', name: '다이아 프레임', description: '고급스러운 다이아몬드', price: 300, rarity: 'epic', sort_order: 20, preview_data: { borderColor: '#B9F2FF', glowColor: '#E0FFFF', animation: 'sparkle' } },
    { category: 'frame', item_key: 'frame_aurora', name: '오로라 프레임', description: '신비로운 오로라 빛', price: 350, rarity: 'epic', sort_order: 21, preview_data: { borderColor: '#7B68EE', glowColor: '#E6E6FA', animation: 'aurora' } },
    { category: 'frame', item_key: 'frame_neon_blue', name: '네온 블루', description: '빛나는 네온 블루', price: 350, rarity: 'epic', sort_order: 22, preview_data: { borderColor: '#00FFFF', glowColor: '#00FFFF', animation: 'pulse' } },
    { category: 'frame', item_key: 'frame_neon_pink', name: '네온 핑크', description: '빛나는 네온 핑크', price: 350, rarity: 'epic', sort_order: 23, preview_data: { borderColor: '#FF1493', glowColor: '#FF1493', animation: 'pulse' } },
    { category: 'frame', item_key: 'frame_galaxy', name: '갤럭시 프레임', description: '은하수를 담은 프레임', price: 400, rarity: 'epic', sort_order: 24, preview_data: { borderColor: '#9400D3', glowColor: '#4B0082', animation: 'sparkle' } },
    // Legendary
    { category: 'frame', item_key: 'frame_flame', name: '불꽃 프레임', description: '타오르는 불꽃 효과', price: 500, rarity: 'legendary', sort_order: 30, preview_data: { borderColor: '#FF4500', glowColor: '#FF6347', animation: 'flame' } },
    { category: 'frame', item_key: 'frame_rainbow', name: '레인보우 프레임', description: '무지개빛 그라데이션', price: 500, rarity: 'legendary', sort_order: 31, preview_data: { borderColor: 'rainbow', glowColor: '#FFFFFF', animation: 'rainbow' } },
    { category: 'frame', item_key: 'frame_lightning', name: '라이트닝 프레임', description: '번개치는 프레임', price: 600, rarity: 'legendary', sort_order: 32, preview_data: { borderColor: '#FFFF00', glowColor: '#FFD700', animation: 'lightning' } },
    { category: 'frame', item_key: 'frame_void', name: '보이드 프레임', description: '심연의 어둠', price: 600, rarity: 'legendary', sort_order: 33, preview_data: { borderColor: '#1C1C1C', glowColor: '#4B0082', animation: 'void' } },
    { category: 'frame', item_key: 'frame_royal', name: '로얄 프레임', description: '왕족의 프레임', price: 800, rarity: 'legendary', sort_order: 34, preview_data: { borderColor: '#8B008B', glowColor: '#FFD700', animation: 'royal' } },
    // 기간제
    { category: 'frame', item_key: 'frame_rainbow_7d', name: '레인보우 프레임 (7일)', description: '7일 한정 레인보우 프레임', price: 50, rarity: 'rare', duration_days: 7, sort_order: 50, preview_data: { borderColor: 'rainbow', glowColor: '#FFFFFF', animation: 'rainbow' } },
    { category: 'frame', item_key: 'frame_flame_7d', name: '불꽃 프레임 (7일)', description: '7일 한정 불꽃 프레임', price: 60, rarity: 'epic', duration_days: 7, sort_order: 51, preview_data: { borderColor: '#FF4500', glowColor: '#FF6347', animation: 'flame' } },

    // === 칭호 ===
    // 기본 (무료)
    { category: 'title', item_key: 'title_default', name: '초보 게이머', description: '모든 모험은 여기서 시작!', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { textColor: '#9E9E9E', icon: null, gradient: null } },
    // Common
    { category: 'title', item_key: 'title_winner', name: '승리의 주인공', description: '승리를 향해!', price: 100, rarity: 'common', sort_order: 1, preview_data: { textColor: '#4CAF50', icon: '🏆', gradient: null } },
    { category: 'title', item_key: 'title_lucky', name: '행운아', description: '오늘도 운이 좋군!', price: 100, rarity: 'common', sort_order: 2, preview_data: { textColor: '#FFC107', icon: '🍀', gradient: null } },
    { category: 'title', item_key: 'title_challenger', name: '도전자', description: '끊임없이 도전한다', price: 100, rarity: 'common', sort_order: 3, preview_data: { textColor: '#FF9800', icon: '💪', gradient: null } },
    { category: 'title', item_key: 'title_explorer', name: '탐험가', description: '새로운 것을 찾아서', price: 100, rarity: 'common', sort_order: 4, preview_data: { textColor: '#795548', icon: '🧭', gradient: null } },
    { category: 'title', item_key: 'title_dreamer', name: '몽상가', description: '꿈을 꾸는 자', price: 80, rarity: 'common', sort_order: 5, preview_data: { textColor: '#9575CD', icon: '💭', gradient: null } },
    // Rare
    { category: 'title', item_key: 'title_veteran', name: '베테랑', description: '수많은 전투를 경험한 자', price: 200, rarity: 'rare', sort_order: 10, preview_data: { textColor: '#2196F3', icon: '⭐', gradient: null } },
    { category: 'title', item_key: 'title_strategist', name: '전략가', description: '치밀한 전략으로 승리한다', price: 200, rarity: 'rare', sort_order: 11, preview_data: { textColor: '#9C27B0', icon: '🧠', gradient: null } },
    { category: 'title', item_key: 'title_speedster', name: '질주하는 자', description: '빠르게, 더 빠르게!', price: 200, rarity: 'rare', sort_order: 12, preview_data: { textColor: '#00BCD4', icon: '⚡', gradient: null } },
    { category: 'title', item_key: 'title_guardian', name: '수호자', description: '지켜야 할 것이 있다', price: 220, rarity: 'rare', sort_order: 13, preview_data: { textColor: '#3F51B5', icon: '🛡️', gradient: null } },
    { category: 'title', item_key: 'title_hunter', name: '사냥꾼', description: '목표를 향해 달린다', price: 220, rarity: 'rare', sort_order: 14, preview_data: { textColor: '#8D6E63', icon: '🎯', gradient: null } },
    { category: 'title', item_key: 'title_genius', name: '천재', description: '타고난 재능의 소유자', price: 250, rarity: 'rare', sort_order: 15, preview_data: { textColor: '#673AB7', icon: '🎓', gradient: null } },
    { category: 'title', item_key: 'title_warrior', name: '전사', description: '전장을 누비는 자', price: 250, rarity: 'rare', sort_order: 16, preview_data: { textColor: '#F44336', icon: '⚔️', gradient: null } },
    // Epic
    { category: 'title', item_key: 'title_champion', name: '챔피언', description: '최고의 자리에 오른 자', price: 400, rarity: 'epic', sort_order: 20, preview_data: { textColor: '#FF5722', icon: '👑', gradient: ['#FF5722', '#FFC107'] } },
    { category: 'title', item_key: 'title_master', name: '마스터', description: '게임의 달인', price: 450, rarity: 'epic', sort_order: 21, preview_data: { textColor: '#E91E63', icon: '💎', gradient: ['#E91E63', '#9C27B0'] } },
    { category: 'title', item_key: 'title_conqueror', name: '정복자', description: '모든 것을 정복한다', price: 450, rarity: 'epic', sort_order: 22, preview_data: { textColor: '#D32F2F', icon: '🗡️', gradient: ['#D32F2F', '#FF8A65'] } },
    { category: 'title', item_key: 'title_shadow', name: '그림자', description: '어둠 속의 존재', price: 400, rarity: 'epic', sort_order: 23, preview_data: { textColor: '#37474F', icon: '🌑', gradient: ['#263238', '#546E7A'] } },
    { category: 'title', item_key: 'title_phoenix', name: '불사조', description: '재에서 일어난 자', price: 500, rarity: 'epic', sort_order: 24, preview_data: { textColor: '#FF5722', icon: '🔥', gradient: ['#FF5722', '#FFEB3B'] } },
    { category: 'title', item_key: 'title_mystic', name: '신비술사', description: '비밀스러운 힘의 소유자', price: 500, rarity: 'epic', sort_order: 25, preview_data: { textColor: '#7E57C2', icon: '🔮', gradient: ['#7E57C2', '#00BCD4'] } },
    // Legendary
    { category: 'title', item_key: 'title_legend', name: '전설', description: '전설로 기억될 자', price: 800, rarity: 'legendary', sort_order: 30, preview_data: { textColor: '#FFD700', icon: '🌟', gradient: ['#FFD700', '#FF8C00', '#FF4500'] } },
    { category: 'title', item_key: 'title_god', name: '신', description: '게임의 신', price: 1000, rarity: 'legendary', sort_order: 31, preview_data: { textColor: '#FFFFFF', icon: '👼', gradient: ['#FFD700', '#FFFACD'] } },
    { category: 'title', item_key: 'title_emperor', name: '황제', description: '모든 것 위에 군림한다', price: 1000, rarity: 'legendary', sort_order: 32, preview_data: { textColor: '#8B008B', icon: '👑', gradient: ['#8B008B', '#FFD700'] } },
    { category: 'title', item_key: 'title_overlord', name: '대군주', description: '모든 것을 지배한다', price: 1200, rarity: 'legendary', sort_order: 33, preview_data: { textColor: '#1A237E', icon: '⚜️', gradient: ['#1A237E', '#C62828'] } },
    { category: 'title', item_key: 'title_immortal', name: '불멸의 존재', description: '영원히 기억될 자', price: 1500, rarity: 'legendary', sort_order: 34, preview_data: { textColor: '#00BFA5', icon: '♾️', gradient: ['#00BFA5', '#FFAB00', '#FF4081'] } },

    // === 테마 ===
    // 기본 (무료)
    { category: 'theme', item_key: 'theme_default', name: '기본 테마', description: '깔끔한 기본 배경', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { gradientColors: ['#6C5CE7', '#A29BFE'], particleType: null } },
    // Common
    { category: 'theme', item_key: 'theme_mint', name: '민트 테마', description: '상쾌한 민트색 배경', price: 100, rarity: 'common', sort_order: 1, preview_data: { gradientColors: ['#00B894', '#55EFC4'], particleType: null } },
    { category: 'theme', item_key: 'theme_peach', name: '피치 테마', description: '따뜻한 복숭아색 배경', price: 100, rarity: 'common', sort_order: 2, preview_data: { gradientColors: ['#FAB1A0', '#FFEAA7'], particleType: null } },
    { category: 'theme', item_key: 'theme_lavender', name: '라벤더 테마', description: '은은한 라벤더색 배경', price: 100, rarity: 'common', sort_order: 3, preview_data: { gradientColors: ['#A29BFE', '#DFE6E9'], particleType: null } },
    // Rare
    { category: 'theme', item_key: 'theme_ocean', name: '오션 테마', description: '시원한 바다 배경', price: 200, rarity: 'rare', sort_order: 10, preview_data: { gradientColors: ['#0077B6', '#00B4D8', '#90E0EF'], particleType: 'bubbles' } },
    { category: 'theme', item_key: 'theme_sunset', name: '선셋 테마', description: '아름다운 노을 배경', price: 200, rarity: 'rare', sort_order: 11, preview_data: { gradientColors: ['#FF6B6B', '#FFA07A', '#FFD93D'], particleType: null } },
    { category: 'theme', item_key: 'theme_forest', name: '포레스트 테마', description: '평화로운 숲 배경', price: 200, rarity: 'rare', sort_order: 12, preview_data: { gradientColors: ['#2D5A27', '#5DAB4D', '#98D989'], particleType: 'leaves' } },
    { category: 'theme', item_key: 'theme_cherry', name: '체리블로썸 테마', description: '벚꽃이 흩날리는 배경', price: 250, rarity: 'rare', sort_order: 13, preview_data: { gradientColors: ['#FF69B4', '#FFB6C1', '#FFDAB9'], particleType: 'petals' } },
    { category: 'theme', item_key: 'theme_midnight', name: '미드나잇 테마', description: '고요한 밤하늘 배경', price: 250, rarity: 'rare', sort_order: 14, preview_data: { gradientColors: ['#191970', '#000080', '#0F0F3D'], particleType: null } },
    { category: 'theme', item_key: 'theme_autumn', name: '어텀 테마', description: '가을 낙엽 배경', price: 250, rarity: 'rare', sort_order: 15, preview_data: { gradientColors: ['#D35400', '#E67E22', '#F39C12'], particleType: 'leaves' } },
    // Epic
    { category: 'theme', item_key: 'theme_galaxy', name: '갤럭시 테마', description: '은하수 별빛 배경', price: 400, rarity: 'epic', sort_order: 20, preview_data: { gradientColors: ['#0F0C29', '#302B63', '#24243E'], particleType: 'stars' } },
    { category: 'theme', item_key: 'theme_aurora', name: '오로라 테마', description: '신비로운 오로라 배경', price: 400, rarity: 'epic', sort_order: 21, preview_data: { gradientColors: ['#0F2027', '#203A43', '#2C5364'], particleType: 'aurora' } },
    { category: 'theme', item_key: 'theme_cyberpunk', name: '사이버펑크 테마', description: '미래 도시 배경', price: 450, rarity: 'epic', sort_order: 22, preview_data: { gradientColors: ['#0D0D0D', '#1A1A2E', '#16213E'], particleType: 'neon' } },
    { category: 'theme', item_key: 'theme_underwater', name: '딥씨 테마', description: '깊은 바다 속 배경', price: 450, rarity: 'epic', sort_order: 23, preview_data: { gradientColors: ['#000428', '#004E92', '#007BFF'], particleType: 'bubbles' } },
    { category: 'theme', item_key: 'theme_northern', name: '노던라이트 테마', description: '북극 오로라 배경', price: 500, rarity: 'epic', sort_order: 24, preview_data: { gradientColors: ['#1A1A2E', '#16213E', '#0F3460'], particleType: 'aurora' } },
    // Legendary
    { category: 'theme', item_key: 'theme_neon', name: '네온 테마', description: '화려한 네온 배경', price: 600, rarity: 'legendary', sort_order: 30, preview_data: { gradientColors: ['#FF00FF', '#00FFFF', '#FF00FF'], particleType: 'neon' } },
    { category: 'theme', item_key: 'theme_inferno', name: '인페르노 테마', description: '타오르는 불꽃 배경', price: 600, rarity: 'legendary', sort_order: 31, preview_data: { gradientColors: ['#1A0000', '#8B0000', '#FF4500'], particleType: 'fire' } },
    { category: 'theme', item_key: 'theme_void', name: '보이드 테마', description: '심연의 어둠 배경', price: 700, rarity: 'legendary', sort_order: 32, preview_data: { gradientColors: ['#000000', '#0D0D0D', '#1A0033'], particleType: 'void' } },
    { category: 'theme', item_key: 'theme_rainbow', name: '레인보우 테마', description: '무지개빛 배경', price: 700, rarity: 'legendary', sort_order: 33, preview_data: { gradientColors: ['#FF0000', '#FF7F00', '#FFFF00', '#00FF00', '#0000FF', '#4B0082', '#8F00FF'], particleType: 'sparkle' } },
    { category: 'theme', item_key: 'theme_celestial', name: '천상 테마', description: '신성한 빛의 배경', price: 800, rarity: 'legendary', sort_order: 34, preview_data: { gradientColors: ['#FFFACD', '#FFE4B5', '#FFDAB9'], particleType: 'holy' } },

    // === 티켓 ===
    { category: 'ticket', item_key: 'ticket_delete_loss', name: '1패 삭제권', description: '선택한 게임에서 패배 1회 삭제', price: 50, rarity: 'common', sort_order: 0, preview_data: { icon: '🎫', effect: 'delete_loss' } },
    { category: 'ticket', item_key: 'ticket_delete_loss_3', name: '3패 삭제권', description: '선택한 게임에서 패배 3회 삭제 (10% 할인)', price: 135, rarity: 'rare', sort_order: 1, preview_data: { icon: '🎟️', effect: 'delete_loss_3' } },
    { category: 'ticket', item_key: 'ticket_change_nickname', name: '닉네임 변경권', description: '닉네임을 변경합니다', price: 100, rarity: 'rare', sort_order: 2, preview_data: { icon: '✏️', effect: 'change_nickname' } },

    // === 아바타 ===
    // 기본 (무료)
    { category: 'avatar', item_key: 'avatar_default', name: '기본', description: '기본 아바타', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { emoji: '👤', bgColor: '#E0E0E0' } },
    // Common
    { category: 'avatar', item_key: 'avatar_smile', name: '스마일', description: '밝은 미소', price: 30, rarity: 'common', sort_order: 1, preview_data: { emoji: '😊', bgColor: '#FFF9C4' } },
    { category: 'avatar', item_key: 'avatar_cool', name: '쿨가이', description: '멋진 선글라스', price: 30, rarity: 'common', sort_order: 2, preview_data: { emoji: '😎', bgColor: '#BBDEFB' } },
    { category: 'avatar', item_key: 'avatar_cat', name: '고양이', description: '귀여운 고양이', price: 50, rarity: 'common', sort_order: 3, preview_data: { emoji: '🐱', bgColor: '#FFE0B2' } },
    { category: 'avatar', item_key: 'avatar_dog', name: '강아지', description: '충직한 강아지', price: 50, rarity: 'common', sort_order: 4, preview_data: { emoji: '🐶', bgColor: '#D7CCC8' } },
    { category: 'avatar', item_key: 'avatar_bear', name: '곰돌이', description: '포근한 곰돌이', price: 50, rarity: 'common', sort_order: 5, preview_data: { emoji: '🐻', bgColor: '#A1887F' } },
    { category: 'avatar', item_key: 'avatar_monkey', name: '원숭이', description: '장난꾸러기 원숭이', price: 50, rarity: 'common', sort_order: 6, preview_data: { emoji: '🐵', bgColor: '#FFCC80' } },
    // Rare
    { category: 'avatar', item_key: 'avatar_fox', name: '여우', description: '영리한 여우', price: 100, rarity: 'rare', sort_order: 10, preview_data: { emoji: '🦊', bgColor: '#FFCCBC' } },
    { category: 'avatar', item_key: 'avatar_lion', name: '사자', description: '용맹한 사자', price: 100, rarity: 'rare', sort_order: 11, preview_data: { emoji: '🦁', bgColor: '#FFE082' } },
    { category: 'avatar', item_key: 'avatar_panda', name: '판다', description: '귀여운 판다', price: 100, rarity: 'rare', sort_order: 12, preview_data: { emoji: '🐼', bgColor: '#F5F5F5' } },
    { category: 'avatar', item_key: 'avatar_rabbit', name: '토끼', description: '깜찍한 토끼', price: 100, rarity: 'rare', sort_order: 13, preview_data: { emoji: '🐰', bgColor: '#FCE4EC' } },
    { category: 'avatar', item_key: 'avatar_tiger', name: '호랑이', description: '힘센 호랑이', price: 120, rarity: 'rare', sort_order: 14, preview_data: { emoji: '🐯', bgColor: '#FFE0B2' } },
    { category: 'avatar', item_key: 'avatar_owl', name: '부엉이', description: '지혜로운 부엉이', price: 120, rarity: 'rare', sort_order: 15, preview_data: { emoji: '🦉', bgColor: '#D7CCC8' } },
    { category: 'avatar', item_key: 'avatar_penguin', name: '펭귄', description: '귀여운 펭귄', price: 120, rarity: 'rare', sort_order: 16, preview_data: { emoji: '🐧', bgColor: '#B3E5FC' } },
    { category: 'avatar', item_key: 'avatar_koala', name: '코알라', description: '졸린 코알라', price: 120, rarity: 'rare', sort_order: 17, preview_data: { emoji: '🐨', bgColor: '#CFD8DC' } },
    // Epic
    { category: 'avatar', item_key: 'avatar_dragon', name: '드래곤', description: '강력한 드래곤', price: 250, rarity: 'epic', sort_order: 20, preview_data: { emoji: '🐉', bgColor: '#C8E6C9' } },
    { category: 'avatar', item_key: 'avatar_unicorn', name: '유니콘', description: '신비로운 유니콘', price: 250, rarity: 'epic', sort_order: 21, preview_data: { emoji: '🦄', bgColor: '#F3E5F5' } },
    { category: 'avatar', item_key: 'avatar_phoenix', name: '피닉스', description: '불사조', price: 300, rarity: 'epic', sort_order: 22, preview_data: { emoji: '🔥', bgColor: '#FFCDD2' } },
    { category: 'avatar', item_key: 'avatar_shark', name: '상어', description: '바다의 포식자', price: 280, rarity: 'epic', sort_order: 23, preview_data: { emoji: '🦈', bgColor: '#B3E5FC' } },
    { category: 'avatar', item_key: 'avatar_eagle', name: '독수리', description: '하늘의 왕', price: 280, rarity: 'epic', sort_order: 24, preview_data: { emoji: '🦅', bgColor: '#FFECB3' } },
    { category: 'avatar', item_key: 'avatar_wolf', name: '늑대', description: '고독한 늑대', price: 300, rarity: 'epic', sort_order: 25, preview_data: { emoji: '🐺', bgColor: '#B0BEC5' } },
    // Legendary
    { category: 'avatar', item_key: 'avatar_alien', name: '외계인', description: '미지의 존재', price: 500, rarity: 'legendary', sort_order: 30, preview_data: { emoji: '👽', bgColor: '#B2DFDB' } },
    { category: 'avatar', item_key: 'avatar_robot', name: '로봇', description: '하이테크 로봇', price: 500, rarity: 'legendary', sort_order: 31, preview_data: { emoji: '🤖', bgColor: '#CFD8DC' } },
    { category: 'avatar', item_key: 'avatar_ghost', name: '유령', description: '신비로운 유령', price: 500, rarity: 'legendary', sort_order: 32, preview_data: { emoji: '👻', bgColor: '#E1BEE7' } },
    { category: 'avatar', item_key: 'avatar_devil', name: '악마', description: '장난꾸러기 악마', price: 600, rarity: 'legendary', sort_order: 33, preview_data: { emoji: '😈', bgColor: '#EF9A9A' } },
    { category: 'avatar', item_key: 'avatar_angel', name: '천사', description: '순수한 천사', price: 600, rarity: 'legendary', sort_order: 34, preview_data: { emoji: '😇', bgColor: '#FFF59D' } },
    { category: 'avatar', item_key: 'avatar_crown', name: '왕', description: '최고의 존재', price: 800, rarity: 'legendary', sort_order: 35, preview_data: { emoji: '🤴', bgColor: '#FFD54F' } },
  ];

  for (const item of items) {
    await client.query(
      `INSERT INTO dm_shop_items (category, item_key, name, description, price, duration_days, rarity, preview_data, sort_order, is_active, is_default)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE, $10)
       ON CONFLICT (item_key) DO NOTHING`,
      [
        item.category,
        item.item_key,
        item.name,
        item.description,
        item.price,
        item.duration_days || null,
        item.rarity,
        JSON.stringify(item.preview_data),
        item.sort_order,
        item.is_default || false,
      ]
    );
  }

  console.log('✅ Shop items seeded');
}

// ================================================================
// [SAJA] 사자툰(SajaToon) 소유 — 사자성어 콘텐츠 seed. 삭제 금지.
// slug 충돌 시 DO NOTHING(관리자/운영 중 수정 보존). 새 사자성어만 추가된다.
// comic 패널: { caption(나레이션), emoji(플레이스홀더 일러스트 힌트),
//   bg(플레이스홀더 배경색), imageKey(실제 웹툰 PNG 슬롯 키) }.
// 앱은 imageKey 에 해당하는 실제 이미지가 없으면 emoji+bg 로 플레이스홀더를 그린다.
// quiz: { question, options[4], answerIndex(0-based), explanation }.
// ================================================================
async function seedSajatoonIdioms(client: any) {
  // 시드는 '최초 1회만'. sj_meta.seeded 플래그가 있으면 건너뛴다.
  // (관리자가 admin 에서 사자성어를 지워도 재부팅 때 되살아나지 않도록.)
  const seededFlag = await client.query(`SELECT 1 FROM sj_meta WHERE key = 'seeded' LIMIT 1`);
  if (seededFlag.rows.length > 0) return;

  // 플래그는 없지만 이미 콘텐츠가 있으면(기존 운영 데이터) 시드 없이 플래그만 세팅.
  const existing = await client.query(`SELECT COUNT(*)::int AS c FROM sj_idioms`);
  if (existing.rows[0].c > 0) {
    await client.query(
      `INSERT INTO sj_meta (key, value) VALUES ('seeded', '1') ON CONFLICT (key) DO NOTHING`
    );
    console.log('✅ SajaToon seed skipped (콘텐츠 이미 존재 → 플래그만 설정)');
    return;
  }

  const panel = (caption: string, emoji: string, bg: string) => ({ caption, emoji, bg });
  // 각 사자성어의 4컷 만화 + 퀴즈. 콘텐츠는 운영 중 admin 으로 보강 가능.
  const idioms = [
    {
      slug: 'oilmujung', hanja: '五里霧中', reading: '오리무중', category: '처세', level: 1, day_index: 1,
      meaning: '5리(약 2km)나 되는 짙은 안갯속에 있다는 뜻으로, 무슨 일에 대해 갈피를 잡지 못하고 어찌할 바를 모르는 상태.',
      origin: '후한서(後漢書)에 나온다. 학자 장해(張楷)는 도술로 사방 5리에 안개를 일으킬 수 있었다고 한다. 사람들이 그를 찾아와도 안개에 가려 길을 잃었다는 데서, 방향을 잃고 헤매는 상황을 가리키게 되었다.',
      modern_example: '"새 프로젝트 방향이 오리무중이라, 팀 전체가 뭘 먼저 해야 할지 몰라 멈춰 있었다."',
      comic: [
        panel('주인공이 깊은 안갯속을 걷는다.', '🌫️', '#E6E2DA'),
        panel('한 치 앞도 보이지 않아 길을 잃는다.', '😵‍💫', '#D8D2C6'),
        panel('어느 쪽으로 가야 할지 도무지 알 수 없다.', '🧭', '#CFC9BB'),
        panel('"이게 바로 오리무중이구나!"', '💡', '#F4C95D'),
      ],
      quiz: { question: '‘오리무중(五里霧中)’의 뜻으로 알맞은 것은?', options: ['일이 술술 잘 풀림', '갈피를 못 잡고 헤맴', '한 번에 두 가지 이득', '준비를 철저히 함'], answerIndex: 1, explanation: '짙은 안갯속처럼 방향을 잃고 어찌할 바를 모르는 상태를 뜻해요.' },
    },
    {
      slug: 'ilseokijo', hanja: '一石二鳥', reading: '일석이조', category: '지혜', level: 1, day_index: 2,
      meaning: '돌 하나를 던져 새 두 마리를 잡는다는 뜻으로, 한 가지 일로 두 가지 이익을 얻음.',
      origin: '본래 영어 속담 "kill two birds with one stone"에서 유래해 한자로 옮겨진 표현으로, 동아시아권에서 널리 쓰이게 되었다. 같은 뜻의 한자성어로 일거양득(一擧兩得)이 있다.',
      modern_example: '"계단을 이용하면 운동도 되고 시간도 아끼니 일석이조다."',
      comic: [
        panel('손에 돌멩이 하나를 든 주인공.', '🪨', '#DCE6DA'),
        panel('나뭇가지에 새 두 마리가 앉아 있다.', '🐦🐦', '#CFE0CB'),
        panel('돌을 휙— 던진다.', '💨', '#BFD6BA'),
        panel('한 번에 두 마리! "일석이조!"', '🎯', '#F4C95D'),
      ],
      quiz: { question: '‘일석이조’와 뜻이 가장 비슷한 말은?', options: ['일거양득(一擧兩得)', '오리무중(五里霧中)', '작심삼일(作心三日)', '자업자득(自業自得)'], answerIndex: 0, explanation: '한 번에 두 이익을 얻는다는 점에서 일거양득과 같은 뜻이에요.' },
    },
    {
      slug: 'saeongjima', hanja: '塞翁之馬', reading: '새옹지마', category: '인생', level: 2, day_index: 3,
      meaning: '변방 노인의 말(馬)이라는 뜻으로, 인생의 화(禍)와 복(福)은 변화가 많아 예측하기 어려움을 이르는 말.',
      origin: '회남자(淮南子)에 나온다. 변방 노인의 말이 도망가(화) → 준마를 데리고 돌아오고(복) → 아들이 그 말을 타다 다리를 다치나(화) → 그 덕에 전쟁 징집을 면한다(복). 길흉화복은 돌고 돈다는 교훈이다.',
      modern_example: '"시험에 떨어져 낙심했지만, 그 덕에 더 좋은 길을 찾았다. 인생은 새옹지마다."',
      comic: [
        panel('노인의 말이 국경 너머로 달아난다.', '🐎', '#E3DCEA'),
        panel('며칠 뒤, 멋진 준마를 데리고 돌아온다.', '🐴✨', '#D6CDE2'),
        panel('아들이 그 말을 타다 다리를 다친다.', '🤕', '#C8BDD9'),
        panel('그 덕에 전쟁 징집을 피한다. "새옹지마!"', '🕊️', '#F4C95D'),
      ],
      quiz: { question: '‘새옹지마’가 전하는 교훈으로 알맞은 것은?', options: ['노력은 배신하지 않는다', '화와 복은 예측하기 어렵다', '지나치면 모자람만 못하다', '뭉치면 강해진다'], answerIndex: 1, explanation: '좋은 일과 나쁜 일은 돌고 돌아, 길흉화복을 미리 알 수 없다는 뜻이에요.' },
    },
    {
      slug: 'ugongisan', hanja: '愚公移山', reading: '우공이산', category: '노력', level: 2, day_index: 4,
      meaning: '우공이 산을 옮긴다는 뜻으로, 어떤 큰 일이라도 끊임없이 꾸준히 노력하면 반드시 이루어짐.',
      origin: '열자(列子)에 나온다. 90세 노인 우공이 집 앞을 막은 두 산을 옮기겠다며 흙을 나르자 사람들이 비웃었다. 그러나 "내가 못 하면 자손이, 자손이 못 하면 그 자손이 잇는다"는 말에 하늘이 감동해 산을 옮겨 주었다고 한다.',
      modern_example: '"매일 30분씩 공부한 것이 쌓여 결국 합격했다. 우공이산의 힘이다."',
      comic: [
        panel('집 앞을 가로막은 거대한 두 산.', '⛰️', '#DDE3E6'),
        panel('90세 우공이 흙을 한 줌씩 나른다.', '👴🪣', '#CFD9DE'),
        panel('"못 하면 자손이 잇는다!" 사람들이 비웃는다.', '😅', '#C1CCD3'),
        panel('마침내 산이 옮겨진다. "우공이산!"', '🌄', '#F4C95D'),
      ],
      quiz: { question: '‘우공이산’이 강조하는 것은?', options: ['타고난 재능', '꾸준한 노력', '빠른 판단', '운과 요행'], answerIndex: 1, explanation: '아무리 큰 일도 멈추지 않고 꾸준히 하면 이뤄진다는 뜻이에요.' },
    },
    {
      slug: 'hwaryongjeongjeong', hanja: '畵龍點睛', reading: '화룡점정', category: '지혜', level: 2, day_index: 5,
      meaning: '용을 그린 뒤 마지막으로 눈동자를 그려 넣는다는 뜻으로, 가장 중요한 부분을 마무리해 일을 완성함.',
      origin: '역대명화기(歷代名畵記)에 나온다. 화가 장승요가 벽에 용을 그리고 눈동자를 찍지 않자 사람들이 의아해했다. 시험 삼아 눈동자를 찍자 용이 벽을 박차고 하늘로 날아올랐다고 한다.',
      modern_example: '"발표 자료의 마지막 한 문장이 화룡점정이 되어 모두를 설득했다."',
      comic: [
        panel('화가가 벽에 멋진 용을 그린다.', '🐉', '#E6DAD6'),
        panel('그런데 눈동자만 찍지 않는다.', '👁️‍🗨️', '#E0CFC9'),
        panel('마지막으로 눈동자를 콕— 찍자', '🖌️', '#D9C4BD'),
        panel('용이 하늘로 날아오른다! "화룡점정!"', '✨🐲', '#F4C95D'),
      ],
      quiz: { question: '‘화룡점정’의 의미로 알맞은 것은?', options: ['처음부터 다시 시작함', '가장 중요한 마무리', '쓸데없는 군더더기', '준비가 부족함'], answerIndex: 1, explanation: '마지막 핵심을 더해 전체를 완성한다는 뜻이에요. 용의 눈동자처럼요!' },
    },
    {
      slug: 'daegimanseong', hanja: '大器晩成', reading: '대기만성', category: '인생', level: 2, day_index: 6,
      meaning: '큰 그릇은 늦게 만들어진다는 뜻으로, 크게 될 사람은 많은 노력과 시간을 들여 늦게 이루어짐.',
      origin: '노자(老子) 도덕경에 "큰 그릇은 늦게 이루어진다(大器晩成)"는 구절에서 나왔다. 삼국지의 최염도 늦게 빛을 본 인물로, 대기만성의 예로 자주 인용된다.',
      modern_example: '"30대 후반에야 빛을 본 그는 대기만성형 배우로 불린다."',
      comic: [
        panel('작은 그릇들은 금세 완성된다.', '🍵', '#DCE0E6'),
        panel('한 도공이 거대한 그릇을 빚는다.', '🪔', '#CED4DE'),
        panel('오랜 시간 정성껏 굽고 또 굽는다.', '🔥⏳', '#C0C8D4'),
        panel('마침내 완성된 대작! "대기만성!"', '🏆', '#F4C95D'),
      ],
      quiz: { question: '‘대기만성’의 뜻으로 알맞은 것은?', options: ['크게 될 사람은 늦게 이뤄짐', '한 번에 두 이득을 봄', '작은 일에 크게 화냄', '시작이 반이다'], answerIndex: 0, explanation: '큰 그릇이 천천히 완성되듯, 큰 인물은 시간이 걸려 이뤄진다는 뜻이에요.' },
    },
    {
      slug: 'gwayubulgeup', hanja: '過猶不及', reading: '과유불급', category: '처세', level: 2, day_index: 7,
      meaning: '지나침은 미치지 못함과 같다는 뜻으로, 정도를 넘어서는 것은 부족함과 다를 바 없음.',
      origin: '논어(論語) 선진편에 나온다. 제자가 두 사람 중 누가 더 나으냐고 묻자 공자는 "지나친 것은 미치지 못한 것과 같다(過猶不及)"고 답했다. 중용(中庸)의 미덕을 강조한 말이다.',
      modern_example: '"건강을 위한 운동도 과유불급, 무리하면 오히려 몸을 해친다."',
      comic: [
        panel('친구가 양념을 적당히 넣는다.', '🧂', '#DEE6DA'),
        panel('주인공은 "더 많이!" 하고 잔뜩 붓는다.', '😋', '#D2E0CC'),
        panel('너무 짜서 먹을 수가 없다.', '😣', '#C5D6BE'),
        panel('"지나치면 모자람만 못해. 과유불급!"', '⚖️', '#F4C95D'),
      ],
      quiz: { question: '‘과유불급’이 강조하는 가치는?', options: ['많을수록 좋다', '알맞은 정도(중용)', '빠를수록 좋다', '강할수록 좋다'], answerIndex: 1, explanation: '지나침은 부족함과 같으니, 알맞은 정도를 지키라는 뜻이에요.' },
    },
    {
      slug: 'yubimuhwan', hanja: '有備無患', reading: '유비무환', category: '처세', level: 1, day_index: 8,
      meaning: '준비가 되어 있으면 근심할 것이 없다는 뜻으로, 미리 대비하면 걱정이 없음.',
      origin: '서경(書經)에 "준비가 있으면 근심이 없다(有備無患)"는 구절에서 나왔다. 춘추시대 진나라의 신하 위강이 임금에게 이 말을 들어 방심을 경계하게 했다는 일화가 전한다.',
      modern_example: '"우산을 미리 챙겼더니 소나기에도 끄떡없었다. 유비무환이다."',
      comic: [
        panel('맑은 날, 주인공이 우산을 챙긴다.', '☀️🌂', '#DEE2E6'),
        panel('친구는 "필요 없어" 하며 그냥 나간다.', '🙅', '#D0D6DE'),
        panel('갑자기 쏟아지는 소나기!', '🌧️', '#C2CAD6'),
        panel('주인공만 멀쩡하다. "유비무환!"', '😎🌂', '#F4C95D'),
      ],
      quiz: { question: '‘유비무환’의 교훈으로 알맞은 것은?', options: ['미리 대비하면 걱정이 없다', '지나치면 모자람만 못하다', '한 번에 두 이득을 본다', '꾸준하면 이룬다'], answerIndex: 0, explanation: '미리 준비해 두면 어떤 일이 닥쳐도 근심이 없다는 뜻이에요.' },
    },
    {
      slug: 'jaeopjadeuk', hanja: '自業自得', reading: '자업자득', category: '인생', level: 1, day_index: 9,
      meaning: '자기가 저지른 일의 결과를 자기가 받는다는 뜻으로, 자신의 행동에 대한 대가를 스스로 치름.',
      origin: '불교에서 나온 말로, 스스로 지은 업(業)의 과보(果報)를 스스로 받는다는 인과응보 사상에서 비롯되었다. 비슷한 말로 자승자박(自繩自縛), 인과응보(因果應報)가 있다.',
      modern_example: '"미루다 벼락치기로 밤을 새운 건 자업자득이지."',
      comic: [
        panel('주인공이 할 일을 자꾸 미룬다.', '🛋️', '#E6DEDA'),
        panel('"내일 하면 되지~" 하며 논다.', '🎮', '#E0D2CC'),
        panel('마감 전날, 산더미 같은 일이 쌓인다.', '😱📚', '#D6C2BE'),
        panel('밤새 고생한다. "이게 자업자득…"', '😵', '#F4C95D'),
      ],
      quiz: { question: '‘자업자득’의 뜻으로 알맞은 것은?', options: ['남이 한 일로 손해 봄', '자기 행동의 결과를 자기가 받음', '우연히 이득을 봄', '함께 힘을 합침'], answerIndex: 1, explanation: '스스로 한 일의 결과는 결국 자신에게 돌아온다는 뜻이에요.' },
    },
    {
      slug: 'gojingamrae', hanja: '苦盡甘來', reading: '고진감래', category: '노력', level: 1, day_index: 10,
      meaning: '쓴 것이 다하면 단 것이 온다는 뜻으로, 고생 끝에 즐거움이나 좋은 일이 옴.',
      origin: '민간에서 오래 전해 내려온 표현으로, 어려움을 견디면 반드시 좋은 날이 온다는 격려의 말이다. 반대말로는 흥진비래(興盡悲來)가 있다.',
      modern_example: '"몇 년간 힘들었지만 마침내 가게가 자리를 잡았다. 고진감래다."',
      comic: [
        panel('주인공이 힘든 일을 묵묵히 견딘다.', '😖💦', '#DEE6E2'),
        panel('포기하고 싶은 순간들이 이어진다.', '🌧️', '#D0E0D8'),
        panel('그래도 한 걸음씩 나아간다.', '🚶', '#C2D6CC'),
        panel('마침내 찾아온 달콤한 보상! "고진감래!"', '🍯😊', '#F4C95D'),
      ],
      quiz: { question: '‘고진감래’와 가장 어울리는 상황은?', options: ['오래 고생한 끝에 성공함', '갈피를 못 잡고 헤맴', '결심이 사흘 만에 무너짐', '준비 없이 일을 당함'], answerIndex: 0, explanation: '쓴맛(고생)이 다하면 단맛(좋은 일)이 온다는 희망의 말이에요.' },
    },
    {
      slug: 'jaksimsamil', hanja: '作心三日', reading: '작심삼일', category: '처세', level: 1, day_index: 11,
      meaning: '먹은 마음이 사흘을 못 간다는 뜻으로, 결심이 굳지 못해 오래가지 못함.',
      origin: '맹자(孟子)의 "사람의 마음은 잡으면 보존되고 놓으면 사라진다"는 사상과 통하는 말로, 우리나라에서 널리 쓰이는 표현이다. 작심(作心)은 마음을 단단히 먹음을 뜻한다.',
      modern_example: '"새해 운동 결심이 또 작심삼일로 끝났다."',
      comic: [
        panel('1일차: "오늘부터 매일 운동!"', '💪🔥', '#E6E2DA'),
        panel('2일차: 조금 피곤하지만 해낸다.', '😅', '#DCD6CA'),
        panel('3일차: "딱 하루만 쉬자…"', '🛏️', '#D2CABA'),
        panel('운동화는 다시 신발장으로. "작심삼일…"', '👟💤', '#F4C95D'),
      ],
      quiz: { question: '‘작심삼일’의 뜻으로 알맞은 것은?', options: ['결심이 오래가지 못함', '준비가 철저함', '큰 인물은 늦게 이뤄짐', '한 번에 두 이득을 봄'], answerIndex: 0, explanation: '굳게 먹은 마음이 사흘을 넘기지 못한다는, 의지가 약함을 빗댄 말이에요.' },
    },
    {
      slug: 'gungyeilhak', hanja: '群鷄一鶴', reading: '군계일학', category: '지혜', level: 3, day_index: 12,
      meaning: '닭의 무리 가운데 한 마리의 학이라는 뜻으로, 평범한 여럿 가운데 유독 뛰어난 한 사람.',
      origin: '진서(晉書)에 나온다. 혜소가 처음 낙양에 들어섰을 때, 그를 본 사람이 "닭 무리 속의 학처럼 우뚝하더라(群鷄一鶴)"고 한 데서 유래했다. 출중한 인물을 가리키는 말이 되었다.',
      modern_example: '"평범한 지원자들 사이에서 그녀의 실력은 단연 군계일학이었다."',
      comic: [
        panel('마당에 닭들이 옹기종기 모여 있다.', '🐔🐔🐔', '#E2E6DA'),
        panel('그 가운데 우아한 학 한 마리가 선다.', '🦢', '#D6E0CC'),
        panel('학은 머리 하나만큼 우뚝 솟아 있다.', '✨', '#CAD6BE'),
        panel('"무리 중 단연 돋보여. 군계일학!"', '👏', '#F4C95D'),
      ],
      quiz: { question: '‘군계일학’이 가리키는 대상은?', options: ['여럿 중 가장 뛰어난 사람', '갈피를 못 잡는 사람', '준비를 잘한 사람', '늦게 성공한 사람'], answerIndex: 0, explanation: '닭 무리 속의 학처럼, 평범한 여럿 가운데 단연 뛰어난 한 사람을 뜻해요.' },
    },
  ];

  for (const it of idioms) {
    // 패널에 imageKey(실제 PNG 슬롯) 부여: <slug>_<번호>.
    const comic = (it.comic as any[]).map((p, i) => ({ ...p, imageKey: `${it.slug}_${i + 1}` }));
    await client.query(
      `INSERT INTO sj_idioms (slug, hanja, reading, meaning, origin, modern_example, category, level, day_index, comic, chars, quiz, is_active)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, TRUE)
       ON CONFLICT (slug) DO NOTHING`,
      [
        it.slug, it.hanja, it.reading, it.meaning, it.origin, it.modern_example,
        it.category, it.level, it.day_index, JSON.stringify(comic),
        JSON.stringify(SAJA_CHARS[it.slug] ?? []), JSON.stringify(it.quiz),
      ]
    );
  }

  // 최초 시드 완료 표시 → 이후 부팅에선 시드를 다시 돌리지 않는다.
  await client.query(
    `INSERT INTO sj_meta (key, value) VALUES ('seeded', '1') ON CONFLICT (key) DO NOTHING`
  );
  console.log('✅ SajaToon idioms seeded (최초 1회)');
}

// [SAJA] 한자 한 글자씩 풀이 [{ c, hun(뜻), eum(음) }]. slug 별.
const SAJA_CHARS: Record<string, Array<{ c: string; hun: string; eum: string }>> = {
  oilmujung: [{ c: '五', hun: '다섯', eum: '오' }, { c: '里', hun: '마을', eum: '리' }, { c: '霧', hun: '안개', eum: '무' }, { c: '中', hun: '가운데', eum: '중' }],
  ilseokijo: [{ c: '一', hun: '한', eum: '일' }, { c: '石', hun: '돌', eum: '석' }, { c: '二', hun: '두', eum: '이' }, { c: '鳥', hun: '새', eum: '조' }],
  saeongjima: [{ c: '塞', hun: '변방', eum: '새' }, { c: '翁', hun: '늙은이', eum: '옹' }, { c: '之', hun: '어조사', eum: '지' }, { c: '馬', hun: '말', eum: '마' }],
  ugongisan: [{ c: '愚', hun: '어리석을', eum: '우' }, { c: '公', hun: '공평할', eum: '공' }, { c: '移', hun: '옮길', eum: '이' }, { c: '山', hun: '메', eum: '산' }],
  hwaryongjeongjeong: [{ c: '畵', hun: '그림', eum: '화' }, { c: '龍', hun: '용', eum: '룡' }, { c: '點', hun: '점찍을', eum: '점' }, { c: '睛', hun: '눈동자', eum: '정' }],
  daegimanseong: [{ c: '大', hun: '큰', eum: '대' }, { c: '器', hun: '그릇', eum: '기' }, { c: '晩', hun: '늦을', eum: '만' }, { c: '成', hun: '이룰', eum: '성' }],
  gwayubulgeup: [{ c: '過', hun: '지날', eum: '과' }, { c: '猶', hun: '오히려', eum: '유' }, { c: '不', hun: '아닐', eum: '불' }, { c: '及', hun: '미칠', eum: '급' }],
  yubimuhwan: [{ c: '有', hun: '있을', eum: '유' }, { c: '備', hun: '갖출', eum: '비' }, { c: '無', hun: '없을', eum: '무' }, { c: '患', hun: '근심', eum: '환' }],
  jaeopjadeuk: [{ c: '自', hun: '스스로', eum: '자' }, { c: '業', hun: '업', eum: '업' }, { c: '自', hun: '스스로', eum: '자' }, { c: '得', hun: '얻을', eum: '득' }],
  gojingamrae: [{ c: '苦', hun: '쓸', eum: '고' }, { c: '盡', hun: '다할', eum: '진' }, { c: '甘', hun: '달', eum: '감' }, { c: '來', hun: '올', eum: '래' }],
  jaksimsamil: [{ c: '作', hun: '지을', eum: '작' }, { c: '心', hun: '마음', eum: '심' }, { c: '三', hun: '석', eum: '삼' }, { c: '日', hun: '날', eum: '일' }],
  gungyeilhak: [{ c: '群', hun: '무리', eum: '군' }, { c: '鷄', hun: '닭', eum: '계' }, { c: '一', hun: '한', eum: '일' }, { c: '鶴', hun: '학', eum: '학' }],
};

// [SAJA] 기존 사자성어(이미 시드됨)에 한자 풀이를 채운다. chars 가 비어 있을 때만 — 삭제/수정 보존.
async function backfillSajatoonChars(client: any) {
  for (const [slug, chars] of Object.entries(SAJA_CHARS)) {
    await client.query(
      `UPDATE sj_idioms SET chars = $2
       WHERE slug = $1 AND (chars IS NULL OR chars = '[]'::jsonb)`,
      [slug, JSON.stringify(chars)]
    );
  }
}

// [SAJA] quizzes 가 빈 사자성어에 퀴즈 리스트를 채운다.
//   ① 기존 단일 quiz(뜻/상황) → 리스트 첫 항목  ② chars 로 '한자 의미' 퀴즈 자동 생성.
//   정답 위치는 앱에서 매번 섞으므로 여기선 정답을 0번에 둔다.
async function backfillSajatoonQuizzes(client: any) {
  const hunPool = Array.from(new Set(Object.values(SAJA_CHARS).flat().map((c) => c.hun)));
  const rows = await client.query(
    `SELECT id, hanja, reading, quiz, chars FROM sj_idioms WHERE quizzes = '[]'::jsonb`
  );
  for (const row of rows.rows) {
    const quizzes: any[] = [];
    if (row.quiz) quizzes.push({ type: 'meaning', ...row.quiz });

    const chars = Array.isArray(row.chars) ? row.chars : [];
    if (chars.length > 0) {
      // 변별력 위해 '훈이 가장 긴' 글자 선택.
      const target = chars.slice().sort((a: any, b: any) => (b.hun || '').length - (a.hun || '').length)[0];
      if (target && target.hun) {
        const distractors = hunPool.filter((h) => h !== target.hun);
        for (let i = distractors.length - 1; i > 0; i--) {
          const j = Math.floor(Math.random() * (i + 1));
          [distractors[i], distractors[j]] = [distractors[j], distractors[i]];
        }
        quizzes.push({
          type: 'hanja',
          question: `‘${row.reading}(${row.hanja})’에서 한자 ‘${target.c}’의 뜻은?`,
          options: [target.hun, ...distractors.slice(0, 3)],
          answerIndex: 0,
          explanation: `‘${target.c}’은(는) '${target.hun} ${target.eum}'.`,
        });
      }
    }

    if (quizzes.length > 0) {
      await client.query(`UPDATE sj_idioms SET quizzes = $2 WHERE id = $1`, [row.id, JSON.stringify(quizzes)]);
    }
  }
}

export function getPool() {
  return pool;
}
