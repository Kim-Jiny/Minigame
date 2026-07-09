import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import * as jwt from 'jsonwebtoken';
import bcrypt from 'bcrypt';
import { coinService } from '../services/coinService';
import { parseAndValidate } from '../services/ctrPuzzleValidate';
import { updateNickname } from '../services/userService';
import { sendPushToUser } from '../services/ppPush'; // [PP] 비즈픽셀 문의 답변 푸시
import { tierFor, resolveTier } from '../services/ppTier'; // [PP] 승인 큐 계급 표시 + 계급 오버라이드
import multer from 'multer'; // [SAJA] 사자툰 만화 이미지 업로드용
// [SAJA] sharp 는 네이티브 모듈 — 로드 실패가 서버 전체를 죽이지 않도록 업로드 시점에 지연 로딩한다.
import path from 'path';
import fs from 'fs';

const router = Router();

// [SAJA] 사자툰 만화 이미지 저장 위치. 정적 라우트 /saja(=public/saja)로 서빙되므로
//        파일은 /saja/comics/<파일명> 으로 접근된다. (배포 시 호스트 볼륨으로 영속화)
//        __dirname: dev=src/routes, prod=dist/routes → ../../public 가 server/public 또는 /app/public.
const SAJA_COMIC_DIR = path.join(__dirname, '../../public/saja/comics');
// 업로드는 메모리로 받아 sharp 로 리사이즈/압축 후 webp 로 저장한다(용량 절감).
const sajaUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024 }, // 원본 최대 25MB (압축 전)
  fileFilter: (_req, file, cb) => {
    cb(null, /^image\/(png|jpe?g|webp|gif|heic|heif)$/.test(file.mimetype));
  },
});

// 업로드 이미지를 용량에 맞게 줄여 webp 로 저장하고 상대 URL 반환.
//   kind='thumb' → 600px 안쪽(모아보기 썸네일), 그 외 → 1080px 폭(웹툰 만화컷).
async function saveSajaImage(buffer: Buffer, originalName: string, kind: string): Promise<string> {
  fs.mkdirSync(SAJA_COMIC_DIR, { recursive: true });
  const base = path.basename(originalName, path.extname(originalName))
    .toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 40) || (kind === 'thumb' ? 'thumb' : 'comic');
  const filename = `${base}_${Date.now()}.webp`;

  const sharp = (await import('sharp')).default; // 지연 로딩(네이티브 모듈)
  let pipeline = sharp(buffer, { failOn: 'none' }).rotate(); // EXIF 회전 보정
  if (kind === 'thumb') {
    pipeline = pipeline.resize({ width: 600, height: 600, fit: 'inside', withoutEnlargement: true });
  } else {
    pipeline = pipeline.resize({ width: 1080, withoutEnlargement: true });
  }
  await pipeline.webp({ quality: 80 }).toFile(path.join(SAJA_COMIC_DIR, filename));
  return `/saja/comics/${filename}`;
}

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
// [CTR] CatchTheRule 소유 — /api/admin/ctr/* 엔드포인트 삭제·리팩터링 금지 (리포 루트 CLAUDE.md).
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

// ==================================================================
// [MFA] 성인의 수학(Math for Adults) — /api/admin/mfa/* 엔드포인트.
// 별도 리포(MathForAdults) 앱의 문의 관리. 삭제·리팩터링 금지.
// ==================================================================

// GET /api/admin/mfa/inquiries?status=pending|replied|all - MFA 문의 목록
router.get('/mfa/inquiries', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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
       FROM mfa_inquiries ${where}
       ORDER BY (status = 'pending') DESC, created_at DESC
       LIMIT 300`,
      params
    );
    const pending = await pool.query(`SELECT COUNT(*) FROM mfa_inquiries WHERE status = 'pending'`);
    res.json({ inquiries: result.rows, pendingCount: parseInt(pending.rows[0].count, 10) });
  } catch (error) {
    console.error('MFA admin list inquiries error:', error);
    res.status(500).json({ error: 'Failed to load inquiries' });
  }
});

// PUT /api/admin/mfa/inquiries/:id/reply - MFA 문의 답변
router.put('/mfa/inquiries/:id/reply', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
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
      `UPDATE mfa_inquiries
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
    console.error('MFA admin reply error:', error);
    res.status(500).json({ error: 'Failed to reply' });
  }
});

// DELETE /api/admin/mfa/inquiries/:id - MFA 문의 삭제
router.delete('/mfa/inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    await pool.query('DELETE FROM mfa_inquiries WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('MFA admin delete inquiry error:', error);
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

// GET /api/admin/ctr/purchases?status=verified|failed|all - CTR 인앱결제 내역(영수증 검증 결과)
router.get('/ctr/purchases', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const status = typeof req.query.status === 'string' ? req.query.status : 'all';
    const where = status === 'verified' || status === 'failed' ? 'WHERE status = $1' : '';
    const params = where ? [status] : [];
    const result = await pool.query(
      `SELECT id, device_id, platform, product_id, transaction_id, kind, verified, status, environment, created_at
       FROM ctr_purchases ${where}
       ORDER BY created_at DESC
       LIMIT 500`,
      params
    );
    const agg = await pool.query(
      `SELECT
         COUNT(*)::int AS total,
         COUNT(*) FILTER (WHERE verified)::int AS verified,
         COUNT(*) FILTER (WHERE NOT verified)::int AS failed
       FROM ctr_purchases`
    );
    res.json({ purchases: result.rows, summary: agg.rows[0] });
  } catch (error) {
    console.error('CTR admin list purchases error:', error);
    res.status(500).json({ error: 'Failed to load purchases' });
  }
});

// ── 추가 스테이지(서버 퍼즐) 관리 ──
// GET /api/admin/ctr/puzzles - 목록(편집용 data 포함)
router.get('/ctr/puzzles', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const r = await pool.query(
      `SELECT id, chapter, ord, enabled, data, updated_at FROM ctr_puzzles ORDER BY chapter, ord`
    );
    res.json({ puzzles: r.rows });
  } catch (error) {
    console.error('CTR admin list puzzles error:', error);
    res.status(500).json({ error: 'Failed to load puzzles' });
  }
});

// POST /api/admin/ctr/puzzles - JSON 붙여넣기(단일/배열) 검증 후 upsert
router.post('/ctr/puzzles', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const text = typeof req.body?.text === 'string' ? req.body.text : JSON.stringify(req.body?.puzzles ?? req.body);
    const { ok, puzzles, errors } = parseAndValidate(text);
    if (!ok) { res.status(400).json({ error: 'validation_failed', errors }); return; }
    for (const p of puzzles) {
      await pool.query(
        `INSERT INTO ctr_puzzles (id, chapter, ord, data, enabled, updated_at)
         VALUES ($1,$2,$3,$4,TRUE,CURRENT_TIMESTAMP)
         ON CONFLICT (id) DO UPDATE SET
           chapter=EXCLUDED.chapter, ord=EXCLUDED.ord, data=EXCLUDED.data,
           enabled=TRUE, updated_at=CURRENT_TIMESTAMP`,
        [p.id, p.chapter, p.order, JSON.stringify(p)]
      );
    }
    res.json({ success: true, saved: puzzles.length });
  } catch (error) {
    console.error('CTR admin save puzzles error:', error);
    res.status(500).json({ error: 'Failed to save' });
  }
});

// DELETE /api/admin/ctr/puzzles/:id
router.delete('/ctr/puzzles/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    await pool.query('DELETE FROM ctr_puzzles WHERE id = $1', [req.params.id]);
    res.json({ success: true });
  } catch (error) {
    console.error('CTR admin delete puzzle error:', error);
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

// ================================================================
// [SAJA] 사자툰(SajaToon) 소유 — /api/admin/saja/* 엔드포인트 삭제·리팩터링 금지 (리포 루트 CLAUDE.md).
// 백스테이지에서 사자성어 콘텐츠(sj_idioms)를 등록·수정·삭제한다.
// ================================================================

// 문자열 배열로 정규화 (images: 줄바꿈/배열 모두 허용)
function asStringArray(v: any): string[] {
  if (Array.isArray(v)) return v.map((x) => String(x).trim()).filter(Boolean);
  if (typeof v === 'string') return v.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  return [];
}

// GET /api/admin/saja/idioms - 사자성어 전체(편집용 전체 필드)
router.get('/saja/idioms', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const r = await pool.query(
      `SELECT id, slug, hanja, reading, meaning, origin, modern_example, category,
              level, day_index, comic, images, thumbnail, chars, quiz, quizzes, is_active, updated_at
       FROM sj_idioms
       ORDER BY day_index ASC NULLS LAST, id ASC`
    );
    const idioms = r.rows.map((row: any) => ({
      id: row.id, slug: row.slug, hanja: row.hanja, reading: row.reading,
      meaning: row.meaning, origin: row.origin, modernExample: row.modern_example,
      category: row.category, level: row.level, dayIndex: row.day_index,
      comic: row.comic ?? [], images: row.images ?? [], thumbnail: row.thumbnail ?? null,
      chars: row.chars ?? [],
      quiz: row.quiz ?? null,
      quizzes: (Array.isArray(row.quizzes) && row.quizzes.length > 0) ? row.quizzes : (row.quiz ? [row.quiz] : []),
      isActive: row.is_active, updatedAt: row.updated_at,
    }));
    res.json({ idioms });
  } catch (error) {
    console.error('SAJA admin list idioms error:', error);
    res.status(500).json({ error: 'Failed to load idioms' });
  }
});

// 사자성어 한 건 검증 + upsert(slug 기준). 단일/일괄 등록에서 공용으로 쓴다.
async function upsertSajaIdiom(pool: any, b: any): Promise<{ ok: true; id: number } | { ok: false; error: string }> {
  const slug = typeof b.slug === 'string' ? b.slug.trim().toLowerCase().slice(0, 64) : '';
  const hanja = typeof b.hanja === 'string' ? b.hanja.trim().slice(0, 20) : '';
  const reading = typeof b.reading === 'string' ? b.reading.trim().slice(0, 40) : '';
  const meaning = typeof b.meaning === 'string' ? b.meaning.trim() : '';
  if (!slug || !hanja || !reading || !meaning) {
    return { ok: false, error: 'slug, hanja, reading, meaning 은 필수입니다.' };
  }

  const origin = typeof b.origin === 'string' ? b.origin.trim() : null;
  const modernExample = typeof b.modernExample === 'string' ? b.modernExample.trim() : null;
  const category = typeof b.category === 'string' ? b.category.trim().slice(0, 30) : null;
  const level = Number.isInteger(b.level) ? b.level : parseInt(b.level, 10) || 1;
  const dayIndex = b.dayIndex === '' || b.dayIndex == null ? null : (parseInt(b.dayIndex, 10) || null);
  const images = asStringArray(b.images);
  const comic = Array.isArray(b.comic) ? b.comic : [];
  const thumbnail = typeof b.thumbnail === 'string' && b.thumbnail.trim() ? b.thumbnail.trim() : null;
  const isActive = b.isActive === false ? false : true;

  // chars: 배열이거나 JSON 문자열로 들어올 수 있다. 비면 [].
  let chars: any[] = [];
  if (Array.isArray(b.chars)) chars = b.chars;
  else if (typeof b.chars === 'string' && b.chars.trim()) {
    try { const p = JSON.parse(b.chars); if (Array.isArray(p)) chars = p; }
    catch { return { ok: false, error: '한자 풀이(chars) JSON 형식 오류' }; }
  }

  // quiz: 객체이거나, 문자열(JSON)로 들어오면 파싱. 비면 null. (레거시 단일)
  let quiz: any = null;
  if (b.quiz && typeof b.quiz === 'object') quiz = b.quiz;
  else if (typeof b.quiz === 'string' && b.quiz.trim()) {
    try { quiz = JSON.parse(b.quiz); } catch { return { ok: false, error: 'quiz JSON 형식 오류' }; }
  }

  // quizzes: 배열이거나 JSON 문자열. 단일 객체면 [객체]로. 비면 [].
  let quizzes: any[] = [];
  if (Array.isArray(b.quizzes)) quizzes = b.quizzes;
  else if (typeof b.quizzes === 'string' && b.quizzes.trim()) {
    try {
      const p = JSON.parse(b.quizzes);
      quizzes = Array.isArray(p) ? p : (p && typeof p === 'object' ? [p] : []);
    } catch { return { ok: false, error: '퀴즈 목록(quizzes) JSON 형식 오류' }; }
  }
  // quizzes 가 비고 단일 quiz 만 있으면 리스트로 승격.
  if (quizzes.length === 0 && quiz) quizzes = [quiz];

  const r = await pool.query(
    `INSERT INTO sj_idioms
       (slug, hanja, reading, meaning, origin, modern_example, category, level, day_index, comic, images, thumbnail, chars, quiz, quizzes, is_active, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,CURRENT_TIMESTAMP)
     ON CONFLICT (slug) DO UPDATE SET
       hanja=EXCLUDED.hanja, reading=EXCLUDED.reading, meaning=EXCLUDED.meaning,
       origin=EXCLUDED.origin, modern_example=EXCLUDED.modern_example, category=EXCLUDED.category,
       level=EXCLUDED.level, day_index=EXCLUDED.day_index, comic=EXCLUDED.comic,
       images=EXCLUDED.images, thumbnail=EXCLUDED.thumbnail, chars=EXCLUDED.chars, quiz=EXCLUDED.quiz, quizzes=EXCLUDED.quizzes, is_active=EXCLUDED.is_active,
       updated_at=CURRENT_TIMESTAMP
     RETURNING id`,
    [slug, hanja, reading, meaning, origin, modernExample, category, level, dayIndex,
     JSON.stringify(comic), JSON.stringify(images), thumbnail, JSON.stringify(chars),
     quiz ? JSON.stringify(quiz) : null, JSON.stringify(quizzes), isActive]
  );
  return { ok: true, id: r.rows[0].id };
}

// POST /api/admin/saja/idioms - 등록/수정 (slug 기준 upsert)
router.post('/saja/idioms', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const result = await upsertSajaIdiom(pool, req.body ?? {});
    if (!result.ok) { res.status(400).json({ error: result.error }); return; }
    res.json({ success: true, id: result.id });
  } catch (error) {
    console.error('SAJA admin upsert idiom error:', error);
    res.status(500).json({ error: 'Failed to save idiom' });
  }
});

// body(text/items) → 사자성어 배열로 파싱. 실패 시 { error }.
function parseBulkItems(body: any): { items: any[] } | { error: string } {
  let items: any = body?.items;
  if (!Array.isArray(items)) {
    const text = typeof body?.text === 'string' ? body.text : '';
    if (!text.trim()) return { error: '붙여넣은 JSON이 없습니다.' };
    try {
      const parsed = JSON.parse(text);
      items = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.idioms) ? parsed.idioms : null);
    } catch (e: any) { return { error: 'JSON 파싱 실패 — 배열 형식인지 확인하세요. (' + (e?.message || '') + ')' }; }
  }
  if (!Array.isArray(items)) return { error: 'JSON 최상위가 배열이 아닙니다.' };
  if (items.length === 0) return { error: '배열이 비어 있습니다.' };
  if (items.length > 200) return { error: '한 번에 최대 200개까지 가능합니다.' };
  return { items };
}

// 한 항목의 형식 검증(저장 없이). slug/hanja/reading 과 오류 목록 반환.
function validateSajaItem(b: any): { slug: string; hanja: string; reading: string; errors: string[] } {
  const errors: string[] = [];
  const slug = typeof b?.slug === 'string' ? b.slug.trim().toLowerCase() : '';
  const hanja = typeof b?.hanja === 'string' ? b.hanja.trim() : '';
  const reading = typeof b?.reading === 'string' ? b.reading.trim() : '';
  const meaning = typeof b?.meaning === 'string' ? b.meaning.trim() : '';
  if (!slug) errors.push('slug 누락');
  else if (!/^[a-z0-9_-]+$/.test(slug)) errors.push('slug 형식 오류(영문 소문자/숫자/-_ 만)');
  if (!hanja) errors.push('hanja 누락');
  if (!reading) errors.push('reading 누락');
  if (!meaning) errors.push('meaning 누락');

  const qs = Array.isArray(b?.quizzes) ? b.quizzes : (b?.quiz ? [b.quiz] : []);
  qs.forEach((q: any, i: number) => {
    if (!q || typeof q !== 'object') { errors.push(`quizzes[${i}] 형식 오류`); return; }
    if (!q.question) errors.push(`quizzes[${i}] question 누락`);
    if (!Array.isArray(q.options) || q.options.length < 2) errors.push(`quizzes[${i}] options 2개 이상 필요`);
    else if (!Number.isInteger(q.answerIndex) || q.answerIndex < 0 || q.answerIndex >= q.options.length) {
      errors.push(`quizzes[${i}] answerIndex 범위 오류`);
    }
  });
  if (b?.chars !== undefined && !Array.isArray(b.chars)) errors.push('chars 는 배열이어야 함');
  return { slug, hanja, reading, errors };
}

// 중복 판정: 배치 내/DB(slug·한자). 첫 등장 이후는 중복으로 본다.
function sajaDupReason(
  v: { slug: string; hanja: string },
  seenSlug: Set<string>, seenHanja: Set<string>,
  dbSlugs: Set<string>, dbHanja: Set<string>,
): string | null {
  if (v.slug && seenSlug.has(v.slug)) return '배치 내 slug 중복';
  if (v.hanja && seenHanja.has(v.hanja)) return '배치 내 한자 중복';
  if (v.slug && dbSlugs.has(v.slug)) return '이미 등록된 slug';
  if (v.hanja && dbHanja.has(v.hanja)) return '이미 등록된 한자';
  return null;
}

async function sajaExistingSets(pool: any): Promise<{ dbSlugs: Set<string>; dbHanja: Set<string> }> {
  const ex = await pool.query(`SELECT slug, hanja FROM sj_idioms`);
  return {
    dbSlugs: new Set(ex.rows.map((r: any) => r.slug)),
    dbHanja: new Set(ex.rows.map((r: any) => r.hanja)),
  };
}

// POST /api/admin/saja/idioms/validate - 저장하지 않고 형식·중복만 검사.
router.post('/saja/idioms/validate', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const parsed = parseBulkItems(req.body);
    if ('error' in parsed) { res.status(400).json({ error: parsed.error }); return; }
    const items = parsed.items;

    const { dbSlugs, dbHanja } = await sajaExistingSets(pool);
    const seenSlug = new Set<string>(), seenHanja = new Set<string>();
    const report = items.map((b, i) => {
      const v = validateSajaItem(b);
      const dup = sajaDupReason(v, seenSlug, seenHanja, dbSlugs, dbHanja);
      if (v.slug) seenSlug.add(v.slug);
      if (v.hanja) seenHanja.add(v.hanja);
      return { index: i, slug: v.slug, reading: v.reading, hanja: v.hanja, errors: v.errors, duplicate: dup };
    });
    res.json({
      total: items.length,
      validNew: report.filter((r) => r.errors.length === 0 && !r.duplicate).length,
      duplicates: report.filter((r) => r.duplicate).length,
      invalid: report.filter((r) => r.errors.length > 0).length,
      report,
    });
  } catch (error) {
    console.error('SAJA admin validate error:', error);
    res.status(500).json({ error: 'Failed to validate' });
  }
});

// POST /api/admin/saja/idioms/bulk - 사자성어 배열 일괄 등록(중복 자동 건너뜀).
//   slug/한자가 배치 내 또는 DB에 이미 있으면 skip. 형식 오류는 failed.
router.post('/saja/idioms/bulk', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const parsed = parseBulkItems(req.body);
    if ('error' in parsed) { res.status(400).json({ error: parsed.error }); return; }
    const items = parsed.items;

    const { dbSlugs, dbHanja } = await sajaExistingSets(pool);
    const seenSlug = new Set<string>(), seenHanja = new Set<string>();

    let saved = 0;
    const skipped: Array<{ index: number; slug?: string; reason: string }> = [];
    const errors: Array<{ index: number; slug?: string; error: string }> = [];

    for (let i = 0; i < items.length; i++) {
      const v = validateSajaItem(items[i] ?? {});
      if (v.errors.length > 0) { errors.push({ index: i, slug: v.slug, error: v.errors.join(', ') }); continue; }
      const dup = sajaDupReason(v, seenSlug, seenHanja, dbSlugs, dbHanja);
      seenSlug.add(v.slug); seenHanja.add(v.hanja);
      if (dup) { skipped.push({ index: i, slug: v.slug, reason: dup }); continue; }

      const result = await upsertSajaIdiom(pool, items[i]);
      if (result.ok) saved++;
      else errors.push({ index: i, slug: v.slug, error: result.error });
    }
    res.json({ success: true, saved, skipped, failed: errors.length, errors, skippedCount: skipped.length });
  } catch (error) {
    console.error('SAJA admin bulk upsert error:', error);
    res.status(500).json({ error: 'Failed to bulk save' });
  }
});

// DELETE /api/admin/saja/idioms/:id
router.delete('/saja/idioms/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    // 진도(sj_progress)가 FK로 참조하므로 먼저 정리 후 삭제.
    await pool.query('DELETE FROM sj_progress WHERE idiom_id = $1', [id]);
    await pool.query('DELETE FROM sj_idioms WHERE id = $1', [id]);
    res.json({ success: true });
  } catch (error) {
    console.error('SAJA admin delete idiom error:', error);
    res.status(500).json({ error: 'Failed to delete idiom' });
  }
});

// GET /api/admin/saja/images - 업로드된 만화 이미지 전체 목록 + 연결 여부.
//   사자성어(images/thumbnail)에 연결 안 된 '고아' 이미지를 찾아낸다.
router.get('/saja/images', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    // 참조 맵: 파일명 → 사용 중인 사자성어 읽기들 (절대/상대 URL 모두 파일명으로 매칭).
    const usedBy = new Map<string, string[]>();
    const fileOf = (u: string): string | null => {
      const m = String(u || '').match(/\/saja\/comics\/([^/?#]+)$/);
      return m ? m[1] : null;
    };
    const r = await pool.query(`SELECT reading, images, thumbnail FROM sj_idioms`);
    for (const row of r.rows) {
      const urls: string[] = [];
      if (Array.isArray(row.images)) urls.push(...row.images);
      if (row.thumbnail) urls.push(row.thumbnail);
      for (const u of urls) {
        const f = fileOf(u);
        if (!f) continue;
        const list = usedBy.get(f) || [];
        if (!list.includes(row.reading)) list.push(row.reading);
        usedBy.set(f, list);
      }
    }

    fs.mkdirSync(SAJA_COMIC_DIR, { recursive: true });
    const exts = new Set(['.webp', '.png', '.jpg', '.jpeg', '.gif']);
    const files = fs.readdirSync(SAJA_COMIC_DIR)
      .filter((f) => exts.has(path.extname(f).toLowerCase()));

    const images = files.map((f) => {
      let size = 0;
      try { size = fs.statSync(path.join(SAJA_COMIC_DIR, f)).size; } catch {}
      const used = usedBy.get(f) || [];
      return { url: `/saja/comics/${f}`, filename: f, size, linked: used.length > 0, usedBy: used };
    });
    // 미연결(고아) 먼저, 그다음 파일명 역순(최근 업로드 위로).
    images.sort((a, b) => Number(a.linked) - Number(b.linked) || (a.filename < b.filename ? 1 : -1));

    res.json({ images, orphanCount: images.filter((i) => !i.linked).length });
  } catch (error) {
    console.error('SAJA admin list images error:', error);
    res.status(500).json({ error: 'Failed to list images' });
  }
});

// GET /api/admin/saja/stats - 사자툰 디바이스/학습 통계
router.get('/saja/stats', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const [devices, active, idioms, learned] = await Promise.all([
      pool.query(`SELECT COUNT(*)::int AS c FROM sj_devices`),
      pool.query(`
        SELECT
          COUNT(*) FILTER (WHERE day = CURRENT_DATE)::int AS dau,
          COUNT(DISTINCT device_id) FILTER (WHERE day >= CURRENT_DATE - 6)::int AS wau,
          COUNT(DISTINCT device_id) FILTER (WHERE day >= CURRENT_DATE - 29)::int AS mau
        FROM sj_device_daily`),
      pool.query(`SELECT COUNT(*)::int AS c FROM sj_idioms WHERE is_active = TRUE`),
      pool.query(`SELECT COUNT(*)::int AS c FROM sj_progress WHERE learned = TRUE`),
    ]);
    res.json({
      totalUsers: devices.rows[0].c,
      dau: active.rows[0].dau || 0,
      wau: active.rows[0].wau || 0,
      mau: active.rows[0].mau || 0,
      idiomCount: idioms.rows[0].c,
      learnedTotal: learned.rows[0].c,
    });
  } catch (error) {
    console.error('SAJA admin stats error:', error);
    res.status(500).json({ error: 'Failed to load stats' });
  }
});

// POST /api/admin/saja/upload?kind=comic|thumb - 이미지 업로드(자동 리사이즈/압축 → webp)
//   multipart/form-data, field: file. 응답 url 은 상대경로(/saja/comics/<파일>).
//   앱이 BASE_URL 기준으로 해석하므로 디버그(로컬)·릴리스(운영) 어디서든 같은 값으로 동작.
router.post('/saja/upload', verifyAdminToken, sajaUpload.single('file'), async (req: Request, res: Response): Promise<void> => {
  try {
    const file = (req as any).file;
    if (!file || !file.buffer) {
      res.status(400).json({ error: '이미지 파일이 필요합니다 (png/jpg/webp/gif/heic, 25MB 이하)' });
      return;
    }
    const kind = req.query.kind === 'thumb' ? 'thumb' : 'comic';
    const url = await saveSajaImage(file.buffer, file.originalname || 'image', kind);
    res.json({ success: true, url });
  } catch (error) {
    console.error('SAJA admin upload error:', error);
    res.status(500).json({ error: '이미지 처리 실패' });
  }
});

// POST /api/admin/saja/upload/delete - 업로드된 이미지 파일을 서버 디스크에서 삭제.
//   body: { url } — /saja/comics/<파일명> 형태만 허용(경로 탈출 방지). 이미 없으면 성공 처리.
router.post('/saja/upload/delete', verifyAdminToken, (req: Request, res: Response): void => {
  try {
    const url = typeof req.body?.url === 'string' ? req.body.url : '';
    // 파일명만 안전하게 추출(슬래시/.. 불가). 영숫자·._- 만 허용.
    const m = url.match(/\/saja\/comics\/([A-Za-z0-9._-]+)$/);
    if (!m) { res.status(400).json({ error: '잘못된 이미지 경로입니다.' }); return; }
    const filePath = path.join(SAJA_COMIC_DIR, m[1]);
    if (!path.resolve(filePath).startsWith(path.resolve(SAJA_COMIC_DIR))) {
      res.status(400).json({ error: '잘못된 경로' }); return;
    }
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
    res.json({ success: true });
  } catch (error) {
    console.error('SAJA admin delete file error:', error);
    res.status(500).json({ error: '파일 삭제 실패' });
  }
});

// ==================================================================
// [PP] PerlerPixel(비즈픽셀) — /api/admin/pp/* 엔드포인트.
// 별도 리포(PerlerPixel) 도안 공유 게시판 운영. 삭제·리팩터링 금지 (리포 루트 CLAUDE.md [PP]).
// ==================================================================

async function ppLog(pool: any, admin: string, action: string, targetType: string, targetId: number, memo = '') {
  try {
    await pool.query(
      'INSERT INTO pp_admin_logs (admin, action, target_type, target_id, memo) VALUES ($1,$2,$3,$4,$5)',
      [admin, action, targetType, targetId, memo]
    );
  } catch (e) { console.error('[PP] admin log error:', e); }
}

// 게시글의 report_count 를 남은 'open' 신고 수와 동기화(관리자 처리 후 표시값 정합성 유지).
async function ppSyncReportCount(pool: any, postId: number) {
  try {
    await pool.query(
      `UPDATE pp_posts SET report_count = (SELECT COUNT(*)::int FROM pp_reports WHERE post_id=$1 AND status='open') WHERE id=$1`,
      [postId]
    );
  } catch (e) { console.error('[PP] sync report_count error:', e); }
}

// GET /api/admin/pp/reports?status=open&reason=copyright — 신고 목록(사유별/저작권 필터)
router.get('/pp/reports', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const status = typeof req.query.status === 'string' ? req.query.status : 'open';
    const reason = typeof req.query.reason === 'string' ? req.query.reason : '';
    const params: any[] = [];
    const conds: string[] = [];
    if (status === 'open' || status === 'resolved' || status === 'rejected') { params.push(status); conds.push(`r.status = $${params.length}`); }
    if (reason) { params.push(reason); conds.push(`r.reason = $${params.length}`); }
    const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
    const rows = (await pool.query(
      `SELECT r.id, r.reason, r.detail, r.status, r.created_at,
              r.post_id, p.title AS post_title, p.status AS post_status, p.preview_path,
              p.author_id, au.nickname AS author_nickname, r.reporter_id, ru.nickname AS reporter_nickname
         FROM pp_reports r
         JOIN pp_posts p ON p.id = r.post_id
         LEFT JOIN pp_users au ON au.id = p.author_id
         LEFT JOIN pp_users ru ON ru.id = r.reporter_id
         ${where}
        ORDER BY r.created_at DESC LIMIT 300`, params
    )).rows;
    const openCount = (await pool.query(`SELECT COUNT(*)::int c FROM pp_reports WHERE status='open'`)).rows[0].c;
    res.json({ reports: rows, openCount });
  } catch (e) { console.error('[PP] admin reports error:', e); res.status(500).json({ error: 'Failed to load reports' }); }
});

// POST /api/admin/pp/posts/:id/hide — 도안 비공개(신고 확정) + 관련 신고 resolved
router.post('/pp/posts/:id/hide', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    await pool.query(`UPDATE pp_posts SET status='hidden', updated_at=CURRENT_TIMESTAMP WHERE id=$1`, [id]);
    await pool.query(`UPDATE pp_reports SET status='resolved', resolved_at=CURRENT_TIMESTAMP, resolver=$2 WHERE post_id=$1 AND status='open'`, [id, admin]);
    await ppSyncReportCount(pool, id);
    await ppLog(pool, admin, 'post_hide', 'post', id, typeof req.body?.memo === 'string' ? req.body.memo : '');
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin hide error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/posts/:id/restore — 비공개/pending 도안 복구
router.post('/pp/posts/:id/restore', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    await pool.query(`UPDATE pp_posts SET status='active', updated_at=CURRENT_TIMESTAMP WHERE id=$1 AND status IN ('hidden','pending')`, [id]);
    await pool.query(`UPDATE pp_reports SET status='rejected', resolved_at=CURRENT_TIMESTAMP, resolver=$2 WHERE post_id=$1 AND status='open'`, [id, admin]);
    await ppSyncReportCount(pool, id);
    await ppLog(pool, admin, 'post_restore', 'post', id);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin restore error:', e); res.status(500).json({ error: 'Failed' }); }
});

// DELETE /api/admin/pp/posts/:id — 도안 삭제(소프트)
router.delete('/pp/posts/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    await pool.query(`UPDATE pp_posts SET status='deleted', updated_at=CURRENT_TIMESTAMP WHERE id=$1`, [id]);
    await pool.query(`UPDATE pp_reports SET status='resolved', resolved_at=CURRENT_TIMESTAMP, resolver=$2 WHERE post_id=$1 AND status='open'`, [id, admin]);
    await ppSyncReportCount(pool, id);
    await ppLog(pool, admin, 'post_delete', 'post', id, typeof req.body?.memo === 'string' ? req.body.memo : '');
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin delete error:', e); res.status(500).json({ error: 'Failed' }); }
});

// ───────── 도안 승인(신규 업로드 검토) ─────────
// GET /api/admin/pp/reviews — 승인 대기 큐(status='review'). 오래된 순(먼저 올린 순).
router.get('/pp/reviews', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const rows = (await pool.query(
      `SELECT p.id, p.title, p.description, p.tags, p.visibility, p.width, p.height, p.bead_count,
              p.preview_path, p.created_at, p.author_id, u.nickname AS author_nickname,
              (SELECT COALESCE(SUM(pl.like_count),0)::int FROM pp_posts pl
                WHERE pl.author_id=p.author_id AND pl.status<>'deleted') AS author_likes
         FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id
        WHERE p.status='review'
        ORDER BY p.created_at ASC LIMIT 300`
    )).rows;
    const reviews = rows.map((r: any) => ({ ...r, tier: tierFor(Number(r.author_likes ?? 0)) }));
    res.json({ reviews });
  } catch (e) { console.error('[PP] admin reviews error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/posts/:id/approve — 승인 → 게시(active). review/rejected 에서만.
router.post('/pp/posts/:id/approve', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const r = await pool.query(
      `UPDATE pp_posts SET status='active', updated_at=CURRENT_TIMESTAMP
        WHERE id=$1 AND status IN ('review','rejected') RETURNING author_id, title`, [id]
    );
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'post_approve', 'post', id);
    if (r.rows[0].author_id) {
      await sendPushToUser(pool, r.rows[0].author_id, '도안이 게시됐어요',
        `'${String(r.rows[0].title).slice(0, 40)}' 승인이 완료돼 커뮤니티에 공개됐어요.`, { type: 'pp_post_approved', postId: String(id) });
    }
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin approve error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/posts/:id/reject — 승인 반려 → rejected(+사유 푸시). review/active/pending 에서.
router.post('/pp/posts/:id/reject', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const memo = typeof req.body?.memo === 'string' ? req.body.memo.slice(0, 500) : '';
    const r = await pool.query(
      `UPDATE pp_posts SET status='rejected', updated_at=CURRENT_TIMESTAMP
        WHERE id=$1 AND status IN ('review','active','pending') RETURNING author_id, title`, [id]
    );
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'post_reject', 'post', id, memo);
    if (r.rows[0].author_id) {
      await sendPushToUser(pool, r.rows[0].author_id, '도안이 반려됐어요',
        memo || `'${String(r.rows[0].title).slice(0, 40)}'가 커뮤니티 정책에 맞지 않아 게시되지 않았어요.`, { type: 'pp_post_rejected', postId: String(id) });
    }
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin reject error:', e); res.status(500).json({ error: 'Failed' }); }
});

// ───────── 연관검색(태그 그룹) 관리 ─────────
function parseTagList(input: any, max: number): string[] {
  const arr = Array.isArray(input) ? input : String(input ?? '').split(',');
  return arr.map((t: any) => String(t).trim()).filter(Boolean).slice(0, max);
}

router.get('/pp/tag-groups', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const rows = (await pool.query(`SELECT id, keyword, tags, created_at FROM pp_tag_groups ORDER BY keyword ASC`)).rows;
    res.json({ groups: rows });
  } catch (e) { console.error('[PP] tag-groups list error:', e); res.status(500).json({ error: 'Failed' }); }
});

router.post('/pp/tag-groups', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const admin = (req as any).admin?.username || 'admin';
    const keyword = String(req.body?.keyword || '').trim().slice(0, 40);
    const tags = parseTagList(req.body?.tags, 50);
    if (!keyword) { res.status(400).json({ error: 'keyword_required' }); return; }
    const r = await pool.query(`INSERT INTO pp_tag_groups (keyword, tags) VALUES ($1,$2) RETURNING id`, [keyword, tags]);
    await ppLog(pool, admin, 'tag_group_create', 'tag_group', r.rows[0].id, keyword);
    res.json({ success: true, id: r.rows[0].id });
  } catch (e) { console.error('[PP] tag-group create error:', e); res.status(500).json({ error: 'Failed' }); }
});

router.put('/pp/tag-groups/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const admin = (req as any).admin?.username || 'admin';
    const id = parseInt(String(req.params.id), 10);
    const keyword = String(req.body?.keyword || '').trim().slice(0, 40);
    const tags = parseTagList(req.body?.tags, 50);
    if (!keyword) { res.status(400).json({ error: 'keyword_required' }); return; }
    const r = await pool.query(`UPDATE pp_tag_groups SET keyword=$1, tags=$2 WHERE id=$3 RETURNING id`, [keyword, tags, id]);
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'tag_group_update', 'tag_group', id, keyword);
    res.json({ success: true });
  } catch (e) { console.error('[PP] tag-group update error:', e); res.status(500).json({ error: 'Failed' }); }
});

router.delete('/pp/tag-groups/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const admin = (req as any).admin?.username || 'admin';
    const id = parseInt(String(req.params.id), 10);
    await pool.query(`DELETE FROM pp_tag_groups WHERE id=$1`, [id]);
    await ppLog(pool, admin, 'tag_group_delete', 'tag_group', id);
    res.json({ success: true });
  } catch (e) { console.error('[PP] tag-group delete error:', e); res.status(500).json({ error: 'Failed' }); }
});

// PATCH /api/admin/pp/posts/:id/tags — 게시글 태그 편집(관리자)
router.patch('/pp/posts/:id/tags', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const admin = (req as any).admin?.username || 'admin';
    const id = parseInt(String(req.params.id), 10);
    const tags = parseTagList(req.body?.tags, 10);
    const r = await pool.query(`UPDATE pp_posts SET tags=$1, updated_at=CURRENT_TIMESTAMP WHERE id=$2 RETURNING id`, [tags, id]);
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'post_tags_edit', 'post', id, tags.join(','));
    res.json({ success: true, tags });
  } catch (e) { console.error('[PP] post tags edit error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/reports/:id/reject — 개별 신고 반려
router.post('/pp/reports/:id/reject', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const r = await pool.query(`UPDATE pp_reports SET status='rejected', resolved_at=CURRENT_TIMESTAMP, resolver=$2 WHERE id=$1 RETURNING post_id`, [id, admin]);
    if (r.rows[0]) await ppSyncReportCount(pool, r.rows[0].post_id);
    await ppLog(pool, admin, 'report_reject', 'report', id);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin reject error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/users/:id/ban — 유저 업로드 제한 또는 정지
router.post('/pp/users/:id/ban', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const banType = req.body?.banType === 'full' ? 'full' : 'upload';
    const reason = typeof req.body?.reason === 'string' ? req.body.reason.slice(0, 500) : '';
    const days = parseInt(String(req.body?.days ?? ''), 10);
    const expires = Number.isFinite(days) && days > 0 ? `CURRENT_TIMESTAMP + INTERVAL '${days} days'` : 'NULL';
    await pool.query(
      `INSERT INTO pp_user_bans (user_id, ban_type, reason, expires_at) VALUES ($1,$2,$3,${expires})`,
      [id, banType, reason]
    );
    await ppLog(pool, admin, `user_ban_${banType}`, 'user', id, reason);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin ban error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/users/:id/unban — 유저 제재 해제
router.post('/pp/users/:id/unban', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    await pool.query(`UPDATE pp_user_bans SET expires_at = CURRENT_TIMESTAMP WHERE user_id=$1 AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)`, [id]);
    await ppLog(pool, admin, 'user_unban', 'user', id);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin unban error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/posts?query=&visibility=&status=&cursor= — 도안 검색/전체(페이지네이션)
router.get('/pp/posts', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const q = typeof req.query.query === 'string' ? req.query.query.trim() : '';
    const vis = typeof req.query.visibility === 'string' ? req.query.visibility : '';
    const status = typeof req.query.status === 'string' ? req.query.status : '';
    const limit = 30;
    const offset = Math.max(0, parseInt(String(req.query.cursor ?? '0'), 10) || 0);
    const params: any[] = [];
    let where = `p.status <> 'deleted'`;
    if (q) { params.push(`%${q}%`); where += ` AND p.title ILIKE $${params.length}`; }
    if (vis === 'public' || vis === 'unlisted') { params.push(vis); where += ` AND p.visibility=$${params.length}`; }
    if (['active', 'review', 'pending', 'hidden', 'rejected'].includes(status)) { params.push(status); where += ` AND p.status=$${params.length}`; }
    const total = (await pool.query(`SELECT COUNT(*)::int c FROM pp_posts p WHERE ${where}`, params)).rows[0].c;
    params.push(limit); const limitP = `$${params.length}`;
    params.push(offset); const offsetP = `$${params.length}`;
    const rows = (await pool.query(
      `SELECT p.id, p.title, p.status, p.visibility, p.report_count, p.like_count, p.download_count,
              p.preview_path, p.created_at, p.author_id, p.tags, u.nickname AS author_nickname
         FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id
        WHERE ${where} ORDER BY p.id DESC LIMIT ${limitP} OFFSET ${offsetP}`, params
    )).rows;
    const nextCursor = rows.length === limit ? offset + limit : null;
    res.json({ posts: rows, nextCursor, total });
  } catch (e) { console.error('[PP] admin posts error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/posts/:id — 도안 상세(편집/조치용 전체 필드)
router.get('/pp/posts/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const p = (await pool.query(
      `SELECT p.id, p.title, p.description, p.tags, p.visibility, p.status, p.share_code,
              p.width, p.height, p.bead_count, p.colors, p.preview_path, p.report_count,
              p.like_count, p.download_count, p.created_at, p.updated_at,
              p.author_id, u.nickname AS author_nickname
         FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id WHERE p.id=$1`, [id]
    )).rows[0];
    if (!p) { res.status(404).json({ error: 'not_found' }); return; }
    const reports = (await pool.query(
      `SELECT id, reason, detail, status, created_at FROM pp_reports WHERE post_id=$1 ORDER BY id DESC LIMIT 50`, [id]
    )).rows;
    res.json({ post: p, reports });
  } catch (e) { console.error('[PP] admin post detail error:', e); res.status(500).json({ error: 'Failed' }); }
});

// PATCH /api/admin/pp/posts/:id — 도안 편집(제목·본문·공개설정·태그)
router.patch('/pp/posts/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const b = req.body ?? {};
    const title = typeof b.title === 'string' ? b.title.trim().slice(0, 120) : '';
    if (!title) { res.status(400).json({ error: 'title_required' }); return; }
    const description = (typeof b.description === 'string' ? b.description : '').slice(0, 2000);
    const visibility = b.visibility === 'unlisted' ? 'unlisted' : 'public';
    const tags = parseTagList(b.tags, 10);
    const r = await pool.query(
      `UPDATE pp_posts SET title=$1, description=$2, visibility=$3, tags=$4, updated_at=CURRENT_TIMESTAMP
        WHERE id=$5 AND status<>'deleted' RETURNING id`, [title, description, visibility, tags, id]
    );
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'post_edit', 'post', id, title);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin post edit error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/users?query= — 유저 검색
router.get('/pp/users', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const q = typeof req.query.query === 'string' ? req.query.query.trim() : '';
    const params: any[] = [];
    let where = `1=1`;
    if (q) { params.push(`%${q}%`); where += ` AND (u.nickname ILIKE $${params.length} OR u.email ILIKE $${params.length})`; }
    const rows = (await pool.query(
      `SELECT u.id, u.nickname, u.email, u.provider, u.status, u.created_at,
              (SELECT COUNT(*)::int FROM pp_posts p WHERE p.author_id=u.id AND p.status<>'deleted') AS post_count,
              EXISTS(SELECT 1 FROM pp_user_bans b WHERE b.user_id=u.id AND (b.expires_at IS NULL OR b.expires_at>CURRENT_TIMESTAMP)) AS banned
         FROM pp_users u WHERE ${where} ORDER BY u.id DESC LIMIT 200`, params
    )).rows;
    res.json({ users: rows });
  } catch (e) { console.error('[PP] admin users error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/logs — 처리 로그
router.get('/pp/logs', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const rows = (await pool.query(`SELECT id, admin, action, target_type, target_id, memo, created_at FROM pp_admin_logs ORDER BY id DESC LIMIT 200`)).rows;
    res.json({ logs: rows });
  } catch (e) { console.error('[PP] admin logs error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/stats — 대시보드 요약
router.get('/pp/stats', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const openReports = (await pool.query(`SELECT COUNT(*)::int c FROM pp_reports WHERE status='open'`)).rows[0].c;
    const posts = (await pool.query(`SELECT COUNT(*)::int c FROM pp_posts WHERE status='active'`)).rows[0].c;
    const users = (await pool.query(`SELECT COUNT(*)::int c FROM pp_users WHERE status='active'`)).rows[0].c;
    const pending = (await pool.query(`SELECT COUNT(*)::int c FROM pp_posts WHERE status='pending'`)).rows[0].c;
    const review = (await pool.query(`SELECT COUNT(*)::int c FROM pp_posts WHERE status='review'`)).rows[0].c;
    const openInquiries = (await pool.query(`SELECT COUNT(*)::int c FROM pp_inquiries WHERE status='pending'`)).rows[0].c;
    res.json({ openReports, activePosts: posts, activeUsers: users, pendingPosts: pending, reviewPosts: review, openInquiries });
  } catch (e) { console.error('[PP] admin stats error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/analytics — 통계 탭용 상세 지표
router.get('/pp/analytics', verifyAdminToken, async (_req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const one = async (sql: string) => (await pool.query(sql)).rows[0].c as number;

    const users = {
      total: await one(`SELECT COUNT(*)::int c FROM pp_users WHERE status='active'`),
      new7d: await one(`SELECT COUNT(*)::int c FROM pp_users WHERE status='active' AND created_at > NOW()-INTERVAL '7 days'`),
      new30d: await one(`SELECT COUNT(*)::int c FROM pp_users WHERE status='active' AND created_at > NOW()-INTERVAL '30 days'`),
      admins: await one(`SELECT COUNT(*)::int c FROM pp_users WHERE is_admin=TRUE AND status='active'`),
    };
    const statusRows = (await pool.query(
      `SELECT status, COUNT(*)::int c FROM pp_posts WHERE status<>'deleted' GROUP BY status`
    )).rows as { status: string; c: number }[];
    const byStatus: Record<string, number> = { active: 0, review: 0, pending: 0, hidden: 0, rejected: 0 };
    for (const r of statusRows) byStatus[r.status] = r.c;
    const posts = {
      total: await one(`SELECT COUNT(*)::int c FROM pp_posts WHERE status<>'deleted'`),
      public: await one(`SELECT COUNT(*)::int c FROM pp_posts WHERE status<>'deleted' AND visibility='public'`),
      unlisted: await one(`SELECT COUNT(*)::int c FROM pp_posts WHERE status<>'deleted' AND visibility='unlisted'`),
      byStatus,
    };
    const engagement = {
      totalLikes: await one(`SELECT COUNT(*)::int c FROM pp_likes`),
      totalDownloads: await one(`SELECT COUNT(*)::int c FROM pp_downloads`),
      openReports: await one(`SELECT COUNT(*)::int c FROM pp_reports WHERE status='open'`),
    };
    const recent7d = {
      posts: await one(`SELECT COUNT(*)::int c FROM pp_posts WHERE status<>'deleted' AND created_at > NOW()-INTERVAL '7 days'`),
      likes: await one(`SELECT COUNT(*)::int c FROM pp_likes WHERE created_at > NOW()-INTERVAL '7 days'`),
      downloads: await one(`SELECT COUNT(*)::int c FROM pp_downloads WHERE created_at > NOW()-INTERVAL '7 days'`),
    };
    const topCreators = (await pool.query(
      `SELECT u.id, u.nickname, COALESCE(SUM(p.like_count),0)::int AS likes, COUNT(p.id)::int AS posts
         FROM pp_users u JOIN pp_posts p ON p.author_id=u.id AND p.status<>'deleted'
        WHERE u.status='active'
        GROUP BY u.id, u.nickname ORDER BY likes DESC, posts DESC LIMIT 10`
    )).rows;
    const reportReasons = (await pool.query(
      `SELECT reason, COUNT(*)::int c FROM pp_reports GROUP BY reason ORDER BY c DESC`
    )).rows;
    const dailyUploads = (await pool.query(
      `SELECT to_char(date_trunc('day', created_at), 'MM-DD') AS day, COUNT(*)::int c
         FROM pp_posts WHERE status<>'deleted' AND created_at > NOW()-INTERVAL '14 days'
        GROUP BY 1 ORDER BY 1`
    )).rows;

    res.json({ users, posts, engagement, recent7d, topCreators, reportReasons, dailyUploads });
  } catch (e) { console.error('[PP] admin analytics error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/inquiries?status=pending|replied|all — 문의 목록
router.get('/pp/inquiries', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const status = typeof req.query.status === 'string' ? req.query.status : 'all';
    const where = status === 'pending' || status === 'replied' ? 'WHERE i.status = $1' : '';
    const params = where ? [status] : [];
    const rows = (await pool.query(
      `SELECT i.id, i.content, i.status, i.reply, i.replied_at, i.is_read, i.created_at,
              i.user_id, u.nickname AS user_nickname, u.email AS user_email
         FROM pp_inquiries i LEFT JOIN pp_users u ON u.id = i.user_id
         ${where} ORDER BY (i.status='pending') DESC, i.created_at DESC LIMIT 300`, params
    )).rows;
    const pending = (await pool.query(`SELECT COUNT(*)::int c FROM pp_inquiries WHERE status='pending'`)).rows[0].c;
    res.json({ inquiries: rows, pendingCount: pending });
  } catch (e) { console.error('[PP] admin inquiries error:', e); res.status(500).json({ error: 'Failed' }); }
});

// PUT /api/admin/pp/inquiries/:id/reply — 문의 답변(+유저 푸시)
router.put('/pp/inquiries/:id/reply', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const reply = typeof req.body?.reply === 'string' ? req.body.reply.trim() : '';
    if (!reply) { res.status(400).json({ error: 'reply_required' }); return; }
    const r = await pool.query(
      `UPDATE pp_inquiries SET reply=$1, status='replied', replied_at=CURRENT_TIMESTAMP, is_read=FALSE
       WHERE id=$2 RETURNING user_id`, [reply, id]
    );
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, (req as any).admin?.username || 'admin', 'inquiry_reply', 'inquiry', id);
    // 답변 도착 푸시(설정 시)
    await sendPushToUser(pool, r.rows[0].user_id, '문의 답변이 도착했어요', reply.slice(0, 80), { type: 'inquiry_reply' });
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin reply error:', e); res.status(500).json({ error: 'Failed' }); }
});

// DELETE /api/admin/pp/inquiries/:id — 문의 삭제
router.delete('/pp/inquiries/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    await pool.query('DELETE FROM pp_inquiries WHERE id=$1', [parseInt(String(req.params.id), 10)]);
    res.json({ success: true });
  } catch (e) { console.error('[PP] admin inquiry delete error:', e); res.status(500).json({ error: 'Failed' }); }
});

// GET /api/admin/pp/users/:id — 유저 상세(정보 + 도안 + 신고/제재 + 문의)
router.get('/pp/users/:id', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const user = (await pool.query(
      `SELECT id, nickname, email, provider, status, created_at, is_admin, tier_override FROM pp_users WHERE id=$1`, [id]
    )).rows[0];
    if (!user) { res.status(404).json({ error: 'not_found' }); return; }
    const likes = (await pool.query(
      `SELECT COALESCE(SUM(like_count),0)::int c FROM pp_posts WHERE author_id=$1 AND status<>'deleted'`, [id]
    )).rows[0].c;
    const tier = resolveTier(likes, user.tier_override ?? null);
    const posts = (await pool.query(
      `SELECT id, title, status, visibility, report_count, like_count, download_count, preview_path, created_at
         FROM pp_posts WHERE author_id=$1 AND status<>'deleted' ORDER BY id DESC LIMIT 100`, [id]
    )).rows;
    const reportsReceived = (await pool.query(
      `SELECT COUNT(*)::int c FROM pp_reports r JOIN pp_posts p ON p.id=r.post_id WHERE p.author_id=$1`, [id]
    )).rows[0].c;
    const bans = (await pool.query(
      `SELECT id, ban_type, reason, banned_at, expires_at FROM pp_user_bans WHERE user_id=$1 ORDER BY id DESC LIMIT 20`, [id]
    )).rows;
    const activeBan = bans.find((b: any) => !b.expires_at || new Date(b.expires_at) > new Date()) || null;
    const inquiries = (await pool.query(
      `SELECT id, content, status, reply, created_at FROM pp_inquiries WHERE user_id=$1 ORDER BY id DESC LIMIT 20`, [id]
    )).rows;
    res.json({ user, posts, reportsReceived, bans, activeBan, inquiries, likesReceived: likes, tier });
  } catch (e) { console.error('[PP] admin user detail error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/users/:id/admin — 앱 내 관리자 권한 부여/회수({grant:boolean})
router.post('/pp/users/:id/admin', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const grant = req.body?.grant !== false;
    const r = await pool.query(`UPDATE pp_users SET is_admin=$2, updated_at=CURRENT_TIMESTAMP WHERE id=$1 RETURNING id`, [id, grant]);
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, grant ? 'user_admin_grant' : 'user_admin_revoke', 'user', id);
    res.json({ success: true, isAdmin: grant });
  } catch (e) { console.error('[PP] admin grant error:', e); res.status(500).json({ error: 'Failed' }); }
});

// POST /api/admin/pp/users/:id/tier — 창작자 계급 수동 지정(level 1~7) 또는 자동(null)
router.post('/pp/users/:id/tier', verifyAdminToken, async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool(); if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }
    const id = parseInt(String(req.params.id), 10);
    const admin = (req as any).admin?.username || 'admin';
    const raw = req.body?.level;
    const level = (raw === null || raw === '' || raw === undefined) ? null : Math.max(1, Math.min(7, parseInt(String(raw), 10) || 0));
    const r = await pool.query(`UPDATE pp_users SET tier_override=$2, updated_at=CURRENT_TIMESTAMP WHERE id=$1 RETURNING id`, [id, level]);
    if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
    await ppLog(pool, admin, 'user_tier_override', 'user', id, level === null ? 'auto' : `Lv${level}`);
    res.json({ success: true, tierOverride: level });
  } catch (e) { console.error('[PP] admin tier override error:', e); res.status(500).json({ error: 'Failed' }); }
});

export default router;
