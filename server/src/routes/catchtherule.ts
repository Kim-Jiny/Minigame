import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import { verifyApple, verifyAndroid, CTR_PRODUCTS, type VerifyResult } from '../services/ctrIap';

/**
 * CatchTheRule (규칙찾기) 솔로 랭킹 API.
 *
 * 로그인이 없는 앱이라 JWT 없이 공개 엔드포인트로 동작한다.
 * 닉네임 + 점수로 등록하고, 기기당 1행을 유지하기 위해 선택적으로 deviceId 를 받는다.
 * 테이블 프리픽스는 ctr_ 로 다른 앱(dm_)과 분리. (스키마는 config/database.ts)
 *
 *   POST /api/catchtherule/scores       { nickname, score, mode?, deviceId? } -> { rank, score }
 *   GET  /api/catchtherule/leaderboard?mode=timeAttack&limit=100 -> { entries: [{ rank, nickname, score }] }
 */
const router = Router();

const MAX_SCORE = 100000;
const ALLOWED_MODES = new Set(['timeAttack']);

function normalizeMode(value: unknown): string {
  return typeof value === 'string' && ALLOWED_MODES.has(value) ? value : 'timeAttack';
}

// POST /api/catchtherule/scores — 점수 제출 후 내 순위 반환
router.post('/scores', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const body = req.body ?? {};
    const nickname = typeof body.nickname === 'string' ? body.nickname.trim() : '';
    const score = body.score;
    const mode = normalizeMode(body.mode);
    const deviceId =
      typeof body.deviceId === 'string' && body.deviceId.trim()
        ? body.deviceId.trim().slice(0, 64)
        : null;
    // ISO 3166-1 alpha-2 국가코드(예: KR). 형식 안 맞으면 null.
    const country =
      typeof body.country === 'string' && /^[A-Za-z]{2}$/.test(body.country)
        ? body.country.toUpperCase()
        : null;

    if (!nickname || nickname.length > 20) {
      res.status(400).json({ error: 'nickname is required (1-20 chars)' });
      return;
    }
    if (!Number.isInteger(score) || score < 0 || score > MAX_SCORE) {
      res.status(400).json({ error: `score must be an integer between 0 and ${MAX_SCORE}` });
      return;
    }
    // deviceId 필수: 기기당 1행(최고점) 보장 + 중복 등록 방지.
    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }

    // 기기당 1행 upsert(최고점 유지).
    const upserted = await pool.query(
      `INSERT INTO ctr_rankings (mode, device_id, nickname, country, score)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (mode, device_id) WHERE device_id IS NOT NULL
       DO UPDATE SET
         score = GREATEST(ctr_rankings.score, EXCLUDED.score),
         nickname = EXCLUDED.nickname,
         country = EXCLUDED.country,
         updated_at = CURRENT_TIMESTAMP
       RETURNING score`,
      [mode, deviceId, nickname, country, score]
    );
    const bestScore = upserted.rows[0].score;

    // 내 최고점보다 높은 점수의 개수 + 1 = 순위 (동점은 같은 순위).
    const rankResult = await pool.query(
      `SELECT COUNT(*) + 1 AS rank FROM ctr_rankings WHERE mode = $1 AND score > $2`,
      [mode, bestScore]
    );
    const rank = parseInt(rankResult.rows[0].rank, 10);

    res.json({ success: true, mode, nickname, score: bestScore, rank });
  } catch (error) {
    console.error('CTR submit score error:', error);
    res.status(500).json({ error: 'Failed to submit score' });
  }
});

// GET /api/catchtherule/leaderboard — 상위 N 랭킹
router.get('/leaderboard', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const mode = normalizeMode(req.query.mode);
    let limit = parseInt(String(req.query.limit ?? '100'), 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = 100;
    limit = Math.min(limit, 200);

    const result = await pool.query(
      `SELECT nickname,
              country,
              score,
              RANK() OVER (ORDER BY score DESC) AS rank
       FROM ctr_rankings
       WHERE mode = $1
       ORDER BY score DESC, created_at ASC
       LIMIT $2`,
      [mode, limit]
    );

    const entries = result.rows.map((row) => ({
      rank: Number(row.rank),
      nickname: row.nickname as string,
      country: (row.country as string | null) ?? null,
      score: row.score as number,
    }));

    res.json({ mode, entries });
  } catch (error) {
    console.error('CTR leaderboard error:', error);
    res.status(500).json({ error: 'Failed to get leaderboard' });
  }
});

// ---------------- 디바이스 핑 (익명 유저 카운팅) ----------------

// POST /api/catchtherule/devices/ping — 앱 실행 시 1회 호출
router.post('/devices/ping', async (req: Request, res: Response): Promise<void> => {
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
    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }
    const platform = body.platform === 'ios' || body.platform === 'android' ? body.platform : null;
    const country =
      typeof body.country === 'string' && /^[A-Za-z]{2}$/.test(body.country)
        ? body.country.toUpperCase()
        : null;
    const appVersion = typeof body.appVersion === 'string' ? body.appVersion.slice(0, 20) : null;
    const osVersion = typeof body.osVersion === 'string' ? body.osVersion.slice(0, 30) : null;

    await pool.query(
      `INSERT INTO ctr_devices (device_id, platform, country, app_version, os_version)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (device_id) DO UPDATE SET
         platform = COALESCE(EXCLUDED.platform, ctr_devices.platform),
         country = COALESCE(EXCLUDED.country, ctr_devices.country),
         app_version = COALESCE(EXCLUDED.app_version, ctr_devices.app_version),
         os_version = COALESCE(EXCLUDED.os_version, ctr_devices.os_version),
         launch_count = ctr_devices.launch_count + 1,
         last_seen = CURRENT_TIMESTAMP`,
      [deviceId, platform, country, appVersion, osVersion]
    );
    await pool.query(
      `INSERT INTO ctr_device_daily (device_id, day, platform)
       VALUES ($1, CURRENT_DATE, $2)
       ON CONFLICT (device_id, day) DO NOTHING`,
      [deviceId, platform]
    );
    res.json({ success: true });
  } catch (error) {
    console.error('CTR device ping error:', error);
    res.status(500).json({ error: 'Failed to ping' });
  }
});

// ---------------- 문의 (로그인 없음, deviceId 기반) ----------------

// POST /api/catchtherule/inquiries — 문의 등록
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
      `INSERT INTO ctr_inquiries (device_id, nickname, content)
       VALUES ($1, $2, $3)
       RETURNING id, content, status, created_at`,
      [deviceId, nickname, content]
    );
    res.json({ success: true, inquiry: result.rows[0] });
  } catch (error) {
    console.error('CTR create inquiry error:', error);
    res.status(500).json({ error: 'Failed to create inquiry' });
  }
});

// GET /api/catchtherule/inquiries?deviceId=... — 내 문의 목록(답변 포함)
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
       FROM ctr_inquiries
       WHERE device_id = $1
       ORDER BY created_at DESC
       LIMIT 100`,
      [deviceId]
    );
    res.json({ inquiries: result.rows });
  } catch (error) {
    console.error('CTR get inquiries error:', error);
    res.status(500).json({ error: 'Failed to get inquiries' });
  }
});

// POST /api/catchtherule/inquiries/read?deviceId=... — 답변 읽음 처리
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
      `UPDATE ctr_inquiries SET is_read = TRUE WHERE device_id = $1 AND status = 'replied'`,
      [deviceId]
    );
    res.json({ success: true });
  } catch (error) {
    console.error('CTR mark inquiry read error:', error);
    res.status(500).json({ error: 'Failed to mark read' });
  }
});

// POST /api/catchtherule/iap/verify - 인앱결제 영수증 검증 + 기록
//   body(iOS):     { platform:"ios", deviceId, productId, transactionId, payload(JWS) }
//   body(Android): { platform:"android", deviceId, productId, transactionId, payload(originalJson), signature }
//   resp: { verified, kind, hints, alreadyProcessed }
router.post('/iap/verify', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    const body = req.body ?? {};
    const platform = body.platform === 'ios' || body.platform === 'android' ? body.platform : null;
    const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim().slice(0, 64) : null;
    const payload = typeof body.payload === 'string' ? body.payload : '';
    if (!platform || !payload) { res.status(400).json({ error: 'platform and payload required' }); return; }

    // 검증
    let result: VerifyResult;
    if (platform === 'ios') {
      result = verifyApple(payload);
    } else {
      result = verifyAndroid(payload, typeof body.signature === 'string' ? body.signature : '');
    }

    // 권위 있는 값은 검증된 페이로드에서, 없으면 클라이언트 값으로 보완
    const productId = result.productId || (typeof body.productId === 'string' ? body.productId : '');
    const transactionId = result.transactionId || (typeof body.transactionId === 'string' ? body.transactionId : '');
    const product = CTR_PRODUCTS[productId];
    const kind = product?.kind ?? null;
    const status = result.verified ? 'verified' : 'failed';

    if (!transactionId) { res.status(400).json({ error: 'transactionId missing' }); return; }

    // 기록 (transaction 중복 시 재지급 방지). 새로 들어온 경우만 inserted.
    const ins = await pool.query(
      `INSERT INTO ctr_purchases (device_id, platform, product_id, transaction_id, kind, verified, status, environment, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (platform, transaction_id) DO NOTHING
       RETURNING id`,
      [deviceId, platform, productId, transactionId, kind, result.verified, status, result.environment || null,
       JSON.stringify({ reason: result.reason || null }).slice(0, 4000)]
    );
    const alreadyProcessed = ins.rows.length === 0;

    res.json({
      verified: result.verified,
      kind,
      hints: product?.hints ?? 0,
      alreadyProcessed,
      reason: result.reason,
    });
  } catch (error) {
    console.error('CTR iap verify error:', error);
    res.status(500).json({ error: 'verify failed' });
  }
});

export default router;
