"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const http_1 = require("http");
const socket_io_1 = require("socket.io");
const cors_1 = __importDefault(require("cors"));
const dotenv_1 = __importDefault(require("dotenv"));
const socket_1 = require("./socket");
const database_1 = require("./config/database");
const auth_1 = __importDefault(require("./routes/auth"));
dotenv_1.default.config();
const app = (0, express_1.default)();
const httpServer = (0, http_1.createServer)(app);
const io = new socket_io_1.Server(httpServer, {
    cors: {
        origin: '*', // 개발 환경에서는 모든 origin 허용
        methods: ['GET', 'POST'],
    },
});
// Middleware
app.use((0, cors_1.default)());
app.use(express_1.default.json());
// Health check
app.get('/', (req, res) => {
    res.json({ status: 'ok', message: 'Minigame Server is running!' });
});
// Auth routes
app.use('/api/auth', auth_1.default);
// Socket.io 핸들러 설정
(0, socket_1.setupSocketHandlers)(io);
const PORT = process.env.PORT || 3000;
async function start() {
    try {
        // 데이터베이스 연결
        await (0, database_1.setupDatabase)();
        httpServer.listen(PORT, () => {
            console.log(`🎮 Minigame Server running on port ${PORT}`);
        });
    }
    catch (error) {
        console.error('Failed to start server:', error);
        process.exit(1);
    }
}
start();
