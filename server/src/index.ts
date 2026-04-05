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

// Admin page
app.use('/admin', express.static(path.join(__dirname, '../public/admin')));

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
