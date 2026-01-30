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

export interface FriendRequest {
  id: number;
  fromUserId: number;
  fromNickname: string;
  toUserId: number;
  toNickname: string;
  createdAt: Date;
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

  // 친구 요청 보내기 (친구 코드로)
  async sendFriendRequest(userId: number, friendCode: string): Promise<{success: boolean; message: string; toUserId?: number}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 친구 코드로 사용자 찾기
    const friendUser = await this.findUserByFriendCode(friendCode);
    if (!friendUser) {
      return { success: false, message: '존재하지 않는 친구 코드입니다.' };
    }

    return this.sendFriendRequestByUserId(userId, friendUser.id);
  },

  // 친구 요청 보내기 (유저 ID로)
  async sendFriendRequestByUserId(userId: number, toUserId: number): Promise<{success: boolean; message: string; toUserId?: number}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 자기 자신 추가 방지
    if (toUserId === userId) {
      return { success: false, message: '자신에게 친구 요청을 보낼 수 없습니다.' };
    }

    // 상대방이 존재하는지 확인
    const userExists = await pool.query(
      'SELECT id, nickname FROM users WHERE id = $1',
      [toUserId]
    );

    if (userExists.rows.length === 0) {
      return { success: false, message: '존재하지 않는 사용자입니다.' };
    }

    // 이미 친구인지 확인
    const existingFriend = await pool.query(
      'SELECT id FROM friendships WHERE user_id = $1 AND friend_id = $2',
      [userId, toUserId]
    );

    if (existingFriend.rows.length > 0) {
      return { success: false, message: '이미 친구로 등록된 사용자입니다.' };
    }

    // 이미 요청을 보냈는지 확인
    const existingRequest = await pool.query(
      `SELECT id FROM friend_requests
       WHERE from_user_id = $1 AND to_user_id = $2 AND status = 'pending'`,
      [userId, toUserId]
    );

    if (existingRequest.rows.length > 0) {
      return { success: false, message: '이미 친구 요청을 보냈습니다.' };
    }

    // 상대방이 나에게 요청을 보냈는지 확인 (자동 수락)
    const reverseRequest = await pool.query(
      `SELECT id FROM friend_requests
       WHERE from_user_id = $1 AND to_user_id = $2 AND status = 'pending'`,
      [toUserId, userId]
    );

    if (reverseRequest.rows.length > 0) {
      // 상대방도 요청한 상태면 바로 친구 추가
      await this.acceptFriendRequest(userId, reverseRequest.rows[0].id);
      return { success: true, message: '서로 친구 요청을 보내서 친구가 되었습니다!', toUserId };
    }

    // 친구 요청 생성
    await pool.query(
      `INSERT INTO friend_requests (from_user_id, to_user_id, status)
       VALUES ($1, $2, 'pending')
       ON CONFLICT (from_user_id, to_user_id)
       DO UPDATE SET status = 'pending', created_at = CURRENT_TIMESTAMP`,
      [userId, toUserId]
    );

    return { success: true, message: '친구 요청을 보냈습니다.', toUserId };
  },

  // 받은 친구 요청 목록 조회
  async getReceivedFriendRequests(userId: number): Promise<FriendRequest[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT fr.id, fr.from_user_id as "fromUserId", u1.nickname as "fromNickname",
              fr.to_user_id as "toUserId", u2.nickname as "toNickname", fr.created_at as "createdAt"
       FROM friend_requests fr
       JOIN users u1 ON fr.from_user_id = u1.id
       JOIN users u2 ON fr.to_user_id = u2.id
       WHERE fr.to_user_id = $1 AND fr.status = 'pending'
       ORDER BY fr.created_at DESC`,
      [userId]
    );

    return result.rows;
  },

  // 보낸 친구 요청 목록 조회
  async getSentFriendRequests(userId: number): Promise<FriendRequest[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT fr.id, fr.from_user_id as "fromUserId", u1.nickname as "fromNickname",
              fr.to_user_id as "toUserId", u2.nickname as "toNickname", fr.created_at as "createdAt"
       FROM friend_requests fr
       JOIN users u1 ON fr.from_user_id = u1.id
       JOIN users u2 ON fr.to_user_id = u2.id
       WHERE fr.from_user_id = $1 AND fr.status = 'pending'
       ORDER BY fr.created_at DESC`,
      [userId]
    );

    return result.rows;
  },

  // 친구 요청 수락
  async acceptFriendRequest(userId: number, requestId: number): Promise<{success: boolean; message: string; friend?: Friend}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 요청 확인
    const request = await pool.query(
      `SELECT * FROM friend_requests WHERE id = $1 AND to_user_id = $2 AND status = 'pending'`,
      [requestId, userId]
    );

    if (request.rows.length === 0) {
      return { success: false, message: '친구 요청을 찾을 수 없습니다.' };
    }

    const fromUserId = request.rows[0].from_user_id;

    // 요청 상태 변경
    await pool.query(
      `UPDATE friend_requests SET status = 'accepted' WHERE id = $1`,
      [requestId]
    );

    // 양방향 친구 관계 추가
    await pool.query(
      `INSERT INTO friendships (user_id, friend_id) VALUES ($1, $2), ($2, $1)
       ON CONFLICT DO NOTHING`,
      [userId, fromUserId]
    );

    // 친구 정보 조회
    const friendInfo = await pool.query(
      `SELECT u.id, u.nickname, u.email, u.avatar_url as "avatarUrl", fc.code as "friendCode"
       FROM users u
       LEFT JOIN friend_codes fc ON u.id = fc.user_id
       WHERE u.id = $1`,
      [fromUserId]
    );

    return {
      success: true,
      message: '친구 요청을 수락했습니다.',
      friend: friendInfo.rows[0]
    };
  },

  // 친구 요청 거절
  async declineFriendRequest(userId: number, requestId: number): Promise<{success: boolean; message: string}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `UPDATE friend_requests SET status = 'declined'
       WHERE id = $1 AND to_user_id = $2 AND status = 'pending'`,
      [requestId, userId]
    );

    if (result.rowCount === 0) {
      return { success: false, message: '친구 요청을 찾을 수 없습니다.' };
    }

    return { success: true, message: '친구 요청을 거절했습니다.' };
  },

  // 보낸 친구 요청 취소
  async cancelFriendRequest(userId: number, requestId: number): Promise<{success: boolean; message: string}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `DELETE FROM friend_requests
       WHERE id = $1 AND from_user_id = $2 AND status = 'pending'`,
      [requestId, userId]
    );

    if (result.rowCount === 0) {
      return { success: false, message: '친구 요청을 찾을 수 없습니다.' };
    }

    return { success: true, message: '친구 요청을 취소했습니다.' };
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
