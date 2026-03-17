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
    // 기존 사용자가 있으면 이메일/아바타만 업데이트 (닉네임은 유저가 직접 설정하므로 덮어쓰지 않음)
    const updated = await pool.query(
      `UPDATE dm_users
       SET email = COALESCE($1, email),
           avatar_url = COALESCE($2, avatar_url),
           updated_at = CURRENT_TIMESTAMP
       WHERE provider = $3 AND provider_id = $4
       RETURNING *`,
      [email, avatarUrl, provider, providerId]
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

  // 랜덤 5자리 생성
  const randomStr = Math.random().toString(36).substring(2, 7);

  // provider_id를 withdraw_랜덤5자리_기존provider_id로 변경하여 소프트 삭제
  const result = await pool.query(
    `UPDATE dm_users
     SET provider_id = 'withdraw_' || $2 || '_' || provider_id,
         nickname = '탈퇴한 유저',
         email = NULL,
         avatar_url = NULL,
         updated_at = CURRENT_TIMESTAMP
     WHERE id = $1`,
    [userId, randomStr]
  );

  if (result.rowCount === 0) {
    throw new Error('User not found');
  }

  // 세션/친구/아이템 등 부가 데이터는 삭제
  await pool.query('DELETE FROM dm_user_sessions WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_user_items WHERE user_id = $1', [userId]);
  await pool.query('DELETE FROM dm_friendships WHERE user_id = $1 OR friend_id = $1', [userId]);
}
