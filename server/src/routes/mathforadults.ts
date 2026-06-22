// [MFA] 성인의 수학(Math for Adults) 공개 API — 별도 리포 ~/Documents/Jiny/MathForAdults 소유.
// 로그인 없는 deviceId 기반. 문의 등록/조회/읽음 처리. 삭제·리팩터링 금지.
import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import { verifyGoogle, verifyApple, signMfaToken, verifyMfaToken } from '../services/mfaAuth';

const router = Router();

// POST /api/mathforadults/inquiries — 문의 등록
router.post('/inquiries', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const body = req.body ?? {};
    const deviceId =
      typeof body.deviceId === 'string' && body.deviceId.trim()
        ? body.deviceId.trim().slice(0, 64)
        : null;
    const nickname =
      typeof body.nickname === 'string' && body.nickname.trim()
        ? body.nickname.trim().slice(0, 20)
        : null;
    const content = typeof body.content === 'string' ? body.content.trim() : '';

    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }
    if (!content || content.length > 2000) {
      res.status(400).json({ error: 'content is required (1-2000 chars)' });
      return;
    }

    const result = await pool.query(
      `INSERT INTO mfa_inquiries (device_id, nickname, content)
       VALUES ($1, $2, $3)
       RETURNING id, content, status, created_at`,
      [deviceId, nickname, content]
    );
    res.json({ success: true, inquiry: result.rows[0] });
  } catch (error) {
    console.error('MFA create inquiry error:', error);
    res.status(500).json({ error: 'Failed to create inquiry' });
  }
});

// GET /api/mathforadults/inquiries?deviceId=... — 내 문의 목록(답변 포함)
router.get('/inquiries', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const deviceId = typeof req.query.deviceId === 'string' ? req.query.deviceId.trim() : '';
    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }
    const result = await pool.query(
      `SELECT id, content, status, reply, replied_at, is_read, created_at
       FROM mfa_inquiries
       WHERE device_id = $1
       ORDER BY created_at DESC
       LIMIT 100`,
      [deviceId]
    );
    res.json({ inquiries: result.rows });
  } catch (error) {
    console.error('MFA get inquiries error:', error);
    res.status(500).json({ error: 'Failed to get inquiries' });
  }
});

// POST /api/mathforadults/inquiries/read — 답변 읽음 처리
router.post('/inquiries/read', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const deviceId = typeof req.body?.deviceId === 'string' ? req.body.deviceId.trim() : '';
    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }
    await pool.query(
      `UPDATE mfa_inquiries SET is_read = TRUE WHERE device_id = $1 AND status = 'replied'`,
      [deviceId]
    );
    res.json({ success: true });
  } catch (error) {
    console.error('MFA mark inquiry read error:', error);
    res.status(500).json({ error: 'Failed to mark read' });
  }
});

// ---------------- 소셜 로그인 + 진도 동기화 (선택적) ----------------

// POST /api/mathforadults/auth/social — { provider: 'google'|'apple', idToken }
// 소셜 토큰 검증 → 사용자 upsert → 자체 JWT 발급.
router.post('/auth/social', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const provider = req.body?.provider;
    const idToken = req.body?.idToken;
    if ((provider !== 'google' && provider !== 'apple') || typeof idToken !== 'string') {
      res.status(400).json({ error: 'provider(google|apple) and idToken are required' });
      return;
    }

    const social = provider === 'google'
        ? await verifyGoogle(idToken)
        : await verifyApple(idToken);
    if (!social) {
      res.status(401).json({ error: 'Invalid social token' });
      return;
    }

    const upsert = await pool.query(
      `INSERT INTO mfa_users (provider, provider_uid, email)
       VALUES ($1, $2, $3)
       ON CONFLICT (provider, provider_uid)
       DO UPDATE SET last_login = CURRENT_TIMESTAMP,
                     email = COALESCE(EXCLUDED.email, mfa_users.email)
       RETURNING id, nickname, email`,
      [provider, social.uid, social.email]
    );
    const user = upsert.rows[0];
    const token = signMfaToken(user.id);
    res.json({
      success: true,
      token,
      user: { id: user.id, nickname: user.nickname, email: user.email },
    });
  } catch (error) {
    console.error('MFA social auth error:', error);
    res.status(500).json({ error: 'Auth failed' });
  }
});

// 인증 미들웨어 — Authorization: Bearer <mfa jwt>
function mfaAuth(req: Request, res: Response): number | null {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) {
    res.status(401).json({ error: 'No token' });
    return null;
  }
  const userId = verifyMfaToken(h.slice(7));
  if (userId === null) {
    res.status(401).json({ error: 'Invalid token' });
    return null;
  }
  return userId;
}

// GET /api/mathforadults/progress — 내 진도 내려받기
router.get('/progress', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const r = await pool.query(
      'SELECT data, updated_at FROM mfa_progress WHERE user_id = $1',
      [userId]
    );
    if (r.rows.length === 0) {
      res.json({ data: null, updatedAt: null });
      return;
    }
    res.json({ data: r.rows[0].data, updatedAt: r.rows[0].updated_at });
  } catch (error) {
    console.error('MFA get progress error:', error);
    res.status(500).json({ error: 'Failed to load progress' });
  }
});

// PUT /api/mathforadults/progress — { data } 진도 올리기(덮어쓰기)
router.put('/progress', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const data = req.body?.data;
    if (data == null || typeof data !== 'object') {
      res.status(400).json({ error: 'data(object) is required' });
      return;
    }
    await pool.query(
      `INSERT INTO mfa_progress (user_id, data, updated_at)
       VALUES ($1, $2, CURRENT_TIMESTAMP)
       ON CONFLICT (user_id)
       DO UPDATE SET data = EXCLUDED.data, updated_at = CURRENT_TIMESTAMP`,
      [userId, JSON.stringify(data)]
    );
    res.json({ success: true });
  } catch (error) {
    console.error('MFA put progress error:', error);
    res.status(500).json({ error: 'Failed to save progress' });
  }
});

export default router;
