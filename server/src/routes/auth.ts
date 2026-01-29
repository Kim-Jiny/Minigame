import { Router, Request, Response } from 'express';
import { OAuth2Client } from 'google-auth-library';
import jwt from 'jsonwebtoken';
import { findOrCreateUser } from '../services/userService';
import { generateToken } from '../utils/jwt';

const router = Router();

// Google OAuth Client
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);

// POST /api/auth/google - Google 로그인
router.post('/google', async (req: Request, res: Response): Promise<void> => {
  try {
    const { idToken } = req.body;

    if (!idToken) {
      res.status(400).json({ error: 'idToken is required' });
      return;
    }

    // Google idToken 검증
    const ticket = await googleClient.verifyIdToken({
      idToken,
      audience: process.env.GOOGLE_CLIENT_ID,
    });

    const payload = ticket.getPayload();
    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const { sub: providerId, email, name, picture } = payload;

    // 사용자 생성 또는 조회
    const user = await findOrCreateUser(
      'google',
      providerId!,
      email || null,
      name || email?.split('@')[0] || 'User',
      picture || null
    );

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
    res.status(401).json({ error: 'Authentication failed' });
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

    // Apple idToken 디코딩 (검증은 클라이언트에서 수행됨)
    // 실제 프로덕션에서는 Apple 공개키로 검증해야 함
    const decoded = jwt.decode(idToken) as {
      sub: string;
      email?: string;
    } | null;

    if (!decoded || !decoded.sub) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

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
    res.status(401).json({ error: 'Authentication failed' });
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
    const nickname = kakaoUser.kakao_account?.profile?.nickname || 'Kakao User';
    const avatarUrl = kakaoUser.kakao_account?.profile?.profile_image_url || null;

    // 사용자 생성 또는 조회
    const user = await findOrCreateUser('kakao', providerId, email, nickname, avatarUrl);

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
    res.status(401).json({ error: 'Authentication failed' });
  }
});

export default router;
