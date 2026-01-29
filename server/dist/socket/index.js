"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setupSocketHandlers = setupSocketHandlers;
const tictactoe_1 = require("../games/tictactoe");
// 게임방 관리
const rooms = new Map();
// 매칭 대기열 (게임 타입별)
const matchQueues = new Map();
function setupSocketHandlers(io) {
    io.on('connection', (socket) => {
        console.log(`👤 Player connected: ${socket.id}`);
        // 플레이어 정보
        let currentPlayer = null;
        let currentRoomId = null;
        // 로비 입장
        socket.on('join_lobby', (data) => {
            currentPlayer = {
                id: socket.id,
                socket,
                nickname: data.nickname,
                userId: data.userId,
            };
            socket.emit('lobby_joined', { success: true });
            console.log(`🎮 ${data.nickname} joined lobby`);
        });
        // 게임 매칭 요청
        socket.on('find_match', (data) => {
            if (!currentPlayer) {
                socket.emit('error', { message: 'Please join lobby first' });
                return;
            }
            const { gameType } = data;
            if (!matchQueues.has(gameType)) {
                matchQueues.set(gameType, []);
            }
            const queue = matchQueues.get(gameType);
            // 이미 대기열에 상대가 있으면 매칭
            if (queue.length > 0) {
                const opponent = queue.shift();
                // 방 생성
                const roomId = `${gameType}_${Date.now()}`;
                const room = {
                    id: roomId,
                    gameType,
                    players: [opponent, currentPlayer],
                    game: null,
                    status: 'waiting',
                };
                // 틱택토 게임 초기화
                if (gameType === 'tictactoe') {
                    room.game = new tictactoe_1.TicTacToeGame();
                }
                rooms.set(roomId, room);
                // 두 플레이어를 방에 조인
                opponent.socket.join(roomId);
                socket.join(roomId);
                currentRoomId = roomId;
                // 매칭 성공 알림
                io.to(roomId).emit('match_found', {
                    roomId,
                    gameType,
                    players: [
                        { id: opponent.id, nickname: opponent.nickname },
                        { id: currentPlayer.id, nickname: currentPlayer.nickname },
                    ],
                });
                console.log(`🎯 Match found: ${opponent.nickname} vs ${currentPlayer.nickname}`);
                // 게임 시작
                room.status = 'playing';
                io.to(roomId).emit('game_start', {
                    currentTurn: opponent.id, // 첫 번째 플레이어가 선공
                    board: room.game?.getBoard(),
                });
            }
            else {
                // 대기열에 추가
                queue.push(currentPlayer);
                socket.emit('waiting_for_match', { gameType });
                console.log(`⏳ ${currentPlayer.nickname} waiting for match (${gameType})`);
            }
        });
        // 매칭 취소
        socket.on('cancel_match', (data) => {
            const queue = matchQueues.get(data.gameType);
            if (queue) {
                const index = queue.findIndex(p => p.id === socket.id);
                if (index !== -1) {
                    queue.splice(index, 1);
                    socket.emit('match_cancelled');
                }
            }
        });
        // 게임 액션 (틱택토: 셀 클릭)
        socket.on('game_action', (data) => {
            const room = rooms.get(data.roomId);
            if (!room || room.status !== 'playing') {
                socket.emit('error', { message: 'Invalid room or game not in progress' });
                return;
            }
            const playerIndex = room.players.findIndex(p => p.id === socket.id);
            if (playerIndex === -1) {
                socket.emit('error', { message: 'You are not in this game' });
                return;
            }
            // 틱택토 게임 로직
            if (room.gameType === 'tictactoe' && room.game) {
                const result = room.game.makeMove(data.action.position, playerIndex);
                if (!result.valid) {
                    socket.emit('error', { message: result.message });
                    return;
                }
                // 게임 상태 업데이트 브로드캐스트
                io.to(data.roomId).emit('game_update', {
                    board: room.game.getBoard(),
                    currentTurn: room.players[room.game.getCurrentPlayer()].id,
                    lastMove: data.action.position,
                });
                // 게임 종료 체크
                if (result.gameOver) {
                    room.status = 'finished';
                    const winnerId = result.winner !== undefined && result.winner !== null
                        ? room.players[result.winner].id
                        : null;
                    const winnerNickname = result.winner !== undefined && result.winner !== null
                        ? room.players[result.winner].nickname
                        : null;
                    io.to(data.roomId).emit('game_end', {
                        winner: winnerId,
                        winnerNickname: winnerNickname,
                        isDraw: result.isDraw,
                        board: room.game.getBoard(),
                    });
                    console.log(`🏆 Game ended: ${result.isDraw ? 'Draw' : winnerNickname + ' wins'}`);
                }
            }
        });
        // 재대결 요청
        socket.on('rematch_request', (data) => {
            const room = rooms.get(data.roomId);
            if (room && room.status === 'finished') {
                socket.to(data.roomId).emit('rematch_requested', {
                    from: currentPlayer?.nickname,
                });
            }
        });
        // 재대결 수락
        socket.on('rematch_accept', (data) => {
            const room = rooms.get(data.roomId);
            if (room && room.status === 'finished') {
                // 게임 리셋
                if (room.gameType === 'tictactoe') {
                    room.game = new tictactoe_1.TicTacToeGame();
                }
                room.status = 'playing';
                // 선공 교체 (두 번째 플레이어가 선공)
                io.to(data.roomId).emit('game_start', {
                    currentTurn: room.players[1].id,
                    board: room.game?.getBoard(),
                });
            }
        });
        // 방 나가기
        socket.on('leave_room', (data) => {
            leaveRoom(socket, data.roomId);
        });
        // 연결 해제
        socket.on('disconnect', () => {
            console.log(`👋 Player disconnected: ${socket.id}`);
            // 대기열에서 제거
            matchQueues.forEach((queue, gameType) => {
                const index = queue.findIndex(p => p.id === socket.id);
                if (index !== -1) {
                    queue.splice(index, 1);
                }
            });
            // 진행 중인 게임에서 제거
            if (currentRoomId) {
                leaveRoom(socket, currentRoomId);
            }
        });
        function leaveRoom(socket, roomId) {
            const room = rooms.get(roomId);
            if (room) {
                socket.leave(roomId);
                // 상대방에게 알림
                socket.to(roomId).emit('opponent_left', {
                    message: 'Opponent has left the game',
                });
                // 방 정리
                room.players = room.players.filter(p => p.id !== socket.id);
                if (room.players.length === 0) {
                    rooms.delete(roomId);
                }
            }
            currentRoomId = null;
        }
    });
}
