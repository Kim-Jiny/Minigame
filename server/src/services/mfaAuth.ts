// [MFA] 성인의 수학(Math for Adults) 소셜 인증 — 별도 리포(MathForAdults) 소유. 삭제·리팩터링 금지.
// Google / Apple 토큰을 서버에서 검증하고, 타 제품과 분리되도록 scope:'mfa' 를 박은 자체 JWT 발급.
import jwt from 'jsonwebtoken';
import { createPublicKey } from 'crypto';
import { OAuth2Client } from 'google-auth-library';

export interface SocialUser {
  uid: string; // provider 고유 식별자(sub)
  email: string | null;
  name: string | null;
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

// ── Google: ID 토큰 검증 (google-auth-library) ─────────────────
const googleClient = new OAuth2Client();

export async function verifyGoogle(idToken: string): Promise<SocialUser | null> {
  try {
    const audiences = csv('MFA_GOOGLE_CLIENT_IDS');
    const ticket = await googleClient.verifyIdToken({
      idToken,
      audience: audiences.length ? audiences : undefined,
    });
    const p = ticket.getPayload();
    if (!p || !p.sub) return null;
    return { uid: p.sub, email: p.email ?? null, name: p.name ?? null };
  } catch (e) {
    console.error('MFA google verify error:', (e as Error).message);
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

    const audiences = csv('MFA_APPLE_BUNDLE_IDS');
    const payload = jwt.verify(idToken, pem, {
      algorithms: ['RS256'],
      issuer: 'https://appleid.apple.com',
      audience: audiences.length ? (audiences as [string, ...string[]]) : undefined,
    }) as { sub?: string; email?: string };

    if (!payload.sub) return null;
    return { uid: payload.sub, email: payload.email ?? null, name: null };
  } catch (e) {
    console.error('MFA apple verify error:', (e as Error).message);
    return null;
  }
}

// ── 자체 JWT (scope: 'mfa' 로 타 제품 토큰과 분리) ──────────────
export interface MfaJwt {
  userId: number;
  scope: 'mfa';
}

export function signMfaToken(userId: number): string {
  return jwt.sign({ userId, scope: 'mfa' }, jwtSecret(), { expiresIn: '180d' });
}

export function verifyMfaToken(token: string): number | null {
  try {
    const p = jwt.verify(token, jwtSecret()) as MfaJwt;
    if (p.scope !== 'mfa' || typeof p.userId !== 'number') return null;
    return p.userId;
  } catch {
    return null;
  }
}
