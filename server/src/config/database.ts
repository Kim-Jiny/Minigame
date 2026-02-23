import { Pool } from 'pg';

let pool: Pool;

export async function setupDatabase() {
  const databaseUrl = process.env.DATABASE_URL;

  if (!databaseUrl) {
    console.log('⚠️  DATABASE_URL not set, running without database');
    return;
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

      -- 초기 관리자 계정 (jiny/1204)
      INSERT INTO dm_admin_accounts (username, password)
      VALUES ('jiny', '1204')
      ON CONFLICT (username) DO NOTHING;

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
    `);

    console.log('✅ Database tables ready');

    // 초기 상점 아이템 seed
    await seedShopItems(client);

    client.release();
  } catch (error) {
    console.error('❌ Database connection failed:', error);
    throw error;
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

export function getPool() {
  return pool;
}
