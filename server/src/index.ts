import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import dotenv from 'dotenv';
import { setupSocketHandlers } from './socket';
import { setupDatabase } from './config/database';
import authRouter from './routes/auth';
import inquiryRouter from './routes/inquiry';
import adminRouter from './routes/admin';
import path from 'path';

dotenv.config();

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: '*', // 개발 환경에서는 모든 origin 허용
    methods: ['GET', 'POST'],
  },
});

// Middleware
app.use(cors());
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
