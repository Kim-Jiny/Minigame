import { getPool } from '../config/database';

export interface User {
  id: number;
  provider: string;
  provider_id: string;
  email: string | null;
  nickname: string;
  avatar_url: string | null;
  created_at: Date;
  updated_at: Date;
}

export async function findOrCreateUser(
  provider: string,
  providerId: string,
  email: string | null,
  nickname: string,
  avatarUrl: string | null
): Promise<User> {
  const pool = getPool();

  if (!pool) {
    throw new Error('Database not connected');
  }

  // 기존 사용자 조회
  const existingUser = await pool.query(
    'SELECT * FROM users WHERE provider = $1 AND provider_id = $2',
    [provider, providerId]
  );

  if (existingUser.rows.length > 0) {
    // 기존 사용자가 있으면 정보 업데이트
    const updated = await pool.query(
      `UPDATE users
       SET email = COALESCE($1, email),
           nickname = COALESCE($2, nickname),
           avatar_url = COALESCE($3, avatar_url),
           updated_at = CURRENT_TIMESTAMP
       WHERE provider = $4 AND provider_id = $5
       RETURNING *`,
      [email, nickname, avatarUrl, provider, providerId]
    );
    return updated.rows[0];
  }

  // 새 사용자 생성
  const newUser = await pool.query(
    `INSERT INTO users (provider, provider_id, email, nickname, avatar_url)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING *`,
    [provider, providerId, email, nickname, avatarUrl]
  );

  return newUser.rows[0];
}

export async function findUserById(id: number): Promise<User | null> {
  const pool = getPool();

  if (!pool) {
    throw new Error('Database not connected');
  }

  const result = await pool.query('SELECT * FROM users WHERE id = $1', [id]);

  return result.rows[0] || null;
}
