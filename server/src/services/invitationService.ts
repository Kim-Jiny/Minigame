import { getPool } from '../config/database';

export interface Invitation {
  id: number;
  inviterId: number;
  inviterNickname: string;
  inviteeId: number;
  inviteeNickname: string;
  gameType: string;
  isHardcore: boolean;
  status: 'pending' | 'accepted' | 'declined' | 'expired';
  roomId?: string;
  createdAt: Date;
}

export const invitationService = {
  // 초대 생성
  async createInvitation(inviterId: number, inviteeId: number, gameType: string, isHardcore: boolean = false): Promise<Invitation> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 기존 pending 초대가 있으면 만료 처리
    await pool.query(
      `UPDATE game_invitations SET status = 'expired'
       WHERE inviter_id = $1 AND invitee_id = $2 AND status = 'pending'`,
      [inviterId, inviteeId]
    );

    const result = await pool.query(
      `INSERT INTO game_invitations (inviter_id, invitee_id, game_type, is_hardcore, status)
       VALUES ($1, $2, $3, $4, 'pending')
       RETURNING id, created_at`,
      [inviterId, inviteeId, gameType, isHardcore]
    );

    // 초대 정보와 사용자 정보 함께 조회
    const invitation = await pool.query(
      `SELECT gi.id, gi.inviter_id as "inviterId", u1.nickname as "inviterNickname",
              gi.invitee_id as "inviteeId", u2.nickname as "inviteeNickname",
              gi.game_type as "gameType", gi.is_hardcore as "isHardcore",
              gi.status, gi.room_id as "roomId",
              gi.created_at as "createdAt"
       FROM game_invitations gi
       JOIN users u1 ON gi.inviter_id = u1.id
       JOIN users u2 ON gi.invitee_id = u2.id
       WHERE gi.id = $1`,
      [result.rows[0].id]
    );

    return invitation.rows[0];
  },

  // 받은 초대 목록 조회
  async getInvitations(userId: number): Promise<Invitation[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT gi.id, gi.inviter_id as "inviterId", u1.nickname as "inviterNickname",
              gi.invitee_id as "inviteeId", u2.nickname as "inviteeNickname",
              gi.game_type as "gameType", COALESCE(gi.is_hardcore, false) as "isHardcore",
              gi.status, gi.room_id as "roomId",
              gi.created_at as "createdAt"
       FROM game_invitations gi
       JOIN users u1 ON gi.inviter_id = u1.id
       JOIN users u2 ON gi.invitee_id = u2.id
       WHERE gi.invitee_id = $1 AND gi.status = 'pending'
       AND gi.created_at > NOW() - INTERVAL '5 minutes'
       ORDER BY gi.created_at DESC`,
      [userId]
    );

    return result.rows;
  },

  // 초대 조회
  async getInvitation(invitationId: number): Promise<Invitation | null> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT gi.id, gi.inviter_id as "inviterId", u1.nickname as "inviterNickname",
              gi.invitee_id as "inviteeId", u2.nickname as "inviteeNickname",
              gi.game_type as "gameType", COALESCE(gi.is_hardcore, false) as "isHardcore",
              gi.status, gi.room_id as "roomId",
              gi.created_at as "createdAt"
       FROM game_invitations gi
       JOIN users u1 ON gi.inviter_id = u1.id
       JOIN users u2 ON gi.invitee_id = u2.id
       WHERE gi.id = $1`,
      [invitationId]
    );

    return result.rows.length > 0 ? result.rows[0] : null;
  },

  // 초대 수락
  async acceptInvitation(invitationId: number, roomId: string): Promise<{success: boolean; message: string; invitation?: Invitation}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 초대 상태 확인
    const existing = await this.getInvitation(invitationId);
    if (!existing) {
      return { success: false, message: '초대를 찾을 수 없습니다.' };
    }

    if (existing.status !== 'pending') {
      return { success: false, message: '이미 처리된 초대입니다.' };
    }

    // 5분 초과 확인
    const createdAt = new Date(existing.createdAt);
    const now = new Date();
    if (now.getTime() - createdAt.getTime() > 5 * 60 * 1000) {
      await pool.query(
        `UPDATE game_invitations SET status = 'expired' WHERE id = $1`,
        [invitationId]
      );
      return { success: false, message: '만료된 초대입니다.' };
    }

    // 수락 처리
    await pool.query(
      `UPDATE game_invitations SET status = 'accepted', room_id = $2 WHERE id = $1`,
      [invitationId, roomId]
    );

    const updated = await this.getInvitation(invitationId);
    return { success: true, message: '초대를 수락했습니다.', invitation: updated! };
  },

  // 초대 거절
  async declineInvitation(invitationId: number): Promise<{success: boolean; message: string}> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const existing = await this.getInvitation(invitationId);
    if (!existing) {
      return { success: false, message: '초대를 찾을 수 없습니다.' };
    }

    if (existing.status !== 'pending') {
      return { success: false, message: '이미 처리된 초대입니다.' };
    }

    await pool.query(
      `UPDATE game_invitations SET status = 'declined' WHERE id = $1`,
      [invitationId]
    );

    return { success: true, message: '초대를 거절했습니다.' };
  }
};
