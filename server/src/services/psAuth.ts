// [PS] PokerStyle(홀덤 성향 테스트) 카카오 로그인 — 별도 리포 ~/Documents/Jiny/JinyShop 소유.
//      웹(jiny.shop)이 카카오 인가 코드를 받아 오면 서버가 직접 토큰 교환·사용자 조회를 하고,
//      타 제품과 분리되도록 scope:'ps' 를 박은 자체 JWT 를 발급한다. 유저는 ps_users 에만 저장한다.
//      삭제·리팩터링 금지. 소유권: 리포 루트 CLAUDE.md 의 [PS] 섹션.
//
// 환경변수 (모두 PS_ 프리픽스)
//   PS_KAKAO_REST_KEY       카카오 디벨로퍼스 앱의 REST API 키 (필수)
//   PS_KAKAO_CLIENT_SECRET  카카오 로그인 > 보안 의 Client Secret (사용 설정한 경우)
//   PS_ALLOWED_REDIRECTS    허용할 리다이렉트 URI 목록(콤마). 기본 https://jiny.shop/pokerstyle/
//   PS_KAKAO_AUTH_BASE / PS_KAKAO_API_BASE  테스트에서 가짜 카카오 서버로 바꾸기 위한 값. 운영에서는 설정하지 않는다.
import jwt from 'jsonwebtoken';
import { Request } from 'express';
import { getPool } from '../config/database';

export interface PsUser {
  id: number;
  nickname: string | null;
}

function jwtSecret(): string {
  const s = process.env.JWT_SECRET;
  if (s && s.length > 0) return s;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET required in production');
  }
  return 'dev-only-insecure-secret';
}

function authBase(): string {
  return (process.env.PS_KAKAO_AUTH_BASE || 'https://kauth.kakao.com').replace(/\/$/, '');
}
function apiBase(): string {
  return (process.env.PS_KAKAO_API_BASE || 'https://kapi.kakao.com').replace(/\/$/, '');
}

export function allowedRedirects(): string[] {
  const raw = process.env.PS_ALLOWED_REDIRECTS || 'https://jiny.shop/pokerstyle/';
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

export function kakaoConfigured(): boolean {
  return !!process.env.PS_KAKAO_REST_KEY;
}

// ── 카카오: 인가 코드 → 액세스 토큰 → 사용자 정보 ───────────────────────────
// 실패(코드 만료·재사용·리다이렉트 불일치 등)하면 null.
export async function kakaoLoginWithCode(
  code: string,
  redirectUri: string
): Promise<{ uid: string; nickname: string | null } | null> {
  try {
    const form = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: process.env.PS_KAKAO_REST_KEY || '',
      redirect_uri: redirectUri,
      code,
    });
    if (process.env.PS_KAKAO_CLIENT_SECRET) form.set('client_secret', process.env.PS_KAKAO_CLIENT_SECRET);

    const tokenRes = await fetch(`${authBase()}/oauth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8' },
      body: form.toString(),
      signal: AbortSignal.timeout(8000),
    });
    if (!tokenRes.ok) {
      console.error('[PS] kakao token exchange failed:', tokenRes.status);
      return null;
    }
    const tokenJson = (await tokenRes.json()) as { access_token?: string };
    if (!tokenJson.access_token) return null;

    const meRes = await fetch(`${apiBase()}/v2/user/me`, {
      headers: { Authorization: `Bearer ${tokenJson.access_token}` },
      signal: AbortSignal.timeout(8000),
    });
    if (!meRes.ok) {
      console.error('[PS] kakao user/me failed:', meRes.status);
      return null;
    }
    const u = (await meRes.json()) as {
      id?: number | string;
      properties?: { nickname?: string };
      kakao_account?: { profile?: { nickname?: string } };
    };
    if (u.id === undefined || u.id === null) return null;
    const nick = u.kakao_account?.profile?.nickname ?? u.properties?.nickname ?? null;
    return { uid: String(u.id), nickname: nick ? nick.slice(0, 40) : null };
  } catch (e) {
    console.error('[PS] kakao login error:', (e as Error).message);
    return null;
  }
}

// ── 자체 JWT (scope: 'ps' 로 타 제품 토큰과 분리) ─────────────────────────
interface PsJwt { userId: number; scope: 'ps' }

export function signPsToken(userId: number): string {
  return jwt.sign({ userId, scope: 'ps' }, jwtSecret(), { expiresIn: '60d' });
}

export function verifyPsToken(token: string): number | null {
  try {
    const p = jwt.verify(token, jwtSecret()) as PsJwt;
    return p.scope === 'ps' && Number.isInteger(p.userId) ? p.userId : null;
  } catch {
    return null;
  }
}

export function bearerToken(req: Request): string | null {
  const h = req.headers.authorization;
  return h && h.startsWith('Bearer ') ? h.slice(7) : null;
}

// 카카오 uid 로 ps_users upsert. 닉네임은 최신 값으로 갱신한다.
export async function upsertPsUser(uid: string, nickname: string | null): Promise<PsUser> {
  const r = await getPool().query(
    `INSERT INTO ps_users (kakao_id, nickname) VALUES ($1, $2)
     ON CONFLICT (kakao_id) DO UPDATE SET nickname = COALESCE(EXCLUDED.nickname, ps_users.nickname), last_login_at = NOW()
     RETURNING id, nickname`,
    [uid, nickname]
  );
  return r.rows[0];
}

// Bearer 토큰에서 로그인 유저를 읽는다. 토큰이 유효해도 계정이 삭제됐다면 null.
export async function userFromRequest(req: Request): Promise<PsUser | null> {
  const token = bearerToken(req);
  if (!token) return null;
  const userId = verifyPsToken(token);
  if (!userId) return null;
  const r = await getPool().query(`SELECT id, nickname FROM ps_users WHERE id = $1`, [userId]);
  return r.rows[0] ?? null;
}
