import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import * as jwt from 'jsonwebtoken';
import bcrypt from 'bcrypt';
import { coinService } from '../services/coinService';
import { updateNickname } from '../services/userService';

const router = Router();

// ADMIN_JWT_SECRET은 반드시 환경변수로 주입해야 한다. 운영 환경에서 누락 시
// 관리자 토큰 위조 위험이 있으므로 부팅을 실패시킨다.
function resolveAdminJwtSecret(): string {
  const fromEnv = process.env.ADMIN_JWT_SECRET;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('ADMIN_JWT_SECRET environment variable is required in production');
  }
  console.warn('[admin] ADMIN_JWT_SECRET not set - using development fallback (DO NOT USE IN PRODUCTION)');
  return 'dev-only-admin-secret';
}

const ADMIN_JWT_SECRET = resolveAdminJwtSecret();

// 관리자 토큰 검증 미들웨어
async function verifyAdminToken(req: Request, res: Response, next: Function) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    res.status(401).json({ error: 'No token provided' });
    return;
  }

  const token = authHeader.split(' ')[1];
  try {
    const payload = jwt.verify(token, ADMIN_JWT_SECRET) as { adminId: number; username: string };
    if (!payload.adminId || !payload.username) {
      res.status(401).json({ error: 'Invalid token payload' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      'SELECT id, username FROM dm_admin_accounts WHERE id = $1 AND username = $2',
      [payload.adminId, payload.username]
    );

    if (result.rows.length === 0) {
      res.status(401).json({ error: 'Admin account not found' });
      return;
    }

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
      'SELECT id, username, password FROM dm_admin_accounts WHERE username = $1',
      [username]
    );

    if (result.rows.length === 0) {
      res.status(401).json({ error: 'Invalid credentials' });
      return;
    }

    const admin = result.rows[0];
    const passwordMatched = await bcrypt.compare(password, admin.password);
    if (!passwordMatched) {
      res.status(401).json({ error: 'Invalid credentials' });
      return;
    }

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

// ============================================================
// Stats
// ============================================================

// GET /api/admin/stats - 확장된 대시보드 통계
router.get('/stats', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const [
      totalUsers,
      newUsersToday,
      newUsersWeek,
      newUsersMonth,
      totalInquiries,
      pendingInquiries,
      gamesToday,
      activeUsers,
      gamePopularity,
      shopRevenue,
      adRewards,
    ] = await Promise.all([
      pool.query('SELECT COUNT(*) FROM dm_users'),
      pool.query("SELECT COUNT(*) FROM dm_users WHERE created_at >= CURRENT_DATE"),
      pool.query("SELECT COUNT(*) FROM dm_users WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'"),
      pool.query("SELECT COUNT(*) FROM dm_users WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'"),
      pool.query('SELECT COUNT(*) FROM dm_inquiries'),
      pool.query("SELECT COUNT(*) FROM dm_inquiries WHERE status = 'pending'"),
      pool.query("SELECT COUNT(*) FROM dm_game_records WHERE created_at >= CURRENT_DATE"),
      pool.query("SELECT COUNT(DISTINCT user_id) FROM dm_user_sessions WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'"),
      pool.query(`
        SELECT game_type, COUNT(*) as count
        FROM dm_game_records
        GROUP BY game_type
        ORDER BY count DESC
      `),
      pool.query(`
        SELECT
          COALESCE(SUM(CASE WHEN h.created_at >= CURRENT_DATE THEN ABS(h.amount) ELSE 0 END), 0) as today,
          COALESCE(SUM(ABS(h.amount)), 0) as total
        FROM dm_mileage_history h
        WHERE h.reason LIKE 'shop_%'
      `),
      pool.query(`
        SELECT
          COALESCE(COUNT(CASE WHEN created_at >= CURRENT_DATE THEN 1 END), 0) as today,
          COALESCE(SUM(CASE WHEN created_at >= CURRENT_DATE THEN amount ELSE 0 END), 0) as today_coins,
          COUNT(*) as total,
          COALESCE(SUM(amount), 0) as total_coins
        FROM dm_mileage_history
        WHERE reason = 'ad_reward'
      `),
    ]);

    res.json({
      totalUsers: parseInt(totalUsers.rows[0].count),
      newUsersToday: parseInt(newUsersToday.rows[0].count),
      newUsersWeek: parseInt(newUsersWeek.rows[0].count),
      newUsersMonth: parseInt(newUsersMonth.rows[0].count),
      totalInquiries: parseInt(totalInquiries.rows[0].count),
      pendingInquiries: parseInt(pendingInquiries.rows[0].count),
      gamesToday: parseInt(gamesToday.rows[0].count),
      activeUsers: parseInt(activeUsers.rows[0].count),
      gamePopularity: gamePopularity.rows,
      shopRevenue: {
        today: parseInt(shopRevenue.rows[0].today),
        total: parseInt(shopRevenue.rows[0].total),
      },
      adRewards: {
        today: parseInt(adRewards.rows[0].today),
        todayCoins: parseInt(adRewards.rows[0].today_coins),
        total: parseInt(adRewards.rows[0].total),
        totalCoins: parseInt(adRewards.rows[0].total_coins),
      },
    });
  } catch (error) {
    console.error('Get stats error:', error);
    res.status(500).json({ error: 'Failed to get stats' });
  }
});

// ============================================================
// Inquiries (라우트 경로 수정: dm_inquiries → inquiries)
// ============================================================

// GET /api/admin/inquiries - 전체 문의 목록
router.get('/inquiries', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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
    res.json({ inquiries: result.rows });
  } catch (error) {
    console.error('Get inquiries error:', error);
    res.status(500).json({ error: 'Failed to get inquiries' });
  }
});

// GET /api/admin/inquiries/:id - 문의 상세 (유저 정보 포함)
router.get('/inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

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

    const [sessionsResult, statsResult, recordsResult, mileageResult] = await Promise.all([
      pool.query(`
        SELECT ip_address, platform, os_version, device_model, app_version, build_number, created_at
        FROM dm_user_sessions WHERE user_id = $1 ORDER BY created_at DESC LIMIT 5
      `, [userId]),
      pool.query(`
        SELECT game_type, wins, losses, draws, level, exp
        FROM dm_user_game_stats WHERE user_id = $1 ORDER BY (wins + losses + draws) DESC
      `, [userId]),
      pool.query(`
        SELECT gr.game_type, gr.winner_id, gr.created_at,
               u1.nickname as player1_nickname, u2.nickname as player2_nickname
        FROM dm_game_records gr
        LEFT JOIN dm_users u1 ON gr.player1_id = u1.id
        LEFT JOIN dm_users u2 ON gr.player2_id = u2.id
        WHERE gr.player1_id = $1 OR gr.player2_id = $1
        ORDER BY gr.created_at DESC LIMIT 10
      `, [userId]),
      pool.query('SELECT mileage FROM dm_user_mileage WHERE user_id = $1', [userId]),
    ]);

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

// PUT /api/admin/inquiries/:id/reply - 문의 답변
router.put('/inquiries/:id/reply', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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
      `UPDATE dm_inquiries SET reply = $1, status = 'replied', replied_at = CURRENT_TIMESTAMP WHERE id = $2 RETURNING *`,
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

// DELETE /api/admin/inquiries/:id - 문의 삭제
router.delete('/inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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

// ============================================================
// Users
// ============================================================

// GET /api/admin/users - 유저 검색/목록
router.get('/users', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const q = (req.query.q as string || '').trim();
    const page = Math.max(1, parseInt(req.query.page as string) || 1);
    const limit = Math.min(50, Math.max(1, parseInt(req.query.limit as string) || 20));
    const offset = (page - 1) * limit;

    let whereClause = '';
    const params: any[] = [];

    if (q) {
      params.push(`%${q}%`);
      whereClause = `WHERE u.nickname ILIKE $1 OR u.email ILIKE $1 OR CAST(u.id AS TEXT) = $${params.length + 1}`;
      params.push(q);
    }

    const countResult = await pool.query(
      `SELECT COUNT(*) FROM dm_users u ${whereClause}`,
      params
    );
    const total = parseInt(countResult.rows[0].count);

    const usersResult = await pool.query(
      `SELECT u.id, u.nickname, u.email, u.provider, u.created_at,
              COALESCE(m.mileage, 0) as coins
       FROM dm_users u
       LEFT JOIN dm_user_mileage m ON u.id = m.user_id
       ${whereClause}
       ORDER BY u.id DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, limit, offset]
    );

    res.json({
      users: usersResult.rows,
      total,
      page,
      totalPages: Math.ceil(total / limit),
    });
  } catch (error) {
    console.error('Get users error:', error);
    res.status(500).json({ error: 'Failed to get users' });
  }
});

// GET /api/admin/users/:id - 유저 상세
router.get('/users/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const userResult = await pool.query(`
      SELECT u.*, COALESCE(m.mileage, 0) as coins
      FROM dm_users u
      LEFT JOIN dm_user_mileage m ON u.id = m.user_id
      WHERE u.id = $1
    `, [id]);

    if (userResult.rows.length === 0) {
      res.status(404).json({ error: 'User not found' });
      return;
    }

    const [stats, items, profileSettings, sessions, mileageHistory, bans] = await Promise.all([
      pool.query(`
        SELECT game_type, wins, losses, draws, level, exp
        FROM dm_user_game_stats WHERE user_id = $1 ORDER BY (wins + losses + draws) DESC
      `, [id]),
      pool.query(`
        SELECT ui.id, ui.purchased_at, ui.expires_at,
               si.item_key, si.name, si.category, si.rarity, si.price
        FROM dm_user_items ui
        JOIN dm_shop_items si ON ui.item_id = si.id
        WHERE ui.user_id = $1
        ORDER BY ui.purchased_at DESC
      `, [id]),
      pool.query(`
        SELECT ps.*,
               f.name as frame_name, t.name as title_name, th.name as theme_name, a.name as avatar_name
        FROM dm_user_profile_settings ps
        LEFT JOIN dm_shop_items f ON ps.active_frame_id = f.id
        LEFT JOIN dm_shop_items t ON ps.active_title_id = t.id
        LEFT JOIN dm_shop_items th ON ps.active_theme_id = th.id
        LEFT JOIN dm_shop_items a ON ps.active_avatar_id = a.id
        WHERE ps.user_id = $1
      `, [id]),
      pool.query(`
        SELECT ip_address, platform, os_version, device_model, app_version, build_number, created_at
        FROM dm_user_sessions WHERE user_id = $1 ORDER BY created_at DESC LIMIT 10
      `, [id]),
      pool.query(`
        SELECT amount, reason, created_at
        FROM dm_mileage_history WHERE user_id = $1 ORDER BY created_at DESC LIMIT 30
      `, [id]),
      pool.query(`
        SELECT b.*, a.username as banned_by_name, r.username as revoked_by_name
        FROM dm_user_bans b
        LEFT JOIN dm_admin_accounts a ON b.banned_by = a.id
        LEFT JOIN dm_admin_accounts r ON b.revoked_by = r.id
        WHERE b.user_id = $1
        ORDER BY b.banned_at DESC
      `, [id]),
    ]);

    res.json({
      user: userResult.rows[0],
      stats: stats.rows,
      items: items.rows,
      profileSettings: profileSettings.rows[0] || null,
      sessions: sessions.rows,
      mileageHistory: mileageHistory.rows,
      bans: bans.rows,
    });
  } catch (error) {
    console.error('Get user detail error:', error);
    res.status(500).json({ error: 'Failed to get user detail' });
  }
});

// POST /api/admin/users/:id/coins - 코인 지급/차감
router.post('/users/:id/coins', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const { amount, reason } = req.body;

    if (!amount || !reason?.trim()) {
      res.status(400).json({ error: 'Amount and reason are required' });
      return;
    }

    const numAmount = parseInt(amount);
    if (isNaN(numAmount) || numAmount === 0) {
      res.status(400).json({ error: 'Invalid amount' });
      return;
    }

    const prefix = numAmount > 0 ? 'admin_grant' : 'admin_deduct';
    const newBalance = await coinService.addCoins(parseInt(id as string), numAmount, `${prefix}: ${reason.trim()}`);

    res.json({ success: true, newBalance });
  } catch (error) {
    console.error('Admin coins error:', error);
    res.status(500).json({ error: 'Failed to update coins' });
  }
});

// POST /api/admin/users/:id/ban - 유저 밴
router.post('/users/:id/ban', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const { ban_type, reason, duration_hours } = req.body;
    const admin = (req as any).admin;

    if (!ban_type || !reason?.trim()) {
      res.status(400).json({ error: 'ban_type and reason are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    let expiresAt = null;
    if (ban_type === 'temporary' && duration_hours) {
      expiresAt = new Date(Date.now() + duration_hours * 60 * 60 * 1000).toISOString();
    }

    const result = await pool.query(
      `INSERT INTO dm_user_bans (user_id, ban_type, reason, banned_by, expires_at)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [id, ban_type, reason.trim(), admin.adminId, expiresAt]
    );

    res.json({ success: true, ban: result.rows[0] });
  } catch (error) {
    console.error('Ban user error:', error);
    res.status(500).json({ error: 'Failed to ban user' });
  }
});

// POST /api/admin/users/:id/unban - 밴 해제
router.post('/users/:id/unban', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const admin = (req as any).admin;

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `UPDATE dm_user_bans
       SET is_active = FALSE, revoked_at = CURRENT_TIMESTAMP, revoked_by = $1
       WHERE user_id = $2 AND is_active = TRUE
       RETURNING *`,
      [admin.adminId, id]
    );

    res.json({ success: true, unbanned: result.rowCount });
  } catch (error) {
    console.error('Unban user error:', error);
    res.status(500).json({ error: 'Failed to unban user' });
  }
});

// PUT /api/admin/users/:id/nickname - 닉네임 강제 변경
router.put('/users/:id/nickname', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const { nickname, reason } = req.body;
    const admin = (req as any).admin;

    if (!nickname?.trim() || !reason?.trim()) {
      res.status(400).json({ error: 'Nickname and reason are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const updatedUser = await updateNickname(parseInt(id as string), nickname.trim());

    // dm_user_bans에 nickname_forced 기록
    await pool.query(
      `INSERT INTO dm_user_bans (user_id, ban_type, reason, banned_by)
       VALUES ($1, 'nickname_forced', $2, $3)`,
      [id, reason.trim(), admin.adminId]
    );

    res.json({ success: true, user: updatedUser });
  } catch (error) {
    console.error('Change nickname error:', error);
    res.status(500).json({ error: 'Failed to change nickname' });
  }
});

// ============================================================
// Notices
// ============================================================

// GET /api/admin/notices - 공지 목록
router.get('/notices', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(`
      SELECT n.*, a.username as created_by_name
      FROM dm_notices n
      LEFT JOIN dm_admin_accounts a ON n.created_by = a.id
      ORDER BY n.created_at DESC
    `);

    res.json({ notices: result.rows });
  } catch (error) {
    console.error('Get notices error:', error);
    res.status(500).json({ error: 'Failed to get notices' });
  }
});

// POST /api/admin/notices - 공지 생성
router.post('/notices', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { title, content, type, is_active } = req.body;
    const admin = (req as any).admin;

    if (!title?.trim() || !content?.trim()) {
      res.status(400).json({ error: 'Title and content are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `INSERT INTO dm_notices (title, content, type, is_active, created_by)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [title.trim(), content.trim(), type || 'general', is_active !== false, admin.adminId]
    );

    res.json({ success: true, notice: result.rows[0] });
  } catch (error) {
    console.error('Create notice error:', error);
    res.status(500).json({ error: 'Failed to create notice' });
  }
});

// PUT /api/admin/notices/:id - 공지 수정
router.put('/notices/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const { title, content, type, is_active } = req.body;

    if (!title?.trim() || !content?.trim()) {
      res.status(400).json({ error: 'Title and content are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `UPDATE dm_notices
       SET title = $1, content = $2, type = $3, is_active = $4, updated_at = CURRENT_TIMESTAMP
       WHERE id = $5 RETURNING *`,
      [title.trim(), content.trim(), type || 'general', is_active !== false, id]
    );

    if (result.rows.length === 0) {
      res.status(404).json({ error: 'Notice not found' });
      return;
    }

    res.json({ success: true, notice: result.rows[0] });
  } catch (error) {
    console.error('Update notice error:', error);
    res.status(500).json({ error: 'Failed to update notice' });
  }
});

// DELETE /api/admin/notices/:id - 공지 삭제
router.delete('/notices/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    await pool.query('DELETE FROM dm_notices WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('Delete notice error:', error);
    res.status(500).json({ error: 'Failed to delete notice' });
  }
});

// ============================================================
// Ad Config
// ============================================================

// GET /api/admin/ad-config - 광고 설정 목록
router.get('/ad-config', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query('SELECT * FROM dm_ad_config ORDER BY id');
    res.json({ configs: result.rows });
  } catch (error) {
    console.error('Get ad config error:', error);
    res.status(500).json({ error: 'Failed to get ad config' });
  }
});

// PUT /api/admin/ad-config/:key - 광고 설정 수정
router.put('/ad-config/:key', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { key } = req.params;
    const { value } = req.body;

    if (value === undefined || value === null) {
      res.status(400).json({ error: 'Value is required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `UPDATE dm_ad_config SET config_value = $1, updated_at = CURRENT_TIMESTAMP WHERE config_key = $2 RETURNING *`,
      [String(value), key]
    );

    if (result.rows.length === 0) {
      res.status(404).json({ error: 'Config key not found' });
      return;
    }

    res.json({ success: true, config: result.rows[0] });
  } catch (error) {
    console.error('Update ad config error:', error);
    res.status(500).json({ error: 'Failed to update ad config' });
  }
});

// ==================================================================
// 규칙찾기(CatchTheRule) 관리 — 게임별 admin 모듈. 확장 시 게임별로 추가.
// ==================================================================

// GET /api/admin/ctr/inquiries?status=pending|replied|all - CTR 문의 목록
router.get('/ctr/inquiries', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const status = typeof req.query.status === 'string' ? req.query.status : 'all';
    const where = status === 'pending' || status === 'replied' ? 'WHERE status = $1' : '';
    const params = where ? [status] : [];
    const result = await pool.query(
      `SELECT id, device_id, nickname, content, status, reply, replied_at, is_read, created_at
       FROM ctr_inquiries ${where}
       ORDER BY (status = 'pending') DESC, created_at DESC
       LIMIT 300`,
      params
    );
    const pending = await pool.query(`SELECT COUNT(*) FROM ctr_inquiries WHERE status = 'pending'`);
    res.json({ inquiries: result.rows, pendingCount: parseInt(pending.rows[0].count, 10) });
  } catch (error) {
    console.error('CTR admin list inquiries error:', error);
    res.status(500).json({ error: 'Failed to load inquiries' });
  }
});

// PUT /api/admin/ctr/inquiries/:id/reply - CTR 문의 답변
router.put('/ctr/inquiries/:id/reply', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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
      `UPDATE ctr_inquiries
       SET reply = $1, status = 'replied', replied_at = CURRENT_TIMESTAMP, is_read = FALSE
       WHERE id = $2 RETURNING *`,
      [reply.trim(), id]
    );
    if (result.rows.length === 0) {
      res.status(404).json({ error: 'Inquiry not found' });
      return;
    }
    res.json({ success: true, inquiry: result.rows[0] });
  } catch (error) {
    console.error('CTR admin reply error:', error);
    res.status(500).json({ error: 'Failed to reply' });
  }
});

// DELETE /api/admin/ctr/inquiries/:id - CTR 문의 삭제
router.delete('/ctr/inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    await pool.query('DELETE FROM ctr_inquiries WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('CTR admin delete inquiry error:', error);
    res.status(500).json({ error: 'Failed to delete' });
  }
});

// GET /api/admin/ctr/rankings?mode=timeAttack - CTR 랭킹 목록(운영 관리용)
router.get('/ctr/rankings', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const mode = typeof req.query.mode === 'string' && req.query.mode ? req.query.mode : 'timeAttack';
    const result = await pool.query(
      `SELECT id, mode, device_id, nickname, country, score, created_at, updated_at
       FROM ctr_rankings WHERE mode = $1
       ORDER BY score DESC, updated_at ASC
       LIMIT 500`,
      [mode]
    );
    res.json({ rankings: result.rows });
  } catch (error) {
    console.error('CTR admin list rankings error:', error);
    res.status(500).json({ error: 'Failed to load rankings' });
  }
});

// DELETE /api/admin/ctr/rankings/:id - CTR 랭킹 기록 삭제(부정행위·부적절 닉네임 등)
router.delete('/ctr/rankings/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    await pool.query('DELETE FROM ctr_rankings WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('CTR admin delete ranking error:', error);
    res.status(500).json({ error: 'Failed to delete' });
  }
});

// GET /api/admin/ctr/stats - CTR 디바이스/유저 통계
router.get('/ctr/stats', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const [total, platform, newToday, active, countries, versions] = await Promise.all([
      pool.query(`SELECT COUNT(*)::int AS c FROM ctr_devices`),
      pool.query(`SELECT COALESCE(platform, 'unknown') AS platform, COUNT(*)::int AS c FROM ctr_devices GROUP BY platform`),
      pool.query(`SELECT COUNT(*)::int AS c FROM ctr_devices WHERE first_seen::date = CURRENT_DATE`),
      pool.query(`
        SELECT
          COUNT(*) FILTER (WHERE day = CURRENT_DATE)::int AS dau,
          COUNT(DISTINCT device_id) FILTER (WHERE day >= CURRENT_DATE - 6)::int AS wau,
          COUNT(DISTINCT device_id) FILTER (WHERE day >= CURRENT_DATE - 29)::int AS mau
        FROM ctr_device_daily`),
      pool.query(`SELECT COALESCE(country, '??') AS country, COUNT(*)::int AS c FROM ctr_devices GROUP BY country ORDER BY c DESC LIMIT 10`),
      pool.query(`SELECT COALESCE(app_version, '?') AS version, COUNT(*)::int AS c FROM ctr_devices GROUP BY app_version ORDER BY c DESC LIMIT 10`),
    ]);

    const byPlatform: Record<string, number> = {};
    platform.rows.forEach((r) => { byPlatform[r.platform] = r.c; });

    res.json({
      totalUsers: total.rows[0].c,
      ios: byPlatform['ios'] || 0,
      android: byPlatform['android'] || 0,
      newToday: newToday.rows[0].c,
      dau: active.rows[0].dau || 0,
      wau: active.rows[0].wau || 0,
      mau: active.rows[0].mau || 0,
      countries: countries.rows,
      versions: versions.rows,
    });
  } catch (error) {
    console.error('CTR admin stats error:', error);
    res.status(500).json({ error: 'Failed to load stats' });
  }
});

export default router;
