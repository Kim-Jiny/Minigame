// env 로딩은 반드시 가장 먼저. 다른 모듈이 top-level에서 process.env를 읽기
// 때문에, 이 import가 다른 import보다 위에 있어야 한다.
import './config/env';

import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import { setupSocketHandlers } from './socket';
import { setupDatabase } from './config/database';
import authRouter from './routes/auth';
import inquiryRouter from './routes/inquiry';
import adminRouter from './routes/admin';
import catchTheRuleRouter from './routes/catchtherule'; // [CTR] CatchTheRule 소유 — 삭제 금지
import sajatoonRouter from './routes/sajatoon'; // [SAJA] 사자툰 소유 — 삭제 금지
import mathForAdultsRouter from './routes/mathforadults'; // [MFA] 성인의 수학 소유 — 삭제 금지
import perlerPixelRouter, { ppAppleAppSiteAssociation, ppSharePage } from './routes/perlerpixel'; // [PP] PerlerPixel 소유 — 삭제 금지
import path from 'path';

// 전역 에러 안전망: 비동기 소켓 핸들러/타이머 콜백에서 발생한 에러가
// Node 프로세스를 죽이지 않도록 방지. 운영 시 로그만 남기고 서비스는 계속.
process.on('unhandledRejection', (reason) => {
  console.error('[unhandledRejection]', reason);
});
process.on('uncaughtException', (err) => {
  console.error('[uncaughtException]', err);
});

const app = express();
const httpServer = createServer(app);

// CORS origin 화이트리스트. ALLOWED_ORIGINS 환경변수로 콤마 구분 지정 가능.
// 미설정 시 개발 편의를 위해 '*' 허용.
const allowedOriginsEnv = process.env.ALLOWED_ORIGINS?.trim();
const corsOrigin: string | string[] = allowedOriginsEnv
  ? allowedOriginsEnv.split(',').map((o) => o.trim()).filter(Boolean)
  : '*';

const io = new Server(httpServer, {
  cors: {
    origin: corsOrigin,
    methods: ['GET', 'POST'],
  },
  // 연결 안정화 설정.
  // - pingInterval/pingTimeout: 모바일에서 네트워크 전환·일시 지연 시 기본값(20s)으로는
  //   pong 지연만으로도 끊김 판정이 나기 쉬워, 타임아웃을 30s로 늘려 불필요한 단절을 줄인다.
  // - maxHttpBufferSize: 비정상적으로 큰 페이로드 방어(기본 1MB 명시).
  pingInterval: 25000,
  pingTimeout: 30000,
  maxHttpBufferSize: 1e6,
});

// Middleware
app.use(cors({ origin: corsOrigin }));
app.use(express.json());

// Health check
app.get('/', (req, res) => {
  res.json({ status: 'ok', message: 'Minigame Server is running!' });
});

// Auth routes
app.use('/api/auth', authRouter);

// Inquiry routes
app.use('/api/inquiry', inquiryRouter);

// Admin routes
app.use('/api/admin', adminRouter);

// [CTR] CatchTheRule(규칙찾기) 공개 API + 정적 약관 — CTR 소유. 삭제·리팩터링 금지.
// CatchTheRule (규칙찾기) 솔로 랭킹 — 로그인 불필요 공개 API
app.use('/api/catchtherule', catchTheRuleRouter);

// [SAJA] 사자툰(SajaToon) 공개 API — SajaToon 소유. 삭제·리팩터링 금지.
// "매일 한 편의 만화로 배우는 사자성어" 앱(별도 리포). 로그인 없는 deviceId 기반.
app.use('/api/sajatoon', sajatoonRouter);

// [MFA] 성인의 수학(Math for Adults) 공개 API — 별도 리포(MathForAdults) 소유. 삭제·리팩터링 금지.
// 로그인 없는 deviceId 기반 문의.
app.use('/api/mathforadults', mathForAdultsRouter);

// [PP] PerlerPixel(비즈픽셀) 커뮤니티 게시판 API — 별도 리포(PerlerPixel) 소유. 삭제·리팩터링 금지.
// 소셜 로그인(pp_users) 기반. 리스트는 비로그인, 상세/업로드/상호작용은 로그인 필요.
app.use('/api/perlerpixel', perlerPixelRouter);

// 관리자 페이지 — /backstage 로만 접근 (기존 /admin 경로는 제거).
app.use('/backstage', express.static(path.join(__dirname, '../public/admin')));

// 게임별 약관/개인정보처리방침 정적 페이지
//   규칙찾기: /ctr/terms, /ctr/privacy   ·   듀오 아레나: /duo/terms, /duo/privacy
app.use('/ctr', express.static(path.join(__dirname, '../public/ctr'), { extensions: ['html'] })); // [CTR] 소유 — 삭제 금지
app.use('/duo', express.static(path.join(__dirname, '../public/duo'), { extensions: ['html'] }));
// [SAJA] 사자툰 정적 자산 — 만화 이미지(/saja/comics/*.png 등)와 약관(/saja/*). SajaToon 소유, 삭제 금지.
app.use('/saja', express.static(path.join(__dirname, '../public/saja'), { extensions: ['html'] }));
// [MFA] 성인의 수학 약관/개인정보/지원 정적 페이지 (/mfa/privacy, /mfa/support). 성인의 수학 소유.
app.use('/mfa', express.static(path.join(__dirname, '../public/mfa'), { extensions: ['html'] }));
// [PP] 유니버설 링크 지원 — AASA(앱이 /pp/p/* 를 가로챔) + 공유 웹페이지. 정적 /pp 마운트보다 먼저.
app.get('/.well-known/apple-app-site-association', ppAppleAppSiteAssociation);
app.get('/apple-app-site-association', ppAppleAppSiteAssociation);
app.get('/pp/p/:code', ppSharePage);
// [PP] PerlerPixel 정적 — 약관·개인정보·커뮤니티 가이드라인·문의(/pp/*)와 업로드 프리뷰(/pp/uploads/*). PerlerPixel 소유.
app.use('/pp', express.static(path.join(__dirname, '../public/pp'), { extensions: ['html'] }));

// Socket.io 핸들러 설정
setupSocketHandlers(io);

const PORT = process.env.PORT || 3000;

async function start() {
  try {
    // 데이터베이스 연결
    await setupDatabase();

    httpServer.listen(PORT, () => {
      console.log(`🎮 Minigame Server running on port ${PORT}`);
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

start();
