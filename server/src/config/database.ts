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
      CREATE TABLE IF NOT EXISTS users (
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

      CREATE TABLE IF NOT EXISTS game_records (
        id SERIAL PRIMARY KEY,
        game_type VARCHAR(50) NOT NULL,
        player1_id INTEGER REFERENCES users(id),
        player2_id INTEGER REFERENCES users(id),
        winner_id INTEGER REFERENCES users(id),
        game_data JSONB,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 친구 코드 테이블
      CREATE TABLE IF NOT EXISTS friend_codes (
        id SERIAL PRIMARY KEY,
        user_id INTEGER UNIQUE REFERENCES users(id),
        code VARCHAR(8) UNIQUE NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 기존 테이블 컬럼 크기 변경 (6자리 -> 8자리)
      ALTER TABLE friend_codes ALTER COLUMN code TYPE VARCHAR(8);

      -- 친구 관계 테이블
      CREATE TABLE IF NOT EXISTS friendships (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        friend_id INTEGER REFERENCES users(id),
        memo VARCHAR(20),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, friend_id)
      );

      -- memo 컬럼 추가 (기존 테이블용)
      ALTER TABLE friendships ADD COLUMN IF NOT EXISTS memo VARCHAR(20);

      -- 친구 요청 테이블
      CREATE TABLE IF NOT EXISTS friend_requests (
        id SERIAL PRIMARY KEY,
        from_user_id INTEGER REFERENCES users(id),
        to_user_id INTEGER REFERENCES users(id),
        status VARCHAR(20) DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(from_user_id, to_user_id)
      );

      -- 게임 초대 테이블
      CREATE TABLE IF NOT EXISTS game_invitations (
        id SERIAL PRIMARY KEY,
        inviter_id INTEGER REFERENCES users(id),
        invitee_id INTEGER REFERENCES users(id),
        game_type VARCHAR(50) NOT NULL,
        is_hardcore BOOLEAN DEFAULT FALSE,
        status VARCHAR(20) DEFAULT 'pending',
        room_id VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- is_hardcore 컬럼 추가 (기존 테이블용)
      ALTER TABLE game_invitations ADD COLUMN IF NOT EXISTS is_hardcore BOOLEAN DEFAULT FALSE;

      -- 게임별 통계 테이블
      CREATE TABLE IF NOT EXISTS user_game_stats (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
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
      CREATE TABLE IF NOT EXISTS user_mileage (
        id SERIAL PRIMARY KEY,
        user_id INTEGER UNIQUE REFERENCES users(id),
        mileage INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 마일리지 기록 테이블
      CREATE TABLE IF NOT EXISTS mileage_history (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        amount INTEGER NOT NULL,
        reason VARCHAR(50) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 친구 메시지 테이블
      CREATE TABLE IF NOT EXISTS friend_messages (
        id SERIAL PRIMARY KEY,
        sender_id INTEGER REFERENCES users(id),
        receiver_id INTEGER REFERENCES users(id),
        content TEXT NOT NULL,
        is_read BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 7일 지난 메시지 자동 삭제용 인덱스
      CREATE INDEX IF NOT EXISTS idx_friend_messages_created_at ON friend_messages(created_at);

      -- 연승 추적 테이블
      CREATE TABLE IF NOT EXISTS user_streak (
        user_id INTEGER PRIMARY KEY REFERENCES users(id),
        current_streak INTEGER DEFAULT 0,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 일일 상대별 게임 횟수 (어뷰징 방지)
      CREATE TABLE IF NOT EXISTS daily_match_count (
        user_id INTEGER REFERENCES users(id),
        opponent_id INTEGER REFERENCES users(id),
        match_date DATE NOT NULL,
        count INTEGER DEFAULT 0,
        PRIMARY KEY (user_id, opponent_id, match_date)
      );

      -- 오래된 daily_match_count 자동 정리용 인덱스
      CREATE INDEX IF NOT EXISTS idx_daily_match_count_date ON daily_match_count(match_date);

      -- 상점 아이템 카탈로그
      CREATE TABLE IF NOT EXISTS shop_items (
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
      CREATE TABLE IF NOT EXISTS user_items (
        id SERIAL PRIMARY KEY,
        user_id INTEGER REFERENCES users(id),
        item_id INTEGER REFERENCES shop_items(id),
        purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        expires_at TIMESTAMP DEFAULT NULL,
        UNIQUE(user_id, item_id)
      );

      -- 유저 프로필 설정
      CREATE TABLE IF NOT EXISTS user_profile_settings (
        user_id INTEGER PRIMARY KEY REFERENCES users(id),
        active_frame_id INTEGER REFERENCES shop_items(id),
        active_title_id INTEGER REFERENCES shop_items(id),
        active_theme_id INTEGER REFERENCES shop_items(id),
        active_avatar_id INTEGER REFERENCES shop_items(id),
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      -- 아바타 컬럼 추가 (기존 테이블용)
      DO $$ BEGIN
        ALTER TABLE user_profile_settings ADD COLUMN active_avatar_id INTEGER REFERENCES shop_items(id);
      EXCEPTION WHEN duplicate_column THEN NULL;
      END $$;

      -- 인덱스 추가
      CREATE INDEX IF NOT EXISTS idx_user_items_user_id ON user_items(user_id);
      CREATE INDEX IF NOT EXISTS idx_user_items_expires_at ON user_items(expires_at);
      CREATE INDEX IF NOT EXISTS idx_shop_items_category ON shop_items(category);
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
  // 이미 데이터가 있으면 스킵
  const existing = await client.query('SELECT COUNT(*) FROM shop_items');
  if (parseInt(existing.rows[0].count) > 0) {
    console.log('✅ Shop items already seeded');
    return;
  }

  const items = [
    // === 프레임 ===
    // 기본 (무료)
    { category: 'frame', item_key: 'frame_default', name: '기본 프레임', description: '심플한 기본 프레임', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { borderColor: '#9E9E9E', glowColor: null, animation: null } },
    // Common
    { category: 'frame', item_key: 'frame_silver', name: '실버 프레임', description: '깔끔한 실버 테두리', price: 50, rarity: 'common', sort_order: 1, preview_data: { borderColor: '#C0C0C0', glowColor: '#E8E8E8', animation: null } },
    // Rare
    { category: 'frame', item_key: 'frame_gold', name: '골드 프레임', description: '빛나는 골드 테두리', price: 150, rarity: 'rare', sort_order: 2, preview_data: { borderColor: '#FFD700', glowColor: '#FFF8DC', animation: 'shimmer' } },
    { category: 'frame', item_key: 'frame_ocean', name: '오션 프레임', description: '시원한 바다 느낌', price: 150, rarity: 'rare', sort_order: 3, preview_data: { borderColor: '#00CED1', glowColor: '#E0FFFF', animation: 'wave' } },
    // Epic
    { category: 'frame', item_key: 'frame_diamond', name: '다이아 프레임', description: '고급스러운 다이아몬드', price: 300, rarity: 'epic', sort_order: 4, preview_data: { borderColor: '#B9F2FF', glowColor: '#E0FFFF', animation: 'sparkle' } },
    { category: 'frame', item_key: 'frame_aurora', name: '오로라 프레임', description: '신비로운 오로라 빛', price: 350, rarity: 'epic', sort_order: 5, preview_data: { borderColor: '#7B68EE', glowColor: '#E6E6FA', animation: 'aurora' } },
    // Legendary
    { category: 'frame', item_key: 'frame_flame', name: '불꽃 프레임', description: '타오르는 불꽃 효과', price: 500, rarity: 'legendary', sort_order: 6, preview_data: { borderColor: '#FF4500', glowColor: '#FF6347', animation: 'flame' } },
    { category: 'frame', item_key: 'frame_rainbow', name: '레인보우 프레임', description: '무지개빛 그라데이션', price: 500, rarity: 'legendary', sort_order: 7, preview_data: { borderColor: 'rainbow', glowColor: '#FFFFFF', animation: 'rainbow' } },
    // 기간제
    { category: 'frame', item_key: 'frame_rainbow_7d', name: '레인보우 프레임 (7일)', description: '7일 한정 레인보우 프레임', price: 50, rarity: 'rare', duration_days: 7, sort_order: 8, preview_data: { borderColor: 'rainbow', glowColor: '#FFFFFF', animation: 'rainbow' } },

    // === 칭호 ===
    // 기본 (무료)
    { category: 'title', item_key: 'title_default', name: '초보 게이머', description: '모든 모험은 여기서 시작!', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { textColor: '#9E9E9E', icon: null, gradient: null } },
    // Common
    { category: 'title', item_key: 'title_winner', name: '승리의 주인공', description: '승리를 향해!', price: 100, rarity: 'common', sort_order: 1, preview_data: { textColor: '#4CAF50', icon: '🏆', gradient: null } },
    { category: 'title', item_key: 'title_lucky', name: '행운아', description: '오늘도 운이 좋군!', price: 100, rarity: 'common', sort_order: 2, preview_data: { textColor: '#FFC107', icon: '🍀', gradient: null } },
    // Rare
    { category: 'title', item_key: 'title_veteran', name: '베테랑', description: '수많은 전투를 경험한 자', price: 200, rarity: 'rare', sort_order: 3, preview_data: { textColor: '#2196F3', icon: '⭐', gradient: null } },
    { category: 'title', item_key: 'title_strategist', name: '전략가', description: '치밀한 전략으로 승리한다', price: 200, rarity: 'rare', sort_order: 4, preview_data: { textColor: '#9C27B0', icon: '🧠', gradient: null } },
    // Epic
    { category: 'title', item_key: 'title_champion', name: '챔피언', description: '최고의 자리에 오른 자', price: 400, rarity: 'epic', sort_order: 5, preview_data: { textColor: '#FF5722', icon: '👑', gradient: ['#FF5722', '#FFC107'] } },
    { category: 'title', item_key: 'title_master', name: '마스터', description: '게임의 달인', price: 450, rarity: 'epic', sort_order: 6, preview_data: { textColor: '#E91E63', icon: '💎', gradient: ['#E91E63', '#9C27B0'] } },
    // Legendary
    { category: 'title', item_key: 'title_legend', name: '전설', description: '전설로 기억될 자', price: 800, rarity: 'legendary', sort_order: 7, preview_data: { textColor: '#FFD700', icon: '🌟', gradient: ['#FFD700', '#FF8C00', '#FF4500'] } },

    // === 테마 ===
    // 기본 (무료)
    { category: 'theme', item_key: 'theme_default', name: '기본 테마', description: '깔끔한 기본 배경', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { gradientColors: ['#6C5CE7', '#A29BFE'], particleType: null } },
    // Rare
    { category: 'theme', item_key: 'theme_ocean', name: '오션 테마', description: '시원한 바다 배경', price: 200, rarity: 'rare', sort_order: 1, preview_data: { gradientColors: ['#0077B6', '#00B4D8', '#90E0EF'], particleType: 'bubbles' } },
    { category: 'theme', item_key: 'theme_sunset', name: '선셋 테마', description: '아름다운 노을 배경', price: 200, rarity: 'rare', sort_order: 2, preview_data: { gradientColors: ['#FF6B6B', '#FFA07A', '#FFD93D'], particleType: null } },
    { category: 'theme', item_key: 'theme_forest', name: '포레스트 테마', description: '평화로운 숲 배경', price: 200, rarity: 'rare', sort_order: 3, preview_data: { gradientColors: ['#2D5A27', '#5DAB4D', '#98D989'], particleType: 'leaves' } },
    // Epic
    { category: 'theme', item_key: 'theme_galaxy', name: '갤럭시 테마', description: '은하수 별빛 배경', price: 400, rarity: 'epic', sort_order: 4, preview_data: { gradientColors: ['#0F0C29', '#302B63', '#24243E'], particleType: 'stars' } },
    { category: 'theme', item_key: 'theme_aurora', name: '오로라 테마', description: '신비로운 오로라 배경', price: 400, rarity: 'epic', sort_order: 5, preview_data: { gradientColors: ['#0F2027', '#203A43', '#2C5364'], particleType: 'aurora' } },
    // Legendary
    { category: 'theme', item_key: 'theme_neon', name: '네온 테마', description: '화려한 네온 배경', price: 600, rarity: 'legendary', sort_order: 6, preview_data: { gradientColors: ['#FF00FF', '#00FFFF', '#FF00FF'], particleType: 'neon' } },
    { category: 'theme', item_key: 'theme_inferno', name: '인페르노 테마', description: '타오르는 불꽃 배경', price: 600, rarity: 'legendary', sort_order: 7, preview_data: { gradientColors: ['#1A0000', '#8B0000', '#FF4500'], particleType: 'fire' } },

    // === 티켓 ===
    { category: 'ticket', item_key: 'ticket_delete_loss', name: '1패 삭제권', description: '선택한 게임에서 패배 1회 삭제', price: 50, rarity: 'common', sort_order: 0, preview_data: { icon: '🎫', effect: 'delete_loss' } },
    { category: 'ticket', item_key: 'ticket_change_nickname', name: '닉네임 변경권', description: '닉네임을 변경합니다', price: 100, rarity: 'rare', sort_order: 1, preview_data: { icon: '✏️', effect: 'change_nickname' } },

    // === 아바타 ===
    // 기본 (무료)
    { category: 'avatar', item_key: 'avatar_default', name: '기본', description: '기본 아바타', price: 0, rarity: 'common', is_default: true, sort_order: 0, preview_data: { emoji: '👤', bgColor: '#E0E0E0' } },
    // Common
    { category: 'avatar', item_key: 'avatar_smile', name: '스마일', description: '밝은 미소', price: 30, rarity: 'common', sort_order: 1, preview_data: { emoji: '😊', bgColor: '#FFF9C4' } },
    { category: 'avatar', item_key: 'avatar_cool', name: '쿨가이', description: '멋진 선글라스', price: 30, rarity: 'common', sort_order: 2, preview_data: { emoji: '😎', bgColor: '#BBDEFB' } },
    { category: 'avatar', item_key: 'avatar_cat', name: '고양이', description: '귀여운 고양이', price: 50, rarity: 'common', sort_order: 3, preview_data: { emoji: '🐱', bgColor: '#FFE0B2' } },
    { category: 'avatar', item_key: 'avatar_dog', name: '강아지', description: '충직한 강아지', price: 50, rarity: 'common', sort_order: 4, preview_data: { emoji: '🐶', bgColor: '#D7CCC8' } },
    // Rare
    { category: 'avatar', item_key: 'avatar_fox', name: '여우', description: '영리한 여우', price: 100, rarity: 'rare', sort_order: 5, preview_data: { emoji: '🦊', bgColor: '#FFCCBC' } },
    { category: 'avatar', item_key: 'avatar_lion', name: '사자', description: '용맹한 사자', price: 100, rarity: 'rare', sort_order: 6, preview_data: { emoji: '🦁', bgColor: '#FFE082' } },
    { category: 'avatar', item_key: 'avatar_panda', name: '판다', description: '귀여운 판다', price: 100, rarity: 'rare', sort_order: 7, preview_data: { emoji: '🐼', bgColor: '#F5F5F5' } },
    { category: 'avatar', item_key: 'avatar_rabbit', name: '토끼', description: '깜찍한 토끼', price: 100, rarity: 'rare', sort_order: 8, preview_data: { emoji: '🐰', bgColor: '#FCE4EC' } },
    // Epic
    { category: 'avatar', item_key: 'avatar_dragon', name: '드래곤', description: '강력한 드래곤', price: 250, rarity: 'epic', sort_order: 9, preview_data: { emoji: '🐉', bgColor: '#C8E6C9' } },
    { category: 'avatar', item_key: 'avatar_unicorn', name: '유니콘', description: '신비로운 유니콘', price: 250, rarity: 'epic', sort_order: 10, preview_data: { emoji: '🦄', bgColor: '#F3E5F5' } },
    { category: 'avatar', item_key: 'avatar_phoenix', name: '피닉스', description: '불사조', price: 300, rarity: 'epic', sort_order: 11, preview_data: { emoji: '🔥', bgColor: '#FFCDD2' } },
    // Legendary
    { category: 'avatar', item_key: 'avatar_alien', name: '외계인', description: '미지의 존재', price: 500, rarity: 'legendary', sort_order: 12, preview_data: { emoji: '👽', bgColor: '#B2DFDB' } },
    { category: 'avatar', item_key: 'avatar_robot', name: '로봇', description: '하이테크 로봇', price: 500, rarity: 'legendary', sort_order: 13, preview_data: { emoji: '🤖', bgColor: '#CFD8DC' } },
    { category: 'avatar', item_key: 'avatar_ghost', name: '유령', description: '신비로운 유령', price: 500, rarity: 'legendary', sort_order: 14, preview_data: { emoji: '👻', bgColor: '#E1BEE7' } },
  ];

  for (const item of items) {
    await client.query(
      `INSERT INTO shop_items (category, item_key, name, description, price, duration_days, rarity, preview_data, sort_order, is_active, is_default)
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
