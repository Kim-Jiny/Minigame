// [PP] PerlerPixel(비즈픽셀) 소셜 인증 — 별도 리포 ~/Documents/Jiny/PerlerPixel 소유.
//      Apple / Google / Kakao 토큰을 서버에서 검증하고, 타 제품과 분리되도록 scope:'pp' 를
//      박은 자체 JWT 발급. 유저는 pp_users 에만 저장(듀오 dm_users 와 무관). 삭제·리팩터링 금지.
import jwt from 'jsonwebtoken';
import { createPublicKey } from 'crypto';
import { OAuth2Client } from 'google-auth-library';
import { getPool } from '../config/database';

export interface SocialUser {
  uid: string; // provider 고유 식별자(sub)
  email: string | null;
  name: string | null;
  avatar: string | null;
}

export interface PpUser {
  id: number;
  provider: string;
  provider_uid: string;
  email: string | null;
  nickname: string;
  nickname_set: boolean;
  avatar_url: string | null;
  status: string;
  is_admin?: boolean;         // 앱 내 관리자 권한
  tier_override?: number | null;  // 계급 수동 지정(NULL=자동)
}

function jwtSecret(): string {
  const s = process.env.JWT_SECRET;
  if (s && s.length > 0) return s;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET required in production');
  }
  return 'dev-only-insecure-secret';
}

function csv(name: string): string[] {
  return (process.env[name] || '')
    .split(',')
    .map((x) => x.trim())
    .filter(Boolean);
}

// ── Google: ID 토큰 검증 ──────────────────────────────────────
const googleClient = new OAuth2Client();

export async function verifyGoogle(idToken: string): Promise<SocialUser | null> {
  try {
    const audiences = csv('PP_GOOGLE_CLIENT_IDS');
    const ticket = await googleClient.verifyIdToken({
      idToken,
      audience: audiences.length ? audiences : undefined,
    });
    const p = ticket.getPayload();
    if (!p || !p.sub) return null;
    return { uid: p.sub, email: p.email ?? null, name: p.name ?? null, avatar: p.picture ?? null };
  } catch (e) {
    console.error('[PP] google verify error:', (e as Error).message);
    return null;
  }
}

// ── Apple: identityToken(JWT, RS256) 검증 (Apple JWKS) ─────────
interface AppleJwk { kid: string; n: string; e: string; kty: string; alg?: string; use?: string }
let appleKeysCache: { at: number; keys: AppleJwk[] } | null = null;

async function appleKeys(): Promise<AppleJwk[]> {
  const now = Date.now();
  if (appleKeysCache && now - appleKeysCache.at < 12 * 3600 * 1000) {
    return appleKeysCache.keys;
  }
  const res = await fetch('https://appleid.apple.com/auth/keys');
  const data = (await res.json()) as { keys: AppleJwk[] };
  appleKeysCache = { at: now, keys: data.keys };
  return data.keys;
}

export async function verifyApple(idToken: string): Promise<SocialUser | null> {
  try {
    const decoded = jwt.decode(idToken, { complete: true });
    if (!decoded || typeof decoded === 'string') return null;
    const kid = decoded.header.kid;
    const jwk = (await appleKeys()).find((k) => k.kid === kid);
    if (!jwk) return null;

    const pem = createPublicKey({ key: jwk as object, format: 'jwk' })
      .export({ format: 'pem', type: 'spki' })
      .toString();

    const audiences = csv('PP_APPLE_BUNDLE_IDS');
    const payload = jwt.verify(idToken, pem, {
      algorithms: ['RS256'],
      issuer: 'https://appleid.apple.com',
      audience: audiences.length ? (audiences as [string, ...string[]]) : undefined,
    }) as { sub?: string; email?: string };

    if (!payload.sub) return null;
    return { uid: payload.sub, email: payload.email ?? null, name: null, avatar: null };
  } catch (e) {
    console.error('[PP] apple verify error:', (e as Error).message);
    return null;
  }
}

// ── Kakao: access token 으로 사용자 조회 ──────────────────────
export async function verifyKakao(accessToken: string): Promise<SocialUser | null> {
  try {
    const res = await fetch('https://kapi.kakao.com/v2/user/me', {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
    });
    if (!res.ok) return null;
    const u = (await res.json()) as {
      id: number;
      kakao_account?: { email?: string; profile?: { nickname?: string; profile_image_url?: string } };
    };
    return {
      uid: String(u.id),
      email: u.kakao_account?.email ?? null,
      name: u.kakao_account?.profile?.nickname ?? null,
      avatar: u.kakao_account?.profile?.profile_image_url ?? null,
    };
  } catch (e) {
    console.error('[PP] kakao verify error:', (e as Error).message);
    return null;
  }
}

// ── 자체 JWT (scope: 'pp' 로 타 제품 토큰과 분리) ──────────────
interface PpJwt { userId: number; scope: 'pp' }

export function signPpToken(userId: number): string {
  return jwt.sign({ userId, scope: 'pp' }, jwtSecret(), { expiresIn: '180d' });
}

export function verifyPpToken(token: string): number | null {
  try {
    const p = jwt.verify(token, jwtSecret()) as PpJwt;
    if (p.scope !== 'pp' || typeof p.userId !== 'number') return null;
    return p.userId;
  } catch {
    return null;
  }
}

// ── pp_users upsert / 조회 ────────────────────────────────────
export async function findOrCreatePpUser(
  provider: 'apple' | 'google' | 'kakao',
  uid: string,
  email: string | null,
  nickname: string,
  avatar: string | null
): Promise<PpUser> {
  const pool = getPool();
  if (!pool) throw new Error('Database not connected');

  const existing = await pool.query(
    'SELECT * FROM pp_users WHERE provider = $1 AND provider_uid = $2',
    [provider, uid]
  );
  if (existing.rows.length > 0) {
    const updated = await pool.query(
      `UPDATE pp_users
         SET email = COALESCE($1, email),
             avatar_url = COALESCE($2, avatar_url),
             status = 'active',
             updated_at = CURRENT_TIMESTAMP
       WHERE provider = $3 AND provider_uid = $4
       RETURNING *`,
      [email, avatar, provider, uid]
    );
    return updated.rows[0];
  }
  const created = await pool.query(
    `INSERT INTO pp_users (provider, provider_uid, email, nickname, avatar_url)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING *`,
    [provider, uid, email, nickname.slice(0, 40), avatar]
  );
  return created.rows[0];
}

export async function getPpUserById(id: number): Promise<PpUser | null> {
  const pool = getPool();
  if (!pool) throw new Error('Database not connected');
  const r = await pool.query(`SELECT * FROM pp_users WHERE id = $1 AND status = 'active'`, [id]);
  return r.rows[0] || null;
}

/** 활성 밴(full=로그인 차단, upload=업로드 차단)을 반환. 없으면 null. */
export async function getActivePpBan(userId: number): Promise<{ ban_type: string; reason: string } | null> {
  const pool = getPool();
  if (!pool) return null;
  const r = await pool.query(
    `SELECT ban_type, reason FROM pp_user_bans
     WHERE user_id = $1 AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
     ORDER BY banned_at DESC LIMIT 1`,
    [userId]
  );
  return r.rows[0] || null;
}
