"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setupDatabase = setupDatabase;
exports.getPool = getPool;
const pg_1 = require("pg");
let pool;
async function setupDatabase() {
    const databaseUrl = process.env.DATABASE_URL;
    if (!databaseUrl) {
        console.log('⚠️  DATABASE_URL not set, running without database');
        return;
    }
    pool = new pg_1.Pool({
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
    `);
        console.log('✅ Database tables ready');
        client.release();
    }
    catch (error) {
        console.error('❌ Database connection failed:', error);
        throw error;
    }
}
function getPool() {
    return pool;
}
