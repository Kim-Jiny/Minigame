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
    'SELECT * FROM dm_users WHERE provider = $1 AND provider_id = $2',
    [provider, providerId]
  );

  if (existingUser.rows.length > 0) {
    // 기존 사용자가 있으면 정보 업데이트
    const updated = await pool.query(
      `UPDATE dm_users
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
    `INSERT INTO dm_users (provider, provider_id, email, nickname, avatar_url)
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

  const result = await pool.query('SELECT * FROM dm_users WHERE id = $1', [id]);

  return result.rows[0] || null;
}

export async function updateNickname(userId: number, nickname: string): Promise<User> {
  const pool = getPool();

  if (!pool) {
    throw new Error('Database not connected');
  }

  const result = await pool.query(
    `UPDATE dm_users
     SET nickname = $1, updated_at = CURRENT_TIMESTAMP
     WHERE id = $2
     RETURNING *`,
    [nickname, userId]
  );

  if (result.rows.length === 0) {
    throw new Error('User not found');
  }

  return result.rows[0];
}

export async function deleteUser(userId: number): Promise<void> {
  const pool = getPool();

  if (!pool) {
    throw new Error('Database not connected');
  }

  // 관련 데이터 삭제 (CASCADE가 설정되어 있지 않은 경우를 대비)
  await pool.query('DELETE FROM dm_user_sessions WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_user_stats WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_game_records WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_user_items WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_friendships WHERE user_id = $1 OR friend_id = $1', [userId]);

  // 사용자 삭제
  const result = await pool.query('DELETE FROM dm_users WHERE id = $1', [userId]);

  if (result.rowCount === 0) {
    throw new Error('User not found');
  }
}
