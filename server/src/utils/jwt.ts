import jwt from 'jsonwebtoken';

// JWT_SECRET은 반드시 환경변수로 주입해야 한다. 운영 환경에서 누락 시 토큰 위조
// 위험이 있으므로 부팅을 실패시킨다. 개발 환경(NODE_ENV=development)에서는
// 편의를 위해 경고만 출력하고 임시 키를 사용한다.
function resolveJwtSecret(): string {
  const fromEnv = process.env.JWT_SECRET;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET environment variable is required in production');
  }
  console.warn('[jwt] JWT_SECRET not set - using development fallback (DO NOT USE IN PRODUCTION)');
  return 'dev-only-insecure-secret';
}

const JWT_SECRET = resolveJwtSecret();
const JWT_EXPIRES_IN = '7d';

export interface JwtPayload {
  userId: number;
  iat?: number;
  exp?: number;
}

export function generateToken(userId: number): string {
  return jwt.sign({ userId }, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });
}

export function verifyToken(token: string): JwtPayload | null {
  try {
    return jwt.verify(token, JWT_SECRET) as JwtPayload;
  } catch {
    return null;
  }
}
