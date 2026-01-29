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
