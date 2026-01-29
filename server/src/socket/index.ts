import { Server, Socket } from 'socket.io';
import { TicTacToeGame } from '../games/tictactoe';
import { InfiniteTicTacToeGame } from '../games/infinitetictactoe';
import { friendService } from '../services/friendService';
import { invitationService } from '../services/invitationService';

interface Player {
  id: string;
  socket: Socket;
  nickname: string;
  userId?: number;
}

interface GameRoom {
  id: string;
  gameType: string;
  players: Player[];
  game: TicTacToeGame | InfiniteTicTacToeGame | null;
  status: 'waiting' | 'playing' | 'finished';
}

// 게임방 관리
const rooms = new Map<string, GameRoom>();
// 매칭 대기열 (게임 타입별)
const matchQueues = new Map<string, Player[]>();
// 유저 ID별 소켓 매핑 (초대 알림용)
const userSockets = new Map<number, Socket>();

export function setupSocketHandlers(io: Server) {
  io.on('connection', (socket: Socket) => {
    console.log(`👤 Player connected: ${socket.id}`);

    // 플레이어 정보
    let currentPlayer: Player | null = null;
    let currentRoomId: string | null = null;

    // 로비 입장
    socket.on('join_lobby', async (data: { nickname: string; userId?: number }) => {
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
          const code = await friendService.generateFriendCode(data.userId);
          console.log(`🔑 Friend code for user ${data.userId}: ${code}`);
        } catch (error) {
          console.error('Failed to generate friend code:', error);
        }
      } else {
        console.log(`⚠️ No userId provided for ${data.nickname}`);
      }

      socket.emit('lobby_joined', { success: true });
      console.log(`🎮 ${data.nickname} joined lobby`);
    });

    // 게임 매칭 요청
    socket.on('find_match', (data: { gameType: string }) => {
      if (!currentPlayer) {
        socket.emit('error', { message: 'Please join lobby first' });
        return;
      }

      const { gameType } = data;

      if (!matchQueues.has(gameType)) {
        matchQueues.set(gameType, []);
      }

      const queue = matchQueues.get(gameType)!;

      // 이미 대기열에 상대가 있으면 매칭
      if (queue.length > 0) {
        const opponent = queue.shift()!;

        // 방 생성
        const roomId = `${gameType}_${Date.now()}`;
        const room: GameRoom = {
          id: roomId,
          gameType,
          players: [opponent, currentPlayer],
          game: null,
          status: 'waiting',
        };

        // 게임 초기화
        if (gameType === 'tictactoe') {
          room.game = new TicTacToeGame();
        } else if (gameType === 'infinite_tictactoe') {
          room.game = new InfiniteTicTacToeGame();
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
      } else {
        // 대기열에 추가
        queue.push(currentPlayer);
        socket.emit('waiting_for_match', { gameType });
        console.log(`⏳ ${currentPlayer.nickname} waiting for match (${gameType})`);
      }
    });

    // 매칭 취소
    socket.on('cancel_match', (data: { gameType: string }) => {
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
    socket.on('game_action', (data: { roomId: string; action: any }) => {
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
      if (room.gameType === 'tictactoe' && room.game instanceof TicTacToeGame) {
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

      // 무한 틱택토 게임 로직
      if (room.gameType === 'infinite_tictactoe' && room.game instanceof InfiniteTicTacToeGame) {
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
          removedPosition: result.removedPosition,  // 사라진 말 위치
          moveHistory: room.game.getMoveHistory(),  // 이동 기록
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
            isDraw: false,  // 무한 틱택토는 무승부 없음
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
        const code = await friendService.generateFriendCode(currentPlayer.userId);
        console.log(`✅ Sending friend code: ${code}`);
        socket.emit('friend_code', { code });
      } catch (error) {
        console.error('❌ get_friend_code error:', error);
        socket.emit('friend_code_error', { message: '친구 코드 조회 실패' });
      }
    });

    // 친구 추가
    socket.on('add_friend', async (data: { friendCode: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('add_friend_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.addFriend(currentPlayer.userId, data.friendCode);
        socket.emit('add_friend_result', result);

        // 상대방에게도 친구 추가 알림
        if (result.success && result.friend) {
          const friendSocket = userSockets.get(result.friend.id);
          if (friendSocket) {
            // 내 정보 조회해서 전송
            const myCode = await friendService.getFriendCode(currentPlayer.userId);
            friendSocket.emit('friend_added', {
              id: currentPlayer.userId,
              nickname: currentPlayer.nickname,
              friendCode: myCode
            });
          }
        }
      } catch (error) {
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
        const friends = await friendService.getFriends(currentPlayer.userId);
        // 온라인 상태 추가
        const friendsWithStatus = friends.map(friend => ({
          ...friend,
          isOnline: userSockets.has(friend.id)
        }));
        socket.emit('friends_list', { friends: friendsWithStatus });
      } catch (error) {
        socket.emit('friends_list', { friends: [] });
      }
    });

    // 친구 삭제
    socket.on('remove_friend', async (data: { friendId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('remove_friend_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.removeFriend(currentPlayer.userId, data.friendId);
        socket.emit('remove_friend_result', result);
      } catch (error) {
        socket.emit('remove_friend_result', { success: false, message: '친구 삭제 실패' });
      }
    });

    // ====== 게임 초대 시스템 ======

    // 게임 초대 보내기
    socket.on('invite_to_game', async (data: { friendId: number; gameType: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('invite_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const invitation = await invitationService.createInvitation(
          currentPlayer.userId,
          data.friendId,
          data.gameType
        );

        socket.emit('invite_result', { success: true, invitation });

        // 상대방에게 초대 알림
        const friendSocket = userSockets.get(data.friendId);
        if (friendSocket) {
          friendSocket.emit('game_invitation', { invitation });
        }
      } catch (error) {
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
        const invitations = await invitationService.getInvitations(currentPlayer.userId);
        socket.emit('invitations_list', { invitations });
      } catch (error) {
        socket.emit('invitations_list', { invitations: [] });
      }
    });

    // 초대 수락
    socket.on('accept_invitation', async (data: { invitationId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('accept_invitation_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const invitation = await invitationService.getInvitation(data.invitationId);
        if (!invitation) {
          socket.emit('accept_invitation_result', { success: false, message: '초대를 찾을 수 없습니다.' });
          return;
        }

        // 게임방 생성
        const roomId = `${invitation.gameType}_invite_${Date.now()}`;
        const result = await invitationService.acceptInvitation(data.invitationId, roomId);

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
        const room: GameRoom = {
          id: roomId,
          gameType: invitation.gameType,
          players: [inviterPlayer, currentPlayer],
          game: null,
          status: 'waiting'
        };

        // 게임 초기화
        if (invitation.gameType === 'tictactoe') {
          room.game = new TicTacToeGame();
        } else if (invitation.gameType === 'infinite_tictactoe') {
          room.game = new InfiniteTicTacToeGame();
        }

        rooms.set(roomId, room);

        // 방 참가
        inviterSocket!.join(roomId);
        socket.join(roomId);
        currentRoomId = roomId;

        socket.emit('accept_invitation_result', { success: true, roomId, gameType: invitation.gameType });

        // 초대자에게 수락 알림 (게임 화면으로 이동하도록)
        inviterSocket!.emit('invitation_accepted', {
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
      } catch (error) {
        socket.emit('accept_invitation_result', { success: false, message: '초대 수락 실패' });
      }
    });

    // 초대 거절
    socket.on('decline_invitation', async (data: { invitationId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('decline_invitation_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const invitation = await invitationService.getInvitation(data.invitationId);
        const result = await invitationService.declineInvitation(data.invitationId);
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
      } catch (error) {
        socket.emit('decline_invitation_result', { success: false, message: '초대 거절 실패' });
      }
    });

    // 재대결 요청
    socket.on('rematch_request', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (room && room.status === 'finished') {
        socket.to(data.roomId).emit('rematch_requested', {
          from: currentPlayer?.nickname,
        });
      }
    });

    // 재대결 수락
    socket.on('rematch_accept', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (room && room.status === 'finished') {
        // 게임 리셋
        if (room.gameType === 'tictactoe') {
          room.game = new TicTacToeGame();
        } else if (room.gameType === 'infinite_tictactoe') {
          room.game = new InfiniteTicTacToeGame();
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
    socket.on('leave_room', (data: { roomId: string }) => {
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

    function leaveRoom(socket: Socket, roomId: string) {
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
