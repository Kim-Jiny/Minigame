import { getPool } from '../config/database';

export interface Message {
  id: number;
  senderId: number;
  senderNickname: string;
  receiverId: number;
  receiverNickname: string;
  content: string;
  isRead: boolean;
  createdAt: string;
  isMine: boolean;
}

export const messageService = {
  // 메시지 전송
  async sendMessage(senderId: number, receiverId: number, content: string): Promise<Message | null> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 친구 관계 확인
    const friendship = await pool.query(
      'SELECT id FROM friendships WHERE user_id = $1 AND friend_id = $2',
      [senderId, receiverId]
    );

    if (friendship.rows.length === 0) {
      return null; // 친구가 아님
    }

    const result = await pool.query(
      `INSERT INTO friend_messages (sender_id, receiver_id, content)
       VALUES ($1, $2, $3)
       RETURNING id, sender_id, receiver_id, content, is_read, created_at`,
      [senderId, receiverId, content]
    );

    const msg = result.rows[0];

    // 발신자/수신자 닉네임 조회
    const users = await pool.query(
      'SELECT id, nickname FROM users WHERE id IN ($1, $2)',
      [senderId, receiverId]
    );

    const senderNickname = users.rows.find((u: any) => u.id === senderId)?.nickname || '';
    const receiverNickname = users.rows.find((u: any) => u.id === receiverId)?.nickname || '';

    return {
      id: msg.id,
      senderId: msg.sender_id,
      senderNickname,
      receiverId: msg.receiver_id,
      receiverNickname,
      content: msg.content,
      isRead: msg.is_read,
      createdAt: msg.created_at.toISOString(),
      isMine: true,
    };
  },

  // 특정 친구와의 대화 조회
  async getMessages(userId: number, friendId: number, limit: number = 50): Promise<Message[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 7일 이내 메시지만 조회
    const result = await pool.query(
      `SELECT
        m.id, m.sender_id, m.receiver_id, m.content, m.is_read, m.created_at,
        s.nickname as sender_nickname,
        r.nickname as receiver_nickname
       FROM friend_messages m
       JOIN users s ON m.sender_id = s.id
       JOIN users r ON m.receiver_id = r.id
       WHERE ((m.sender_id = $1 AND m.receiver_id = $2) OR (m.sender_id = $2 AND m.receiver_id = $1))
         AND m.created_at > NOW() - INTERVAL '7 days'
       ORDER BY m.created_at ASC
       LIMIT $3`,
      [userId, friendId, limit]
    );

    return result.rows.map(row => ({
      id: row.id,
      senderId: row.sender_id,
      senderNickname: row.sender_nickname,
      receiverId: row.receiver_id,
      receiverNickname: row.receiver_nickname,
      content: row.content,
      isRead: row.is_read,
      createdAt: row.created_at.toISOString(),
      isMine: row.sender_id === userId,
    }));
  },

  // 메시지 읽음 처리
  async markAsRead(userId: number, friendId: number): Promise<void> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    await pool.query(
      `UPDATE friend_messages
       SET is_read = TRUE
       WHERE sender_id = $1 AND receiver_id = $2 AND is_read = FALSE`,
      [friendId, userId]
    );
  },

  // 안 읽은 메시지 수 조회
  async getUnreadCount(userId: number, friendId?: number): Promise<number | { [friendId: number]: number }> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    if (friendId) {
      const result = await pool.query(
        `SELECT COUNT(*) as count
         FROM friend_messages
         WHERE sender_id = $1 AND receiver_id = $2 AND is_read = FALSE
           AND created_at > NOW() - INTERVAL '7 days'`,
        [friendId, userId]
      );
      return parseInt(result.rows[0].count);
    }

    // 전체 친구별 안 읽은 메시지 수
    const result = await pool.query(
      `SELECT sender_id, COUNT(*) as count
       FROM friend_messages
       WHERE receiver_id = $1 AND is_read = FALSE
         AND created_at > NOW() - INTERVAL '7 days'
       GROUP BY sender_id`,
      [userId]
    );

    const counts: { [friendId: number]: number } = {};
    result.rows.forEach((row: any) => {
      counts[row.sender_id] = parseInt(row.count);
    });
    return counts;
  },

  // 오래된 메시지 삭제 (7일 이상)
  async deleteOldMessages(): Promise<number> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `DELETE FROM friend_messages WHERE created_at < NOW() - INTERVAL '7 days'`
    );

    return result.rowCount || 0;
  },
};
