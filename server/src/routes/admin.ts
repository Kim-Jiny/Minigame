import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import jwt from 'jsonwebtoken';

const router = Router();
const ADMIN_JWT_SECRET = process.env.JWT_SECRET || 'admin-secret-key';

// 관리자 토큰 검증 미들웨어
function verifyAdminToken(req: Request, res: Response, next: Function) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    res.status(401).json({ error: 'No token provided' });
    return;
  }

  const token = authHeader.split(' ')[1];
  try {
    const payload = jwt.verify(token, ADMIN_JWT_SECRET) as { adminId: number; username: string };
    (req as any).admin = payload;
    next();
  } catch {
    res.status(401).json({ error: 'Invalid token' });
  }
}

// POST /api/admin/login - 관리자 로그인
router.post('/login', async (req: Request, res: Response): Promise<void> => {
  try {
    const { username, password } = req.body;

    if (!username || !password) {
      res.status(400).json({ error: 'Username and password are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      'SELECT id, username FROM dm_admin_accounts WHERE username = $1 AND password = $2',
      [username, password]
    );

    if (result.rows.length === 0) {
      res.status(401).json({ error: 'Invalid credentials' });
      return;
    }

    const admin = result.rows[0];
    const token = jwt.sign(
      { adminId: admin.id, username: admin.username },
      ADMIN_JWT_SECRET,
      { expiresIn: '24h' }
    );

    res.json({ success: true, token, username: admin.username });
  } catch (error) {
    console.error('Admin login error:', error);
    res.status(500).json({ error: 'Login failed' });
  }
});

// GET /api/admin/dm_inquiries - 전체 문의 목록
router.get('/dm_inquiries', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const status = req.query.status as string;
    let query = `
      SELECT i.*, u.nickname, u.email
      FROM dm_inquiries i
      LEFT JOIN dm_users u ON i.user_id = u.id
    `;
    const params: any[] = [];

    if (status && status !== 'all') {
      query += ' WHERE i.status = $1';
      params.push(status);
    }

    query += ' ORDER BY i.created_at DESC LIMIT 100';

    const result = await pool.query(query, params);
    res.json({ dm_inquiries: result.rows });
  } catch (error) {
    console.error('Get dm_inquiries error:', error);
    res.status(500).json({ error: 'Failed to get dm_inquiries' });
  }
});

// GET /api/admin/dm_inquiries/:id - 문의 상세 (유저 정보 포함)
router.get('/dm_inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    // 문의 정보
    const inquiryResult = await pool.query(`
      SELECT i.*, u.nickname, u.email, u.created_at as user_created_at
      FROM dm_inquiries i
      LEFT JOIN dm_users u ON i.user_id = u.id
      WHERE i.id = $1
    `, [id]);

    if (inquiryResult.rows.length === 0) {
      res.status(404).json({ error: 'Inquiry not found' });
      return;
    }

    const inquiry = inquiryResult.rows[0];
    const userId = inquiry.user_id;

    // 최근 접속 정보 (최근 5개)
    const sessionsResult = await pool.query(`
      SELECT ip_address, platform, os_version, device_model, app_version, build_number, created_at
      FROM dm_user_sessions
      WHERE user_id = $1
      ORDER BY created_at DESC
      LIMIT 5
    `, [userId]);

    // 게임 통계
    const statsResult = await pool.query(`
      SELECT game_type, wins, losses, draws, level, exp
      FROM dm_user_game_stats
      WHERE user_id = $1
      ORDER BY (wins + losses + draws) DESC
    `, [userId]);

    // 최근 게임 기록 (최근 10개)
    const recordsResult = await pool.query(`
      SELECT gr.game_type, gr.winner_id, gr.created_at,
             u1.nickname as player1_nickname,
             u2.nickname as player2_nickname
      FROM dm_game_records gr
      LEFT JOIN dm_users u1 ON gr.player1_id = u1.id
      LEFT JOIN dm_users u2 ON gr.player2_id = u2.id
      WHERE gr.player1_id = $1 OR gr.player2_id = $1
      ORDER BY gr.created_at DESC
      LIMIT 10
    `, [userId]);

    // 마일리지 정보
    const mileageResult = await pool.query(`
      SELECT mileage FROM dm_user_mileage WHERE user_id = $1
    `, [userId]);

    res.json({
      inquiry,
      sessions: sessionsResult.rows,
      stats: statsResult.rows,
      recentGames: recordsResult.rows,
      mileage: mileageResult.rows[0]?.mileage || 0,
    });
  } catch (error) {
    console.error('Get inquiry detail error:', error);
    res.status(500).json({ error: 'Failed to get inquiry detail' });
  }
});

// PUT /api/admin/dm_inquiries/:id/reply - 문의 답변
router.put('/dm_inquiries/:id/reply', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const { reply } = req.body;

    if (!reply?.trim()) {
      res.status(400).json({ error: 'Reply is required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `UPDATE dm_inquiries
       SET reply = $1, status = 'replied', replied_at = CURRENT_TIMESTAMP
       WHERE id = $2
       RETURNING *`,
      [reply.trim(), id]
    );

    if (result.rows.length === 0) {
      res.status(404).json({ error: 'Inquiry not found' });
      return;
    }

    res.json({ success: true, inquiry: result.rows[0] });
  } catch (error) {
    console.error('Reply inquiry error:', error);
    res.status(500).json({ error: 'Failed to reply' });
  }
});

// DELETE /api/admin/dm_inquiries/:id - 문의 삭제
router.delete('/dm_inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    await pool.query('DELETE FROM dm_inquiries WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('Delete inquiry error:', error);
    res.status(500).json({ error: 'Failed to delete' });
  }
});

// GET /api/admin/stats - 통계
router.get('/stats', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const [dm_users, dm_inquiries, pending] = await Promise.all([
      pool.query('SELECT COUNT(*) FROM dm_users'),
      pool.query('SELECT COUNT(*) FROM dm_inquiries'),
      pool.query("SELECT COUNT(*) FROM dm_inquiries WHERE status = 'pending'"),
    ]);

    res.json({
      totalUsers: parseInt(dm_users.rows[0].count),
      totalInquiries: parseInt(dm_inquiries.rows[0].count),
      pendingInquiries: parseInt(pending.rows[0].count),
    });
  } catch (error) {
    console.error('Get stats error:', error);
    res.status(500).json({ error: 'Failed to get stats' });
  }
});

export default router;
