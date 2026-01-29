"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setupSocketHandlers = setupSocketHandlers;
const tictactoe_1 = require("../games/tictactoe");
const infinitetictactoe_1 = require("../games/infinitetictactoe");
const friendService_1 = require("../services/friendService");
const invitationService_1 = require("../services/invitationService");
const statsService_1 = require("../services/statsService");
// 게임방 관리
const rooms = new Map();
// 매칭 대기열 (게임 타입별)
const matchQueues = new Map();
// 유저 ID별 소켓 매핑 (초대 알림용)
const userSockets = new Map();
function setupSocketHandlers(io) {
    io.on('connection', (socket) => {
        console.log(`👤 Player connected: ${socket.id}`);
        // 플레이어 정보
        let currentPlayer = null;
        let currentRoomId = null;
        // 로비 입장
        socket.on('join_lobby', async (data) => {
            console.log(`📥 join_lobby received:`, { nickname: data.nickname, userId: data.userId });
            currentPlayer = {
                id: socket.id,
                socket,
                nickname: data.nickname,
                userId: data.userId,
            };
            // 유저 ID가 있으면 소켓 매핑
            if (data.userId) {
                userSockets.set(data.userId, socket);
                console.log(`👤 User ${data.userId} mapped to socket ${socket.id}`);
                // 친구 코드 자동 생성 (없으면)
                try {
                    const code = await friendService_1.friendService.generateFriendCode(data.userId);
                    console.log(`🔑 Friend code for user ${data.userId}: ${code}`);
                }
                catch (error) {
                    console.error('Failed to generate friend code:', error);
                }
            }
            else {
                console.log(`⚠️ No userId provided for ${data.nickname}`);
            }
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
                // 게임 초기화
                if (gameType === 'tictactoe') {
                    room.game = new tictactoe_1.TicTacToeGame();
                }
                else if (gameType === 'infinite_tictactoe') {
                    room.game = new infinitetictactoe_1.InfiniteTicTacToeGame();
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
        socket.on('game_action', async (data) => {
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
            if (room.gameType === 'tictactoe' && room.game instanceof tictactoe_1.TicTacToeGame) {
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
                    // 통계 업데이트 및 기록 저장
                    const player0 = room.players[0];
                    const player1 = room.players[1];
                    for (let i = 0; i < room.players.length; i++) {
                        const player = room.players[i];
                        const opponent = room.players[i === 0 ? 1 : 0];
                        if (player.userId) {
                            let gameResult;
                            if (result.isDraw) {
                                gameResult = 'draw';
                            }
                            else if (result.winner === i) {
                                gameResult = 'win';
                            }
                            else {
                                gameResult = 'loss';
                            }
                            try {
                                const stats = await statsService_1.statsService.recordGameResult(player.userId, room.gameType, gameResult);
                                player.socket.emit('stats_updated', { stats });
                                // 게임 기록 저장 (첫 번째 플레이어만 저장하면 됨)
                                if (i === 0 && opponent.userId) {
                                    await statsService_1.statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
                                }
                            }
                            catch (err) {
                                console.error('Failed to update stats:', err);
                            }
                        }
                    }
                    io.to(data.roomId).emit('game_end', {
                        winner: winnerId,
                        winnerNickname: winnerNickname,
                        isDraw: result.isDraw,
                        board: room.game.getBoard(),
                    });
                    console.log(`🏆 Game ended: ${result.isDraw ? 'Draw' : winnerNickname + ' wins'}`);
                }
            }
            // 무한 틱택토 게임 로직
            if (room.gameType === 'infinite_tictactoe' && room.game instanceof infinitetictactoe_1.InfiniteTicTacToeGame) {
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
                    removedPosition: result.removedPosition, // 사라진 말 위치
                    moveHistory: room.game.getMoveHistory(), // 이동 기록
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
                    // 통계 업데이트 및 기록 저장
                    for (let i = 0; i < room.players.length; i++) {
                        const player = room.players[i];
                        const opponent = room.players[i === 0 ? 1 : 0];
                        if (player.userId) {
                            const gameResult = result.winner === i ? 'win' : 'loss';
                            try {
                                const stats = await statsService_1.statsService.recordGameResult(player.userId, room.gameType, gameResult);
                                player.socket.emit('stats_updated', { stats });
                                // 게임 기록 저장 (첫 번째 플레이어만 저장하면 됨)
                                if (i === 0 && opponent.userId) {
                                    await statsService_1.statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
                                }
                            }
                            catch (err) {
                                console.error('Failed to update stats:', err);
                            }
                        }
                    }
                    io.to(data.roomId).emit('game_end', {
                        winner: winnerId,
                        winnerNickname: winnerNickname,
                        isDraw: false, // 무한 틱택토는 무승부 없음
                        board: room.game.getBoard(),
                    });
                    console.log(`🏆 Infinite TicTacToe ended: ${winnerNickname} wins`);
                }
            }
        });
        // ====== 친구 시스템 ======
        // 내 친구 코드 조회
        socket.on('get_friend_code', async () => {
            console.log(`📥 get_friend_code requested by user:`, currentPlayer?.userId);
            if (!currentPlayer?.userId) {
                console.log(`⚠️ get_friend_code: No userId`);
                socket.emit('friend_code_error', { message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const code = await friendService_1.friendService.generateFriendCode(currentPlayer.userId);
                console.log(`✅ Sending friend code: ${code}`);
                socket.emit('friend_code', { code });
            }
            catch (error) {
                console.error('❌ get_friend_code error:', error);
                socket.emit('friend_code_error', { message: '친구 코드 조회 실패' });
            }
        });
        // 친구 추가
        socket.on('add_friend', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('add_friend_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const result = await friendService_1.friendService.addFriend(currentPlayer.userId, data.friendCode);
                socket.emit('add_friend_result', result);
                // 상대방에게도 친구 추가 알림
                if (result.success && result.friend) {
                    const friendSocket = userSockets.get(result.friend.id);
                    if (friendSocket) {
                        // 내 정보 조회해서 전송
                        const myCode = await friendService_1.friendService.getFriendCode(currentPlayer.userId);
                        friendSocket.emit('friend_added', {
                            id: currentPlayer.userId,
                            nickname: currentPlayer.nickname,
                            friendCode: myCode
                        });
                    }
                }
            }
            catch (error) {
                socket.emit('add_friend_result', { success: false, message: '친구 추가 실패' });
            }
        });
        // 친구 목록 조회
        socket.on('get_friends', async () => {
            if (!currentPlayer?.userId) {
                socket.emit('friends_list', { friends: [] });
                return;
            }
            try {
                const friends = await friendService_1.friendService.getFriends(currentPlayer.userId);
                // 온라인 상태 추가
                const friendsWithStatus = friends.map(friend => ({
                    ...friend,
                    isOnline: userSockets.has(friend.id)
                }));
                socket.emit('friends_list', { friends: friendsWithStatus });
            }
            catch (error) {
                socket.emit('friends_list', { friends: [] });
            }
        });
        // 친구 삭제
        socket.on('remove_friend', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('remove_friend_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const result = await friendService_1.friendService.removeFriend(currentPlayer.userId, data.friendId);
                socket.emit('remove_friend_result', result);
            }
            catch (error) {
                socket.emit('remove_friend_result', { success: false, message: '친구 삭제 실패' });
            }
        });
        // 친구 메모 수정
        socket.on('update_friend_memo', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('update_friend_memo_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const result = await friendService_1.friendService.updateFriendMemo(currentPlayer.userId, data.friendId, data.memo);
                socket.emit('update_friend_memo_result', { ...result, friendId: data.friendId, memo: data.memo });
            }
            catch (error) {
                socket.emit('update_friend_memo_result', { success: false, message: '메모 저장 실패' });
            }
        });
        // ====== 게임 초대 시스템 ======
        // 게임 초대 보내기
        socket.on('invite_to_game', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('invite_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const invitation = await invitationService_1.invitationService.createInvitation(currentPlayer.userId, data.friendId, data.gameType);
                socket.emit('invite_result', { success: true, invitation });
                // 상대방에게 초대 알림
                const friendSocket = userSockets.get(data.friendId);
                if (friendSocket) {
                    friendSocket.emit('game_invitation', { invitation });
                }
            }
            catch (error) {
                socket.emit('invite_result', { success: false, message: '초대 전송 실패' });
            }
        });
        // 받은 초대 목록 조회
        socket.on('get_invitations', async () => {
            if (!currentPlayer?.userId) {
                socket.emit('invitations_list', { invitations: [] });
                return;
            }
            try {
                const invitations = await invitationService_1.invitationService.getInvitations(currentPlayer.userId);
                socket.emit('invitations_list', { invitations });
            }
            catch (error) {
                socket.emit('invitations_list', { invitations: [] });
            }
        });
        // 초대 수락
        socket.on('accept_invitation', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('accept_invitation_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const invitation = await invitationService_1.invitationService.getInvitation(data.invitationId);
                if (!invitation) {
                    socket.emit('accept_invitation_result', { success: false, message: '초대를 찾을 수 없습니다.' });
                    return;
                }
                // 게임방 생성
                const roomId = `${invitation.gameType}_invite_${Date.now()}`;
                const result = await invitationService_1.invitationService.acceptInvitation(data.invitationId, roomId);
                if (!result.success) {
                    socket.emit('accept_invitation_result', result);
                    return;
                }
                // 초대한 사람 찾기
                const inviterSocket = userSockets.get(invitation.inviterId);
                const inviterPlayer = inviterSocket ? {
                    id: inviterSocket.id,
                    socket: inviterSocket,
                    nickname: invitation.inviterNickname,
                    userId: invitation.inviterId
                } : null;
                if (!inviterPlayer) {
                    socket.emit('accept_invitation_result', { success: false, message: '초대한 사람이 오프라인입니다.' });
                    return;
                }
                // 게임방 생성
                const room = {
                    id: roomId,
                    gameType: invitation.gameType,
                    players: [inviterPlayer, currentPlayer],
                    game: null,
                    status: 'waiting'
                };
                // 게임 초기화
                if (invitation.gameType === 'tictactoe') {
                    room.game = new tictactoe_1.TicTacToeGame();
                }
                else if (invitation.gameType === 'infinite_tictactoe') {
                    room.game = new infinitetictactoe_1.InfiniteTicTacToeGame();
                }
                rooms.set(roomId, room);
                // 방 참가
                inviterSocket.join(roomId);
                socket.join(roomId);
                currentRoomId = roomId;
                socket.emit('accept_invitation_result', { success: true, roomId, gameType: invitation.gameType });
                // 초대자에게 수락 알림 (게임 화면으로 이동하도록)
                inviterSocket.emit('invitation_accepted', {
                    roomId,
                    gameType: invitation.gameType,
                    acceptedBy: currentPlayer.nickname
                });
                // 양쪽에 매칭 성공 알림
                io.to(roomId).emit('match_found', {
                    roomId,
                    gameType: invitation.gameType,
                    players: [
                        { id: inviterPlayer.id, nickname: inviterPlayer.nickname },
                        { id: currentPlayer.id, nickname: currentPlayer.nickname }
                    ]
                });
                // 게임 시작
                room.status = 'playing';
                io.to(roomId).emit('game_start', {
                    currentTurn: inviterPlayer.id,
                    board: room.game?.getBoard()
                });
                console.log(`🎮 Invitation game started: ${inviterPlayer.nickname} vs ${currentPlayer.nickname}`);
            }
            catch (error) {
                socket.emit('accept_invitation_result', { success: false, message: '초대 수락 실패' });
            }
        });
        // 초대 거절
        socket.on('decline_invitation', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('decline_invitation_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const invitation = await invitationService_1.invitationService.getInvitation(data.invitationId);
                const result = await invitationService_1.invitationService.declineInvitation(data.invitationId);
                socket.emit('decline_invitation_result', result);
                // 초대한 사람에게 알림
                if (invitation) {
                    const inviterSocket = userSockets.get(invitation.inviterId);
                    if (inviterSocket) {
                        inviterSocket.emit('invitation_declined', {
                            invitationId: data.invitationId,
                            declinedBy: currentPlayer.nickname
                        });
                    }
                }
            }
            catch (error) {
                socket.emit('decline_invitation_result', { success: false, message: '초대 거절 실패' });
            }
        });
        // ====== 통계 시스템 ======
        // 모든 게임 통계 조회
        socket.on('get_all_stats', async () => {
            if (!currentPlayer?.userId) {
                socket.emit('all_stats', { stats: [] });
                return;
            }
            try {
                const stats = await statsService_1.statsService.getAllGameStats(currentPlayer.userId);
                socket.emit('all_stats', { stats });
            }
            catch (error) {
                socket.emit('all_stats', { stats: [] });
            }
        });
        // 최근 게임 기록 조회
        socket.on('get_recent_records', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('recent_records', { records: [] });
                return;
            }
            try {
                const records = await statsService_1.statsService.getRecentRecords(currentPlayer.userId, data?.limit || 20);
                socket.emit('recent_records', { records });
            }
            catch (error) {
                socket.emit('recent_records', { records: [] });
            }
        });
        // 특정 게임 통계 조회
        socket.on('get_game_stats', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('game_stats', { stats: null });
                return;
            }
            try {
                const stats = await statsService_1.statsService.getGameStats(currentPlayer.userId, data.gameType);
                socket.emit('game_stats', { stats });
            }
            catch (error) {
                socket.emit('game_stats', { stats: null });
            }
        });
        // 마일리지 조회
        socket.on('get_mileage', async () => {
            if (!currentPlayer?.userId) {
                socket.emit('mileage', { mileage: 0 });
                return;
            }
            try {
                const mileage = await statsService_1.statsService.getMileage(currentPlayer.userId);
                socket.emit('mileage', { mileage });
            }
            catch (error) {
                socket.emit('mileage', { mileage: 0 });
            }
        });
        // 광고 시청 마일리지 지급
        socket.on('claim_ad_reward', async () => {
            if (!currentPlayer?.userId) {
                socket.emit('ad_reward_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            try {
                const mileage = await statsService_1.statsService.addMileage(currentPlayer.userId, 10, 'ad_watch');
                socket.emit('ad_reward_result', { success: true, mileage, message: '10 마일리지가 지급되었습니다!' });
            }
            catch (error) {
                socket.emit('ad_reward_result', { success: false, message: '마일리지 지급 실패' });
            }
        });
        // 승률 초기화 (마일리지 사용)
        socket.on('reset_stats', async (data) => {
            if (!currentPlayer?.userId) {
                socket.emit('reset_stats_result', { success: false, message: '로그인이 필요합니다.' });
                return;
            }
            const RESET_COST = 100; // 승률 초기화 비용
            try {
                // 마일리지 차감
                const mileageResult = await statsService_1.statsService.useMileage(currentPlayer.userId, RESET_COST, `reset_stats_${data.gameType}`);
                if (!mileageResult.success) {
                    socket.emit('reset_stats_result', { success: false, message: mileageResult.message, mileage: mileageResult.mileage });
                    return;
                }
                // 통계 초기화
                const resetResult = await statsService_1.statsService.resetStats(currentPlayer.userId, data.gameType);
                if (!resetResult.success) {
                    // 롤백: 마일리지 복구
                    await statsService_1.statsService.addMileage(currentPlayer.userId, RESET_COST, 'reset_stats_rollback');
                    socket.emit('reset_stats_result', { success: false, message: resetResult.message });
                    return;
                }
                // 새 통계 조회
                const newStats = await statsService_1.statsService.getGameStats(currentPlayer.userId, data.gameType);
                socket.emit('reset_stats_result', {
                    success: true,
                    message: '승률이 초기화되었습니다.',
                    stats: newStats,
                    mileage: mileageResult.mileage
                });
            }
            catch (error) {
                socket.emit('reset_stats_result', { success: false, message: '승률 초기화 실패' });
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
                else if (room.gameType === 'infinite_tictactoe') {
                    room.game = new infinitetictactoe_1.InfiniteTicTacToeGame();
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
            // userSockets에서 제거
            if (currentPlayer?.userId) {
                userSockets.delete(currentPlayer.userId);
            }
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
