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
