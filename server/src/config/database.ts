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
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(user_id, friend_id)
      );

      -- 게임 초대 테이블
      CREATE TABLE IF NOT EXISTS game_invitations (
        id SERIAL PRIMARY KEY,
        inviter_id INTEGER REFERENCES users(id),
        invitee_id INTEGER REFERENCES users(id),
        game_type VARCHAR(50) NOT NULL,
        status VARCHAR(20) DEFAULT 'pending',
        room_id VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    `);

    console.log('✅ Database tables ready');
    client.release();
  } catch (error) {
    console.error('❌ Database connection failed:', error);
    throw error;
  }
}

export function getPool() {
  return pool;
}
