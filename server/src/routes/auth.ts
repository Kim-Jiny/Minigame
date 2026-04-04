import { Router, Request, Response } from 'express';
import { OAuth2Client } from 'google-auth-library';
import jwt from 'jsonwebtoken';
import { createPublicKey } from 'crypto';
import { findOrCreateUser, updateNickname, deleteUser, findUserById, assertUserNotBanned } from '../services/userService';
import { generateToken, verifyToken } from '../utils/jwt';

const router = Router();
const GOOGLE_VERIFY_TIMEOUT_MS = 8000;
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_AUDIENCES = [
  process.env.APPLE_CLIENT_ID,
  process.env.APPLE_BUNDLE_ID,
  'com.minigame.minigameApp',
].filter(Boolean) as string[];

let appleKeysCache:
  | {
      expiresAt: number;
      keys: Array<Record<string, unknown>>;
    }
  | null = null;

// Google OAuth Client
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), timeoutMs);

    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

async function getAppleSigningKeys(): Promise<Array<Record<string, unknown>>> {
  const now = Date.now();
  if (appleKeysCache && appleKeysCache.expiresAt > now) {
    return appleKeysCache.keys;
  }

  const response = await withTimeout(
    fetch(APPLE_JWKS_URL),
    GOOGLE_VERIFY_TIMEOUT_MS,
    'Apple signing key fetch timed out'
  );

  if (!response.ok) {
    throw new Error('Failed to fetch Apple signing keys');
  }

  const data = (await response.json()) as { keys?: Array<Record<string, unknown>> };
  const keys = data.keys ?? [];
  if (keys.length === 0) {
    throw new Error('Apple signing keys are unavailable');
  }

  appleKeysCache = {
    keys,
    expiresAt: now + 60 * 60 * 1000,
  };

  return keys;
}

async function verifyAppleIdToken(idToken: string): Promise<{ sub: string; email?: string }> {
  if (APPLE_AUDIENCES.length === 0) {
    throw new Error('Apple auth is not configured');
  }

  const decoded = jwt.decode(idToken, { complete: true }) as
    | { header?: { kid?: string; alg?: string } }
    | null;
  const kid = decoded?.header?.kid;
  const alg = decoded?.header?.alg;

  if (!kid || alg !== 'RS256') {
    throw new Error('Invalid Apple token header');
  }

  const keys = await getAppleSigningKeys();
  const jwk = keys.find((key) => key.kid === kid && key.alg === alg);
  if (!jwk) {
    throw new Error('Matching Apple signing key not found');
  }

  const publicKey = createPublicKey({
    key: jwk as any,
    format: 'jwk',
  });

  const payload = jwt.verify(idToken, publicKey, {
    algorithms: ['RS256'],
    issuer: APPLE_ISSUER,
    audience: APPLE_AUDIENCES as any,
  }) as { sub?: string; email?: string };

  if (!payload.sub) {
    throw new Error('Invalid Apple token payload');
  }

  return {
    sub: payload.sub,
    email: payload.email,
  };
}

// POST /api/auth/google - Google 로그인
router.post('/google', async (req: Request, res: Response): Promise<void> => {
  try {
    const { idToken } = req.body;
    const audiences = [
      process.env.GOOGLE_CLIENT_ID,
      process.env.GOOGLE_IOS_CLIENT_ID,
    ].filter(Boolean) as string[];

    if (!idToken) {
      res.status(400).json({ error: 'idToken is required' });
      return;
    }

    if (audiences.length === 0) {
      console.error('Google auth error: GOOGLE_CLIENT_ID / GOOGLE_IOS_CLIENT_ID is not configured');
      res.status(500).json({ error: 'Google auth is not configured' });
      return;
    }

    console.log('Google auth: verifying idToken', {
      audienceCount: audiences.length,
      audiences,
      env: process.env.NODE_ENV,
    });

    let providerId: string;
    let email: string | undefined;
    let name: string | undefined;
    let picture: string | undefined;

    if (process.env.NODE_ENV === 'development') {
      // 개발 환경: Google 서버 검증 건너뛰고 토큰 디코딩만
      const decoded = jwt.decode(idToken) as any;
      if (!decoded || !decoded.sub) {
        res.status(401).json({ error: 'Invalid token' });
        return;
      }
      providerId = decoded.sub;
      email = decoded.email;
      name = decoded.name;
      picture = decoded.picture;
      console.log('Google auth: dev mode - skipped verification');
    } else {
      // 프로덕션: Google 서버로 정식 검증
      const ticket = await withTimeout(
        googleClient.verifyIdToken({
          idToken,
          audience: audiences,
        }),
        GOOGLE_VERIFY_TIMEOUT_MS,
        'Google ID token verification timed out'
      );

      const payload = ticket.getPayload();
      if (!payload) {
        res.status(401).json({ error: 'Invalid token' });
        return;
      }

      providerId = payload.sub!;
      email = payload.email;
      name = payload.name;
      picture = payload.picture;
    }

    // 사용자 생성 또는 조회
    const user = await findOrCreateUser(
      'google',
      providerId!,
      email || null,
      name || email?.split('@')[0] || 'User',
      picture || null
    );
    await assertUserNotBanned(user.id);

    // JWT 발급
    const token = generateToken(user.id);

    res.json({
      token,
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Google auth error:', error);
    const message = error instanceof Error ? error.message : 'Authentication failed';
    const statusCode = message.includes('banned')
      ? 403
      : message.includes('timed out')
        ? 504
        : 401;
    res.status(statusCode).json({ error: message });
  }
});

// POST /api/auth/apple - Apple 로그인
router.post('/apple', async (req: Request, res: Response): Promise<void> => {
  try {
    const { idToken, user: appleUser } = req.body;

    if (!idToken) {
      res.status(400).json({ error: 'idToken is required' });
      return;
    }

    const decoded = await verifyAppleIdToken(idToken);

    // Apple은 최초 로그인시에만 사용자 정보를 제공
    const email = decoded.email || appleUser?.email || null;
    const name = appleUser?.name?.firstName
      ? `${appleUser.name.firstName} ${appleUser.name.lastName || ''}`.trim()
      : null;

    // 사용자 생성 또는 조회
    const user = await findOrCreateUser(
      'apple',
      decoded.sub,
      email,
      name || email?.split('@')[0] || 'Apple User',
      null
    );
    await assertUserNotBanned(user.id);

    // JWT 발급
    const token = generateToken(user.id);

    res.json({
      token,
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Apple auth error:', error);
    const message = error instanceof Error ? error.message : 'Authentication failed';
    const statusCode = message.includes('banned') ? 403 : 401;
    res.status(statusCode).json({ error: message });
  }
});

// POST /api/auth/kakao - Kakao 로그인
router.post('/kakao', async (req: Request, res: Response): Promise<void> => {
  try {
    const { accessToken } = req.body;

    if (!accessToken) {
      res.status(400).json({ error: 'accessToken is required' });
      return;
    }

    // Kakao API로 사용자 정보 조회
    const kakaoResponse = await fetch('https://kapi.kakao.com/v2/user/me', {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
    });

    if (!kakaoResponse.ok) {
      res.status(401).json({ error: 'Invalid Kakao token' });
      return;
    }

    const kakaoUser = (await kakaoResponse.json()) as {
      id: number;
      kakao_account?: {
        email?: string;
        profile?: {
          nickname?: string;
          profile_image_url?: string;
        };
      };
    };

    const providerId = String(kakaoUser.id);
    const email = kakaoUser.kakao_account?.email || null;
    const nickname = kakaoUser.kakao_account?.profile?.nickname || email?.split('@')[0] || `유저${providerId.slice(-6)}`;
    const avatarUrl = kakaoUser.kakao_account?.profile?.profile_image_url || null;

    // 사용자 생성 또는 조회
    const user = await findOrCreateUser('kakao', providerId, email, nickname, avatarUrl);
    await assertUserNotBanned(user.id);

    // JWT 발급
    const token = generateToken(user.id);

    res.json({
      token,
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Kakao auth error:', error);
    const message = error instanceof Error ? error.message : 'Authentication failed';
    const statusCode = message.includes('banned') ? 403 : 401;
    res.status(statusCode).json({ error: message });
  }
});

// POST /api/auth/test - 심사용 테스트 로그인
router.post('/test', async (req: Request, res: Response): Promise<void> => {
  try {
    const { nickname } = req.body;

    if (nickname !== 'appletest12') {
      res.status(401).json({ error: 'Invalid test account' });
      return;
    }

    // 심사용 계정: user_id = 1 (apple provider)
    const { getPool } = require('../config/database');
    const pool = getPool();
    const result = await pool.query('SELECT * FROM dm_users WHERE id = 1');

    if (result.rows.length === 0) {
      res.status(404).json({ error: 'Test account not found' });
      return;
    }

    const user = result.rows[0];
    await assertUserNotBanned(user.id);
    const token = generateToken(user.id);

    res.json({
      token,
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Test auth error:', error);
    const message = error instanceof Error ? error.message : 'Test login failed';
    const statusCode = message.includes('banned') ? 403 : 500;
    res.status(statusCode).json({ error: message });
  }
});

// GET /api/auth/me - 토큰 검증 및 현재 사용자 조회
router.get('/me', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const user = await findUserById(payload.userId);
    if (!user) {
      res.status(404).json({ error: 'User not found' });
      return;
    }
    await assertUserNotBanned(user.id);

    res.json({
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Get current user error:', error);
    const message = error instanceof Error ? error.message : 'Failed to fetch current user';
    const statusCode = message.includes('banned') ? 403 : 500;
    res.status(statusCode).json({ error: message });
  }
});

// PUT /api/auth/nickname - 닉네임 변경
router.put('/nickname', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const { nickname } = req.body;

    if (!nickname || typeof nickname !== 'string') {
      res.status(400).json({ error: 'nickname is required' });
      return;
    }

    const trimmedNickname = nickname.trim();
    if (trimmedNickname.length < 2 || trimmedNickname.length > 20) {
      res.status(400).json({ error: 'nickname must be 2-20 characters' });
      return;
    }
    await assertUserNotBanned(payload.userId);

    const user = await updateNickname(payload.userId, trimmedNickname);

    res.json({
      user: {
        id: user.id,
        nickname: user.nickname,
        email: user.email,
        avatarUrl: user.avatar_url,
      },
    });
  } catch (error) {
    console.error('Update nickname error:', error);
    const message = error instanceof Error ? error.message : 'Failed to update nickname';
    const statusCode = message.includes('banned') ? 403 : 500;
    res.status(statusCode).json({ error: message });
  }
});

// DELETE /api/auth/account - 회원 탈퇴
router.delete('/account', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    await deleteUser(payload.userId);

    res.json({ success: true, message: '회원 탈퇴가 완료되었습니다.' });
  } catch (error) {
    console.error('Delete account error:', error);
    res.status(500).json({ error: 'Failed to delete account' });
  }
});

export default router;
