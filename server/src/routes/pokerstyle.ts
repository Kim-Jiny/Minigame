// [PS] PokerStyle(홀덤 성향 테스트) "남들이 본 나" 평가 API — 별도 리포 ~/Documents/Jiny/JinyShop 의
// /pokerstyle/ 웹도구가 호출한다. 삭제·리팩터링 금지. 소유권: 리포 루트 CLAUDE.md 의 [PS] 섹션.
//
// ── 프리픽스 ────────────────────────────────────────────────────────────────
//   DB 테이블 `ps_*` · 라우트 `/api/pokerstyle/*` · 환경변수 `PS_*` 만 이 파일이 소유한다.
//
// ── 권한 모델 (카카오 로그인 + 평가 링크) ───────────────────────────────────
//   OWNER  카카오로 로그인한 사용자. POST /auth/kakao 로 받은 JWT(scope:'ps')를
//          `Authorization: Bearer` 로 보낸다. 사용자당 프로필 1개(재테스트하면 갱신, 평가는 유지).
//          할 수 있는 것: 평가 링크(프로필) 생성·갱신, 본인 프로필의 집계 결과 조회, 프로필 삭제, 계정 탈퇴.
//   RATER  로그인 불필요. 프로필 공개 코드(id)만 알면 된다(친구에게 보낸 링크).
//          할 수 있는 것: 프로필 존재 확인, 평가 1회 제출.
//          할 수 없는 것: 오너의 응답·유형·평가 수·다른 평가자의 응답을 보는 것(편향 방지).
//   ANY    위 둘 외에는 아무것도 읽을 수 없다. 개별 평가 원본은 어떤 응답에도 내려가지 않는다.
//
// ── 개인정보 ───────────────────────────────────────────────────────────────
//   로그인 사용자: 카카오 회원번호(kakao_id)와 닉네임만 저장한다(이메일·프로필사진·연락처는 요청하지 않는다).
//   평가자: 이름·연락처·자유 입력 텍스트는 받지 않는다. 축별 점수(숫자), 관계(고정 선택지),
//          평가자 식별용 해시 2종(raterKey 해시, IP 해시 — 원문 저장 안 함)만 저장한다.
//   프로필·평가는 90일 후 삭제된다. 계정 탈퇴 시 ps_users 와 프로필·평가가 모두 삭제된다(CASCADE).
//
// ── 알려진 한계 ────────────────────────────────────────────────────────────
//   · 평가자가 3명 미만이면 집계를 내려주지 않는다. 다만 3명 이후 평가가 추가될 때마다 오너가
//     조회하면 평균 변화량으로 새 평가자의 값을 역산할 수 있다(익명성은 "명백한 식별 불가" 수준).
//   · 점수는 클라이언트가 계산해 보낸다 — 악의적 평가자의 값 조작은 서버가 막을 수 없다
//     (범위/형식 검증과 횟수 제한만 한다).
import { Router, Request, Response } from 'express';
import { createHash, randomBytes } from 'crypto';
import { getPool } from '../config/database';
import {
  allowedRedirects,
  kakaoConfigured,
  kakaoLoginWithCode,
  signPsToken,
  upsertPsUser,
  userFromRequest,
  PsUser,
} from '../services/psAuth';

const router = Router();

const AXES = 4; // 축 개수 (JinyShop/pokerstyle/pokerstyle-data.js PS_AXES 와 동일)
const QUESTIONS_PER_AXIS = 8; // 축당 문항 수
const MIN_ANSWERED_TOTAL = 8; // 평가자가 최소 이만큼은 "모름"이 아니어야 제출 가능
const MIN_RATERS_TO_REVEAL = 3; // 이 인원 미만이면 집계를 숨긴다
const PROFILE_TTL_DAYS = 90;
const MAX_RATINGS_PER_PROFILE = 200;
const MAX_RATINGS_PER_IP_PER_PROFILE = 3; // 같은 네트워크(가족·회사) 허용치
const RELATIONS = ['friend', 'table', 'family', 'online', 'other'] as const;
const FIRST_LETTERS = ['L', 'A', 'R', 'M']; // 각 축의 첫 번째 극 (p>50 이면 이쪽)
const SECOND_LETTERS = ['T', 'P', 'E', 'S'];

// ── 유틸 ─────────────────────────────────────────────────────────────────
function sha256(s: string): string {
  return createHash('sha256').update(s).digest('hex');
}

function hashSalt(): string {
  return process.env.PS_HASH_SALT || process.env.JWT_SECRET || 'ps-dev-salt';
}

// nginx 가 X-Forwarded-For 뒤에 실제 IP 를 덧붙이므로, 클라이언트가 위조 가능한 앞쪽이 아니라
// 가장 마지막 값을 쓴다. 헤더가 없으면 소켓 주소.
function clientIp(req: Request): string {
  const xff = req.headers['x-forwarded-for'];
  const raw = Array.isArray(xff) ? xff.join(',') : xff;
  if (raw) {
    const parts = raw.split(',').map((s) => s.trim()).filter(Boolean);
    if (parts.length) return parts[parts.length - 1];
  }
  return req.socket.remoteAddress || 'unknown';
}

function ipHash(req: Request): string {
  return sha256(hashSalt() + '|ip|' + clientIp(req));
}

// 공개 프로필 코드: 혼동되는 글자(0,O,1,I,L)를 뺀 32자 알파벳 10자리.
const ID_ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ_';
function newProfileId(): string {
  const bytes = randomBytes(10);
  let out = '';
  for (let i = 0; i < 10; i++) out += ID_ALPHABET[bytes[i] % 32];
  return out;
}

const ID_RE = /^[2-9A-HJKMNP-Z_]{10}$/;

// 메모리 기반 단순 레이트 리미터. 재시작하면 초기화되는 가벼운 방어선이다.
const buckets = new Map<string, { count: number; reset: number }>();
function limited(key: string, max: number, windowMs: number): boolean {
  const now = Date.now();
  const b = buckets.get(key);
  if (!b || b.reset < now) {
    buckets.set(key, { count: 1, reset: now + windowMs });
    if (buckets.size > 5000) {
      for (const [k, v] of buckets) if (v.reset < now) buckets.delete(k);
    }
    return false;
  }
  b.count++;
  return b.count > max;
}

function isPct(v: unknown): v is number {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= 100;
}

// 로그인 사용자 확인. 실패하면 401 을 응답하고 null.
async function requireUser(req: Request, res: Response): Promise<PsUser | null> {
  const user = await userFromRequest(req);
  if (!user) {
    res.status(401).json({ error: 'login required' });
    return null;
  }
  return user;
}

async function purgeExpired(): Promise<void> {
  try {
    await getPool().query(`DELETE FROM ps_profiles WHERE expires_at <= NOW()`);
  } catch (e) {
    console.error('[PS] purge error:', e);
  }
}

// ── POST /api/pokerstyle/auth/kakao — 카카오 인가 코드로 로그인 ───────────────
// body: { code, redirectUri }  → { token, user: { id, nickname } }
// redirectUri 는 PS_ALLOWED_REDIRECTS 에 있는 값만 허용한다.
router.post('/auth/kakao', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    if (!kakaoConfigured()) { res.status(503).json({ error: 'login not configured' }); return; }
    if (limited('ps:auth:' + ipHash(req), 30, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const code = req.body?.code;
    const redirectUri = req.body?.redirectUri;
    if (typeof code !== 'string' || code.length < 1 || code.length > 512) {
      res.status(400).json({ error: 'code required' });
      return;
    }
    if (typeof redirectUri !== 'string' || !allowedRedirects().includes(redirectUri)) {
      res.status(400).json({ error: 'redirectUri not allowed' });
      return;
    }
    const k = await kakaoLoginWithCode(code, redirectUri);
    if (!k) { res.status(401).json({ error: 'kakao login failed' }); return; }
    const user = await upsertPsUser(k.uid, k.nickname);
    res.json({ token: signPsToken(user.id), user: { id: user.id, nickname: user.nickname } });
  } catch (error) {
    console.error('[PS] kakao auth error:', error);
    res.status(500).json({ error: 'Failed to login' });
  }
});

// ── GET /api/pokerstyle/auth/me — [OWNER] 로그인 상태 확인 ────────────────────
router.get('/auth/me', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const user = await requireUser(req, res);
    if (!user) return;
    res.json({ user: { id: user.id, nickname: user.nickname } });
  } catch (error) {
    console.error('[PS] me error:', error);
    res.status(500).json({ error: 'Failed to load user' });
  }
});

// ── DELETE /api/pokerstyle/auth/me — [OWNER] 계정 탈퇴 (프로필·평가까지 CASCADE 삭제) ─
router.delete('/auth/me', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const user = await requireUser(req, res);
    if (!user) return;
    await getPool().query(`DELETE FROM ps_users WHERE id = $1`, [user.id]);
    res.json({ success: true });
  } catch (error) {
    console.error('[PS] delete account error:', error);
    res.status(500).json({ error: 'Failed to delete account' });
  }
});

// ── POST /api/pokerstyle/profiles — [OWNER] 평가 링크(프로필) 생성·갱신 ───────
// body: { pcts: [int×4] }  → { id, expiresAt }
// 사용자당 1개. 이미 있으면 본인 응답만 갱신하고 평가는 그대로 둔다(재테스트해도 평가 링크 유지).
// 유형 코드는 pcts 에서 서버가 직접 계산한다(클라이언트 값을 신뢰하지 않음).
router.post('/profiles', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const ip = ipHash(req);
    if (limited('ps:create:' + ip, 30, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const user = await requireUser(req, res);
    if (!user) return;
    const pcts = req.body?.pcts;
    if (!Array.isArray(pcts) || pcts.length !== AXES || !pcts.every(isPct)) {
      res.status(400).json({ error: 'pcts must be 4 integers 0-100' });
      return;
    }
    const code = pcts.map((p: number, i: number) => (p > 50 ? FIRST_LETTERS[i] : SECOND_LETTERS[i])).join('');
    const pool = getPool();
    const ttl = String(PROFILE_TTL_DAYS);

    const upd = await pool.query(
      `UPDATE ps_profiles SET code = $2, self_pcts = $3, expires_at = NOW() + ($4 || ' days')::interval
        WHERE owner_user_id = $1 RETURNING id, expires_at`,
      [user.id, code, pcts, ttl]
    );
    if (upd.rows[0]) {
      res.json({ id: upd.rows[0].id, expiresAt: upd.rows[0].expires_at });
      return;
    }

    for (let attempt = 0; attempt < 5; attempt++) {
      const id = newProfileId();
      try {
        const ins = await pool.query(
          `INSERT INTO ps_profiles (id, owner_user_id, code, self_pcts, creator_ip_hash, expires_at)
           VALUES ($1, $2, $3, $4, $5, NOW() + ($6 || ' days')::interval)
           RETURNING id, expires_at`,
          [id, user.id, code, pcts, ip, ttl]
        );
        void purgeExpired();
        res.json({ id: ins.rows[0].id, expiresAt: ins.rows[0].expires_at });
        return;
      } catch (e: any) {
        if (e?.code !== '23505') throw e;
        // 같은 사용자의 동시 요청이 먼저 만들었다면 그 프로필을 돌려준다. 아니면 id 충돌 → 재시도.
        const again = await pool.query(`SELECT id, expires_at FROM ps_profiles WHERE owner_user_id = $1`, [user.id]);
        if (again.rows[0]) { res.json({ id: again.rows[0].id, expiresAt: again.rows[0].expires_at }); return; }
      }
    }
    res.status(500).json({ error: 'Failed to create profile' });
  } catch (error) {
    console.error('[PS] create profile error:', error);
    res.status(500).json({ error: 'Failed to create profile' });
  }
});

// ── GET /api/pokerstyle/profiles/me/results — [OWNER] 내 프로필의 집계 결과 ───
// 평가자 3명 미만이면 others=null (인원 수만 노출). 프로필이 없으면 404.
// → { id, code, selfPcts, ratingCount, minToReveal, expiresAt, others: null | { axes:[{pct,answered,raters}], relations:{...} } }
router.get('/profiles/me/results', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    if (limited('ps:res:' + ipHash(req), 120, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const user = await requireUser(req, res);
    if (!user) return;
    const pr = await getPool().query(
      `SELECT id, code, self_pcts, expires_at FROM ps_profiles WHERE owner_user_id = $1 AND expires_at > NOW()`,
      [user.id]
    );
    const prof = pr.rows[0];
    if (!prof) { res.status(404).json({ error: 'no profile' }); return; }
    const r = await getPool().query(`SELECT relation, axes FROM ps_ratings WHERE profile_id = $1`, [prof.id]);
    const ratingCount = r.rows.length;
    let others: unknown = null;

    if (ratingCount >= MIN_RATERS_TO_REVEAL) {
      const sum = new Array(AXES).fill(0);
      const ans = new Array(AXES).fill(0);
      const raters = new Array(AXES).fill(0);
      const relations: Record<string, number> = {};
      for (const row of r.rows) {
        const key = row.relation || 'unknown';
        relations[key] = (relations[key] || 0) + 1;
        (row.axes as { p: number | null; n: number }[]).forEach((a, i) => {
          if (a.p !== null && a.n > 0) {
            sum[i] += a.p * a.n; // 많이 답한 평가자의 값에 가중
            ans[i] += a.n;
            raters[i] += 1;
          }
        });
      }
      others = {
        // raters 가 3 미만인 축은 pct 를 숨겨 "모름"이 많은 축이 소수 평가자를 노출하지 않게 한다.
        axes: sum.map((s, i) => ({
          pct: raters[i] >= MIN_RATERS_TO_REVEAL && ans[i] > 0 ? Math.round(s / ans[i]) : null,
          answered: ans[i],
          raters: raters[i],
        })),
        relations,
      };
    }

    res.json({
      id: prof.id,
      code: prof.code,
      selfPcts: prof.self_pcts,
      ratingCount,
      minToReveal: MIN_RATERS_TO_REVEAL,
      expiresAt: prof.expires_at,
      others,
    });
  } catch (error) {
    console.error('[PS] results error:', error);
    res.status(500).json({ error: 'Failed to load results' });
  }
});

// ── DELETE /api/pokerstyle/profiles/me — [OWNER] 내 프로필과 평가 전부 삭제 ───
// 계정은 유지된다(탈퇴는 DELETE /auth/me).
router.delete('/profiles/me', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const user = await requireUser(req, res);
    if (!user) return;
    await getPool().query(`DELETE FROM ps_profiles WHERE owner_user_id = $1`, [user.id]); // ps_ratings 는 CASCADE
    res.json({ success: true });
  } catch (error) {
    console.error('[PS] delete profile error:', error);
    res.status(500).json({ error: 'Failed to delete profile' });
  }
});

// ── GET /api/pokerstyle/profiles/:id — [RATER] 프로필 존재 확인 ──────────────
// 본인 응답·유형·평가 수는 내려주지 않는다. 링크가 유효한지만 알려준다.
router.get('/profiles/:id', async (req: Request, res: Response): Promise<void> => {
  try {
    const id = String(req.params.id);
    if (!ID_RE.test(id)) { res.status(404).json({ error: 'not found' }); return; }
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    if (limited('ps:get:' + ipHash(req), 120, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const r = await getPool().query(`SELECT 1 FROM ps_profiles WHERE id = $1 AND expires_at > NOW()`, [id]);
    if (!r.rows.length) { res.status(404).json({ error: 'not found' }); return; }
    res.json({ id, exists: true });
  } catch (error) {
    console.error('[PS] get profile error:', error);
    res.status(500).json({ error: 'Failed to get profile' });
  }
});

// ── POST /api/pokerstyle/profiles/:id/ratings — [RATER] 평가 제출 ───────────
// body: { raterKey: string(16~64, 기기 로컬 랜덤값), relation?: 'friend'|..., axes: [{p:int|null, n:int}×4] }
//   axes[i].p = 그 축에서 "모름"을 제외하고 계산한 첫 번째 극 퍼센트(0~100), n = 답한 문항 수(0~8).
//   n=0 이면 p 는 null.
router.post('/profiles/:id/ratings', async (req: Request, res: Response): Promise<void> => {
  try {
    const id = String(req.params.id);
    if (!ID_RE.test(id)) { res.status(404).json({ error: 'not found' }); return; }
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const ip = ipHash(req);
    if (limited('ps:rate:' + ip, 40, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }

    const body = req.body ?? {};
    const raterKey = typeof body.raterKey === 'string' ? body.raterKey : '';
    if (raterKey.length < 16 || raterKey.length > 64) {
      res.status(400).json({ error: 'raterKey must be 16-64 chars' });
      return;
    }
    const relation = body.relation == null ? null : String(body.relation);
    if (relation !== null && !(RELATIONS as readonly string[]).includes(relation)) {
      res.status(400).json({ error: 'invalid relation' });
      return;
    }
    const axes = body.axes;
    if (!Array.isArray(axes) || axes.length !== AXES) {
      res.status(400).json({ error: 'axes must have 4 entries' });
      return;
    }
    let answeredTotal = 0;
    const clean: { p: number | null; n: number }[] = [];
    for (const a of axes) {
      const n = a?.n;
      const p = a?.p;
      if (!Number.isInteger(n) || n < 0 || n > QUESTIONS_PER_AXIS) {
        res.status(400).json({ error: 'invalid n' });
        return;
      }
      if (n === 0 ? p !== null : !isPct(p)) {
        res.status(400).json({ error: 'invalid p' });
        return;
      }
      answeredTotal += n;
      clean.push({ p: n === 0 ? null : p, n });
    }
    if (answeredTotal < MIN_ANSWERED_TOTAL) {
      res.status(400).json({ error: 'too many unknown answers' });
      return;
    }

    const pool = getPool();
    const prof = await pool.query(`SELECT 1 FROM ps_profiles WHERE id = $1 AND expires_at > NOW()`, [id]);
    if (!prof.rows.length) { res.status(404).json({ error: 'not found' }); return; }

    const cnt = await pool.query(
      `SELECT COUNT(*)::int AS total, COUNT(*) FILTER (WHERE ip_hash = $2)::int AS same_ip
         FROM ps_ratings WHERE profile_id = $1`,
      [id, ip]
    );
    if (cnt.rows[0].total >= MAX_RATINGS_PER_PROFILE || cnt.rows[0].same_ip >= MAX_RATINGS_PER_IP_PER_PROFILE) {
      res.status(429).json({ error: 'rating limit reached' });
      return;
    }

    try {
      await pool.query(
        `INSERT INTO ps_ratings (profile_id, rater_key_hash, ip_hash, relation, axes)
         VALUES ($1, $2, $3, $4, $5)`,
        [id, sha256(hashSalt() + '|rk|' + raterKey), ip, relation, JSON.stringify(clean)]
      );
    } catch (e: any) {
      if (e?.code === '23505') { res.status(409).json({ error: 'already rated' }); return; }
      throw e;
    }
    res.json({ success: true });
  } catch (error) {
    console.error('[PS] create rating error:', error);
    res.status(500).json({ error: 'Failed to submit rating' });
  }
});

export default router;
