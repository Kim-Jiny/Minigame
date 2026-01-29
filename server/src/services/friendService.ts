import { getPool } from '../config/database';

// 8자리 친구 코드 생성 (대문자 + 숫자, 0/O/1/I 제외)
function generateRandomCode(): string {
  const characters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 8; i++) {
    code += characters.charAt(Math.floor(Math.random() * characters.length));
  }
  return code;
}

export interface Friend {
  id: number;
  nickname: string;
  email?: string;
  avatarUrl?: string;
  friendCode: string;
  memo?: string;
}

export const friendService = {
  // 친구 코드 생성 (없으면 새로 생성)
  async generateFriendCode(userId: number): Promise<string> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 이미 코드가 있는지 확인
    const existing = await pool.query(
      'SELECT code FROM friend_codes WHERE user_id = $1',
      [userId]
    );

    if (existing.rows.length > 0) {
      return existing.rows[0].code;
    }

    // 새 코드 생성 (중복 방지)
    let code: string;
    let isUnique = false;

    while (!isUnique) {
      code = generateRandomCode();
      const check = await pool.query(
        'SELECT id FROM friend_codes WHERE code = $1',
        [code]
      );
      if (check.rows.length === 0) {
        isUnique = true;
      }
    }

    await pool.query(
      'INSERT INTO friend_codes (user_id, code) VALUES ($1, $2)',
      [userId, code!]
    );

    return code!;
  },

  // 친구 코드 조회
  async getFriendCode(userId: number): Promise<string | null> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      'SELECT code FROM friend_codes WHERE user_id = $1',
      [userId]
    );

    return result.rows.length > 0 ? result.rows[0].code : null;
  },

  // 친구 코드로 사용자 찾기
  async findUserByFriendCode(code: string): Promise<{id: number; nickname: string} | null> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT u.id, u.nickname
       FROM users u
       JOIN friend_codes fc ON u.id = fc.user_id
       WHERE fc.code = $1`,
      [code.toUpperCase()]
    );

    return result.rows.length > 0 ? result.rows[0] : null;
  },

  // 친구 추가
  async addFriend(userId: number, friendCode: string): Promise<{success: boolean; message: string; friend?: Friend}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 친구 코드로 사용자 찾기
    const friendUser = await this.findUserByFriendCode(friendCode);
    if (!friendUser) {
      return { success: false, message: '존재하지 않는 친구 코드입니다.' };
    }

    // 자기 자신 추가 방지
    if (friendUser.id === userId) {
      return { success: false, message: '자신을 친구로 추가할 수 없습니다.' };
    }

    // 이미 친구인지 확인
    const existing = await pool.query(
      'SELECT id FROM friendships WHERE user_id = $1 AND friend_id = $2',
      [userId, friendUser.id]
    );

    if (existing.rows.length > 0) {
      return { success: false, message: '이미 친구로 등록된 사용자입니다.' };
    }

    // 양방향 친구 관계 추가
    await pool.query(
      'INSERT INTO friendships (user_id, friend_id) VALUES ($1, $2), ($2, $1)',
      [userId, friendUser.id]
    );

    // 친구 정보 조회
    const friendInfo = await pool.query(
      `SELECT u.id, u.nickname, u.email, u.avatar_url as "avatarUrl", fc.code as "friendCode"
       FROM users u
       JOIN friend_codes fc ON u.id = fc.user_id
       WHERE u.id = $1`,
      [friendUser.id]
    );

    return {
      success: true,
      message: '친구가 추가되었습니다.',
      friend: friendInfo.rows[0]
    };
  },

  // 친구 목록 조회
  async getFriends(userId: number): Promise<Friend[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT u.id, u.nickname, u.email, u.avatar_url as "avatarUrl", fc.code as "friendCode", f.memo
       FROM users u
       JOIN friendships f ON u.id = f.friend_id
       LEFT JOIN friend_codes fc ON u.id = fc.user_id
       WHERE f.user_id = $1
       ORDER BY u.nickname`,
      [userId]
    );

    return result.rows;
  },

  // 친구 메모 수정
  async updateFriendMemo(userId: number, friendId: number, memo: string | null): Promise<{success: boolean; message: string}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      'UPDATE friendships SET memo = $1 WHERE user_id = $2 AND friend_id = $3',
      [memo, userId, friendId]
    );

    if (result.rowCount === 0) {
      return { success: false, message: '친구 관계를 찾을 수 없습니다.' };
    }

    return { success: true, message: '메모가 저장되었습니다.' };
  },

  // 친구 삭제
  async removeFriend(userId: number, friendId: number): Promise<{success: boolean; message: string}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 양방향 삭제
    const result = await pool.query(
      'DELETE FROM friendships WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)',
      [userId, friendId]
    );

    if (result.rowCount === 0) {
      return { success: false, message: '친구 관계를 찾을 수 없습니다.' };
    }

    return { success: true, message: '친구가 삭제되었습니다.' };
  }
};
