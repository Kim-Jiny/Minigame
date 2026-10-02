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

// POST /api/mathforadults/device-ping — 앱 시작 시 1회 호출(로그인 불필요, 게스트 포함).
// 어드민 DAU/WAU/MAU 통계용 — CatchTheRule의 ctr_devices/ctr_device_daily 패턴 미러링.
router.post('/device-ping', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }
    const deviceId = typeof req.body?.deviceId === 'string' ? req.body.deviceId.trim().slice(0, 64) : '';
    if (!deviceId) {
      res.status(400).json({ error: 'deviceId is required' });
      return;
    }
    const platform = req.body?.platform === 'ios' || req.body?.platform === 'android' ? req.body.platform : null;

    await pool.query(
      `INSERT INTO mfa_devices (device_id, platform)
       VALUES ($1, $2)
       ON CONFLICT (device_id) DO UPDATE SET
         platform = COALESCE(EXCLUDED.platform, mfa_devices.platform),
         launch_count = mfa_devices.launch_count + 1,
         last_seen = CURRENT_TIMESTAMP`,
      [deviceId, platform]
    );
    await pool.query(
      `INSERT INTO mfa_device_daily (device_id, day, platform)
       VALUES ($1, CURRENT_DATE, $2)
       ON CONFLICT (device_id, day) DO NOTHING`,
      [deviceId, platform]
    );
    res.json({ success: true });
  } catch (error) {
    console.error('MFA device ping error:', error);
    res.status(500).json({ error: 'Failed to ping' });
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

// 로그인 없이도 쓸 수 있는 라우트(IAP 영수증 검증 등 — App Store Review Guideline
// 5.1.1(v): 계정과 무관한 상품 구매에 로그인을 강제할 수 없음)에 쓴다. 토큰 자체가
// 없으면 게스트로 보고 null(정상), 토큰은 있는데 무효/만료면 401 응답하고
// undefined(호출부가 이 값이면 바로 return) — mfaAuth()와 달리 "토큰 없음"은
// 에러로 취급하지 않는다.
function mfaAuthOptional(req: Request, res: Response): number | null | undefined {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) return null;
  const userId = verifyMfaToken(h.slice(7));
  if (userId === null) {
    res.status(401).json({ error: 'Invalid token' });
    return undefined;
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
//   resp: { verified, kind, coupons, alreadyProcessed, balance }
// 로그인은 선택(Bearer 없어도 됨) — App Store Review Guideline 5.1.1(v): 계정과
// 무관한 상품(힌트쿠폰/광고제거) 구매에 로그인을 강제할 수 없다. 로그인 상태면
// 기존처럼 서버 계정 잔액(mfa_users.hint_coupon_balance)에 반영하고 그 최종값을
// balance로 내려주고(클라이언트는 로컬에 증분을 더하지 않고 이 값을 그대로 신뢰),
// 로그인 안 된 요청(토큰 없음)은 게스트로 보고 검증 결과(coupons 증분량)만 내려준다
// — 계정 잔액은 안 건드리고, 클라이언트가 이 기기에만 로컬로 반영한다.
router.post('/iap/verify', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuthOptional(req, res);
  if (userId === undefined) return;
  const pool = getPool();
  if (!pool) {
    res.status(500).json({ error: 'Database not available' });
    return;
  }
  try {
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
    if (userId !== null && result.accountUuid) {
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

    // 거래 기록(mfa_purchases)과 힌트쿠폰 잔액 증가를 한 트랜잭션으로 묶는다 — 따로
    // 커밋되면 커넥션이 중간에 끊겼을 때 "이미 처리됨"으로 기록만 남고 지급은 영영 안
    // 되는 사고가 날 수 있다(server/src/services/shopService.ts의 BEGIN/COMMIT 패턴과 동일).
    const client = await pool.connect();
    let alreadyProcessed: boolean;
    let balance: number | undefined;
    try {
      await client.query('BEGIN');
      // 기록(transaction 중복 시 재지급 방지). 새로 들어온 경우만 inserted.
      const ins = await client.query(
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
      alreadyProcessed = ins.rows.length === 0;

      // 로그인 계정(userId != null)이면 힌트쿠폰을 서버 계정 잔액에 원자적으로 반영하고
      // 그 최종값(balance)을 내려준다 — 클라이언트는 이 값을 그대로 신뢰해서 덮어쓴다.
      // (로컬 병합(max merge) 기반이던 예전 방식의 "로그아웃 후 소모→재로그인 시 부활" 버그를
      // 원천 차단하기 위함.) 이미 처리된 재검증이어도 최신 잔액을 함께 돌려줘 클라이언트
      // 상태가 서버와 어긋나지 않게 한다.
      // 게스트(userId == null)는 서버 잔액 개념이 없음 — balance는 응답에 안 실리고
      // (undefined), 클라이언트가 응답의 coupons(증분량)를 이 기기 로컬에만 반영한다.
      if (kind === 'hint_coupons' && userId !== null) {
        if (!alreadyProcessed && result.verified && product?.coupons) {
          const upd = await client.query(
            'UPDATE mfa_users SET hint_coupon_balance = hint_coupon_balance + $2 WHERE id = $1 RETURNING hint_coupon_balance',
            [userId, product.coupons]
          );
          balance = upd.rows[0]?.hint_coupon_balance;
          await client.query(
            `INSERT INTO mfa_coupon_log (user_id, delta, reason, balance_after) VALUES ($1, $2, 'purchase', $3)`,
            [userId, product.coupons, balance]
          );
        } else {
          const bal = await client.query('SELECT hint_coupon_balance FROM mfa_users WHERE id = $1', [userId]);
          balance = bal.rows[0]?.hint_coupon_balance ?? 0;
        }
      }
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }

    res.json({
      verified: result.verified,
      kind,
      // 이미 기록된 트랜잭션(재검증·재전달)이면 0 — 클라이언트가 매번 다시 지급하는 걸 막는다.
      coupons: alreadyProcessed ? 0 : (product?.coupons ?? 0),
      alreadyProcessed,
      reason: result.reason,
      balance,
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
    const bal = await pool.query('SELECT hint_coupon_balance FROM mfa_users WHERE id = $1', [userId]);
    res.json({ adsRemoved: r.rows.length > 0, hintCoupons: bal.rows[0]?.hint_coupon_balance ?? 0 });
  } catch (error) {
    console.error('MFA get entitlements error:', error);
    res.status(500).json({ error: 'Failed to load entitlements' });
  }
});

// POST /api/mathforadults/hint-coupons/checkin — 계정당 하루 1회 출석 쿠폰 지급(로그인 필수).
// 기기 로컬 출석 체크와 별개로, 쿠폰 지급 자체는 이 서버 호출이 유일한 진실 — 두 기기로
// 각각 눌러도 하루 한 번만 지급된다(mfa_checkins PK(user_id, day) 충돌로 보장).
router.post('/hint-coupons/checkin', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  const pool = getPool();
  if (!pool) {
    res.status(500).json({ error: 'Database not available' });
    return;
  }
  // 출석 기록(mfa_checkins)과 잔액 증가를 한 트랜잭션으로 묶는다 — 따로 커밋되면
  // 커넥션이 중간에 끊겼을 때 "오늘 이미 출석함"만 영구히 남고 쿠폰은 영영 안 받는
  // 사고가 날 수 있다(server/src/services/shopService.ts의 BEGIN/COMMIT 패턴과 동일).
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const ins = await client.query(
      `INSERT INTO mfa_checkins (user_id, day)
       VALUES ($1, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date)
       ON CONFLICT (user_id, day) DO NOTHING
       RETURNING day`,
      [userId]
    );
    if (ins.rows.length === 0) {
      const bal = await client.query('SELECT hint_coupon_balance FROM mfa_users WHERE id = $1', [userId]);
      await client.query('COMMIT');
      res.json({ granted: false, balance: bal.rows[0]?.hint_coupon_balance ?? 0 });
      return;
    }
    const upd = await client.query(
      'UPDATE mfa_users SET hint_coupon_balance = hint_coupon_balance + 1 WHERE id = $1 RETURNING hint_coupon_balance',
      [userId]
    );
    await client.query(
      `INSERT INTO mfa_coupon_log (user_id, delta, reason, balance_after) VALUES ($1, 1, 'checkin', $2)`,
      [userId, upd.rows[0].hint_coupon_balance]
    );
    await client.query('COMMIT');
    res.json({ granted: true, balance: upd.rows[0].hint_coupon_balance });
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('MFA checkin error:', error);
    res.status(500).json({ error: 'checkin failed' });
  } finally {
    client.release();
  }
});

// POST /api/mathforadults/hint-coupons/spend — 힌트쿠폰 1개 원자적 차감(로그인 필수).
// WHERE 절에 잔액 조건을 같이 걸어서 음수로 내려가는 걸 DB 레벨에서 막는다(동시 요청 안전).
router.post('/hint-coupons/spend', async (req: Request, res: Response): Promise<void> => {
  const userId = mfaAuth(req, res);
  if (userId === null) return;
  const pool = getPool();
  if (!pool) {
    res.status(500).json({ error: 'Database not available' });
    return;
  }
  // 잔액 차감 + 운영 로그 기록(mfa_coupon_log)을 한 트랜잭션으로 묶는다 — 로그 INSERT가
  // 추가되면서 두 문장이 됐으니, checkin/iap-verify와 동일하게 BEGIN/COMMIT으로 보호한다.
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const upd = await client.query(
      `UPDATE mfa_users SET hint_coupon_balance = hint_coupon_balance - 1
       WHERE id = $1 AND hint_coupon_balance > 0
       RETURNING hint_coupon_balance`,
      [userId]
    );
    if (upd.rows.length === 0) {
      await client.query('COMMIT');
      res.status(409).json({ success: false, error: 'insufficient_balance' });
      return;
    }
    await client.query(
      `INSERT INTO mfa_coupon_log (user_id, delta, reason, balance_after) VALUES ($1, -1, 'spend', $2)`,
      [userId, upd.rows[0].hint_coupon_balance]
    );
    await client.query('COMMIT');
    res.json({ success: true, balance: upd.rows[0].hint_coupon_balance });
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('MFA spend hint coupon error:', error);
    res.status(500).json({ error: 'spend failed' });
  } finally {
    client.release();
  }
});

export default router;
