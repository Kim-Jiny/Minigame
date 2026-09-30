// [MFA] 성인의 수학(Math for Adults) 공개 API — 별도 리포 ~/Documents/Jiny/MathForAdults 소유.
// 로그인 없는 deviceId 기반. 문의 등록/조회/읽음 처리. 삭제·리팩터링 금지.
import { Router, Request, Response } from 'express';
import { randomUUID } from 'crypto';
import { getPool } from '../config/database';
import {
  verifyGoogle,
  verifyApple,
  verifyKakao,
  signMfaToken,
  verifyMfaToken,
  randomGuestNickname,
} from '../services/mfaAuth';
import { verifyApple as verifyAppleIap, verifyAndroid as verifyAndroidIap, MFA_PRODUCTS, VerifyResult } from '../services/mfaIap';

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

// POST /api/mathforadults/auth/social
//   google/apple: { provider, idToken }  |  kakao: { provider: 'kakao', accessToken }
// 소셜 토큰 검증 → 사용자 upsert → 자체 JWT 발급.
router.post('/auth/social', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const provider = req.body?.provider;
    if (provider !== 'google' && provider !== 'apple' && provider !== 'kakao') {
      res.status(400).json({ error: 'provider(google|apple|kakao) is required' });
      return;
    }

    let social: Awaited<ReturnType<typeof verifyGoogle>> = null;
    if (provider === 'kakao') {
      const accessToken = req.body?.accessToken;
      if (typeof accessToken !== 'string') {
        res.status(400).json({ error: 'accessToken is required for kakao' });
        return;
      }
      social = await verifyKakao(accessToken);
    } else {
      const idToken = req.body?.idToken;
      if (typeof idToken !== 'string') {
        res.status(400).json({ error: 'idToken is required' });
        return;
      }
      social = provider === 'google' ? await verifyGoogle(idToken) : await verifyApple(idToken);
    }
    if (!social) {
      res.status(401).json({ error: 'Invalid social token' });
      return;
    }

    // 소셜에서 닉네임을 안 주면(Kakao는 비즈 앱 인증 전엔 항상 null) 신규 계정에
    // guest-xxxxxx 기본 닉네임을 부여한다. 기존 계정은 ON CONFLICT에서 nickname을
    // 건드리지 않으므로 이미 있는 닉네임(기본값이든 직접 바꾼 값이든)은 유지된다.
    const defaultNickname = social.name ?? randomGuestNickname();
    // 인앱결제 영수증에 심을 계정 식별자 — 매번 새로 만들어서 넘기되, 이미 있으면
    // COALESCE가 기존 값을 유지한다(신규 계정은 이걸로 최초 부여, 기존 계정은 다음
    // 로그인 때 자동 백필).
    const freshIapUuid = randomUUID();
    const upsert = await pool.query(
      `INSERT INTO mfa_users (provider, provider_uid, email, nickname, iap_account_uuid)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (provider, provider_uid)
       DO UPDATE SET last_login = CURRENT_TIMESTAMP,
                     email = COALESCE(EXCLUDED.email, mfa_users.email),
                     iap_account_uuid = COALESCE(mfa_users.iap_account_uuid, EXCLUDED.iap_account_uuid)
       RETURNING id, nickname, email, iap_account_uuid`,
      [provider, social.uid, social.email, defaultNickname, freshIapUuid]
    );
    const user = upsert.rows[0];
    const token = signMfaToken(user.id);
    res.json({
      success: true,
      token,
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        iapAccountUuid: user.iap_account_uuid,
      },
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

// PUT /api/mathforadults/auth/nickname — { nickname } 닉네임 변경(기본 guest-xxxxxx에서 바꾸기)
router.put('/auth/nickname', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const nickname = typeof req.body?.nickname === 'string' ? req.body.nickname.trim() : '';
    if (!nickname || nickname.length > 20) {
      res.status(400).json({ error: 'nickname is required (1-20 chars)' });
      return;
    }
    const result = await pool.query(
      `UPDATE mfa_users SET nickname = $1 WHERE id = $2
       RETURNING id, nickname, email, iap_account_uuid`,
      [nickname, userId]
    );
    const u = result.rows[0];
    res.json({
      success: true,
      user: { id: u.id, nickname: u.nickname, email: u.email, iapAccountUuid: u.iap_account_uuid },
    });
  } catch (error) {
    console.error('MFA update nickname error:', error);
    res.status(500).json({ error: 'Failed to update nickname' });
  }
});

// DELETE /api/mathforadults/account — 회원탈퇴. 계정 삭제 시 mfa_progress는 함께 삭제(ON DELETE CASCADE),
// mfa_purchases는 회계 기록 보존을 위해 user_id만 NULL 처리(ON DELETE SET NULL). Apple/Google 스토어
// 정책상 "계정 생성을 지원하면 앱 내 계정 삭제도 제공해야 함" 요건 대응.
router.delete('/account', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    await pool.query('DELETE FROM mfa_users WHERE id = $1', [userId]);
    res.json({ success: true });
  } catch (error) {
    console.error('MFA delete account error:', error);
    res.status(500).json({ error: 'Failed to delete account' });
  }
});

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

// ---------------- 인앱결제 ----------------

// POST /api/mathforadults/iap/verify — 인앱결제 영수증 검증 + 기록
//   body(iOS):     { platform:"ios", productId, transactionId, payload(JWS) }
//   body(Android): { platform:"android", productId, transactionId, payload(originalJson), signature }
//   resp: { verified, kind, coupons, alreadyProcessed }
// 로그인 필수(Bearer) — 구매는 계정에 귀속된다. 힌트쿠폰 개수는 여기서 직접 반영하지 않고
// (진도의 단일 소스는 클라이언트 UserStats), 클라이언트가 verified:true를 받으면
// 로컬에서 hintCoupons를 올린 뒤 기존 PUT /progress로 반영한다.
router.post('/iap/verify', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const body = req.body ?? {};
    const platform = body.platform === 'ios' || body.platform === 'android' ? body.platform : null;
    const payload = typeof body.payload === 'string' ? body.payload : '';
    if (!platform || !payload) {
      res.status(400).json({ error: 'platform and payload required' });
      return;
    }

    let result: VerifyResult;
    if (platform === 'ios') {
      result = verifyAppleIap(payload);
    } else {
      result = verifyAndroidIap(
        payload,
        typeof body.signature === 'string' ? body.signature : ''
      );
    }

    const productId = result.productId || (typeof body.productId === 'string' ? body.productId : '');
    const transactionId =
      result.transactionId || (typeof body.transactionId === 'string' ? body.transactionId : '');
    const product = MFA_PRODUCTS[productId];
    const kind = product?.kind ?? null;
    const status = result.verified ? 'verified' : 'failed';

    if (!transactionId) {
      res.status(400).json({ error: 'transactionId missing' });
      return;
    }

    // 영수증에 계정 식별자(accountUuid)가 심어져 있으면, 지금 인증된 JWT 소유자와
    // 실제로 일치하는지 대조해서 감사 로그를 남긴다. 값이 다르더라도 지급 자체는 항상
    // "지금 검증을 마친 세션(JWT 소유자)"에게 한다 — 그래야 클라이언트가 로컬에 반영하는
    // 계정과 서버 기록이 항상 일치한다(다른 계정에 기록만 해두고 아무도 못 받는 상황 방지).
    // 불일치가 잦으면 이 로그를 근거로 "미수령 지급 인박스" 같은 별도 정산 기능을 고려할 것.
    if (result.accountUuid) {
      const owner = await pool.query('SELECT id FROM mfa_users WHERE iap_account_uuid = $1', [
        result.accountUuid,
      ]);
      if (owner.rows.length > 0 && owner.rows[0].id !== userId) {
        console.warn(
          `MFA iap: receipt-embedded owner ${owner.rows[0].id} != verifying JWT user ${userId} ` +
            `(txn ${transactionId}) — credited to JWT user per policy`
        );
      }
    }

    // 기록(transaction 중복 시 재지급 방지). 새로 들어온 경우만 inserted.
    const ins = await pool.query(
      `INSERT INTO mfa_purchases (user_id, platform, product_id, transaction_id, kind, verified, status, environment, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (platform, transaction_id) DO NOTHING
       RETURNING id`,
      [
        userId,
        platform,
        productId,
        transactionId,
        kind,
        result.verified,
        status,
        result.environment || null,
        JSON.stringify({ reason: result.reason || null }).slice(0, 4000),
      ]
    );
    const alreadyProcessed = ins.rows.length === 0;

    res.json({
      verified: result.verified,
      kind,
      // 이미 기록된 트랜잭션(재검증·재전달)이면 0 — 클라이언트가 매번 다시 지급하는 걸 막는다.
      coupons: alreadyProcessed ? 0 : (product?.coupons ?? 0),
      alreadyProcessed,
      reason: result.reason,
    });
  } catch (error) {
    console.error('MFA iap verify error:', error);
    res.status(500).json({ error: 'verify failed' });
  }
});

// GET /api/mathforadults/entitlements — 계정 기준 영구 엔타이틀먼트(광고 제거 등) 조회.
// 다른 기기에서 로그인했을 때 "이 계정은 이미 광고 제거를 샀었다"를 복원하는 용도.
router.get('/entitlements', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const r = await pool.query(
      `SELECT 1 FROM mfa_purchases WHERE user_id = $1 AND kind = 'remove_ads' AND verified = TRUE LIMIT 1`,
      [userId]
    );
    res.json({ adsRemoved: r.rows.length > 0 });
  } catch (error) {
    console.error('MFA get entitlements error:', error);
    res.status(500).json({ error: 'Failed to load entitlements' });
  }
});

export default router;
