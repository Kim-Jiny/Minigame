// [PS] PokerStyle(홀덤 성향 테스트) "남들이 본 나" 평가 API — 별도 리포 ~/Documents/Jiny/JinyShop 의
// /pokerstyle/ 웹도구가 호출한다. 삭제·리팩터링 금지. 소유권: 리포 루트 CLAUDE.md 의 [PS] 섹션.
//
// ── 프리픽스 ────────────────────────────────────────────────────────────────
//   DB 테이블 `ps_*` · 라우트 `/api/pokerstyle/*` · 환경변수 `PS_*` 만 이 파일이 소유한다.
//
// ── 권한 모델 (로그인 없음, 토큰 기반) ─────────────────────────────────────
//   OWNER  프로필 생성자. 생성 응답으로 받은 ownerToken(64hex, 서버에는 SHA-256 해시만 저장)을
//          `X-Owner-Token` 헤더로 보낸다. 할 수 있는 것: 본인 프로필의 집계 결과 조회, 프로필 삭제.
//   RATER  프로필 공개 코드(id)만 아는 누구나. 할 수 있는 것: 프로필 존재 확인, 평가 1회 제출.
//          할 수 없는 것: 본인 응답(selfPcts)·유형·다른 평가자의 응답을 보는 것(편향 방지).
//   ANY    위 둘 외에는 아무것도 읽을 수 없다. 개별 평가 원본은 어떤 응답에도 내려가지 않는다.
//
// ── 개인정보 ───────────────────────────────────────────────────────────────
//   이름·연락처·자유 입력 텍스트는 받지 않는다. 저장하는 것: 축별 점수(숫자), 관계(고정 선택지),
//   평가자 식별용 해시 2종(raterKey 해시, IP 해시 — 원문 저장 안 함). 프로필은 90일 후 삭제된다.
//
// ── 알려진 한계 ────────────────────────────────────────────────────────────
//   · 평가자가 3명 미만이면 집계를 내려주지 않는다. 다만 3명 이후 평가가 추가될 때마다 오너가
//     조회하면 평균 변화량으로 새 평가자의 값을 역산할 수 있다(익명성은 "명백한 식별 불가" 수준).
//   · 점수는 클라이언트가 계산해 보낸다 — 악의적 평가자의 값 조작은 서버가 막을 수 없다
//     (범위/형식 검증과 횟수 제한만 한다).
import { Router, Request, Response } from 'express';
import { createHash, randomBytes, timingSafeEqual } from 'crypto';
import { getPool } from '../config/database';

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

// 소유자 토큰 검증. 성공 시 프로필 행을 돌려준다.
async function authOwner(req: Request, res: Response, id: string) {
  const pool = getPool();
  const token = req.header('x-owner-token') || '';
  if (!/^[0-9a-f]{64}$/.test(token)) {
    res.status(401).json({ error: 'owner token required' });
    return null;
  }
  const r = await pool.query(
    `SELECT id, code, self_pcts, owner_token_hash, created_at, expires_at
       FROM ps_profiles WHERE id = $1 AND expires_at > NOW()`,
    [id]
  );
  const row = r.rows[0];
  const given = Buffer.from(sha256(token), 'hex');
  const stored = row ? Buffer.from(row.owner_token_hash, 'hex') : Buffer.alloc(32);
  const ok = row && given.length === stored.length && timingSafeEqual(given, stored);
  if (!ok) {
    // 존재 여부를 흘리지 않도록 같은 응답.
    res.status(404).json({ error: 'not found' });
    return null;
  }
  return row;
}

async function purgeExpired(): Promise<void> {
  try {
    await getPool().query(`DELETE FROM ps_profiles WHERE expires_at <= NOW()`);
  } catch (e) {
    console.error('[PS] purge error:', e);
  }
}

// ── POST /api/pokerstyle/profiles — [OWNER 생성] 본인 결과로 프로필 생성 ─────
// body: { pcts: [int×4] }  → { id, ownerToken, expiresAt }
// 유형 코드는 pcts 에서 서버가 직접 계산한다(클라이언트 값을 신뢰하지 않음).
router.post('/profiles', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const ip = ipHash(req);
    if (limited('ps:create:' + ip, 10, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const pcts = req.body?.pcts;
    if (!Array.isArray(pcts) || pcts.length !== AXES || !pcts.every(isPct)) {
      res.status(400).json({ error: 'pcts must be 4 integers 0-100' });
      return;
    }
    const code = pcts.map((p: number, i: number) => (p > 50 ? FIRST_LETTERS[i] : SECOND_LETTERS[i])).join('');
    const ownerToken = randomBytes(32).toString('hex');

    let id = '';
    for (let attempt = 0; attempt < 5; attempt++) {
      id = newProfileId();
      try {
        await getPool().query(
          `INSERT INTO ps_profiles (id, owner_token_hash, code, self_pcts, creator_ip_hash, expires_at)
           VALUES ($1, $2, $3, $4, $5, NOW() + ($6 || ' days')::interval)`,
          [id, sha256(ownerToken), code, pcts, ip, String(PROFILE_TTL_DAYS)]
        );
        break;
      } catch (e: any) {
        if (e?.code === '23505' && attempt < 4) continue; // id 충돌 → 재시도
        throw e;
      }
    }
    void purgeExpired();
    const exp = await getPool().query(`SELECT expires_at FROM ps_profiles WHERE id = $1`, [id]);
    res.json({ id, ownerToken, expiresAt: exp.rows[0]?.expires_at });
  } catch (error) {
    console.error('[PS] create profile error:', error);
    res.status(500).json({ error: 'Failed to create profile' });
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

// ── GET /api/pokerstyle/profiles/:id/results — [OWNER] 집계 결과 ─────────────
// 헤더 X-Owner-Token 필수. 평가자 3명 미만이면 others=null (인원 수만 노출).
// → { code, selfPcts, ratingCount, minToReveal, expiresAt, others: null | { axes:[{pct,answered,raters}], relations:{...} } }
router.get('/profiles/:id/results', async (req: Request, res: Response): Promise<void> => {
  try {
    const id = String(req.params.id);
    if (!ID_RE.test(id)) { res.status(404).json({ error: 'not found' }); return; }
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    if (limited('ps:res:' + ipHash(req), 120, 60 * 60 * 1000)) {
      res.status(429).json({ error: 'too many requests' });
      return;
    }
    const prof = await authOwner(req, res, id);
    if (!prof) return;

    const r = await getPool().query(`SELECT relation, axes FROM ps_ratings WHERE profile_id = $1`, [id]);
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

// ── DELETE /api/pokerstyle/profiles/:id — [OWNER] 프로필과 평가 전부 삭제 ────
router.delete('/profiles/:id', async (req: Request, res: Response): Promise<void> => {
  try {
    const id = String(req.params.id);
    if (!ID_RE.test(id)) { res.status(404).json({ error: 'not found' }); return; }
    if (!getPool()) { res.status(500).json({ error: 'Database not available' }); return; }
    const prof = await authOwner(req, res, id);
    if (!prof) return;
    await getPool().query(`DELETE FROM ps_profiles WHERE id = $1`, [id]); // ps_ratings 는 CASCADE
    res.json({ success: true });
  } catch (error) {
    console.error('[PS] delete profile error:', error);
    res.status(500).json({ error: 'Failed to delete profile' });
  }
});

export default router;
