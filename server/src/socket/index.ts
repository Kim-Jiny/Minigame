import { Server, Socket } from 'socket.io';
import { TicTacToeGame } from '../games/tictactoe';
import { InfiniteTicTacToeGame } from '../games/infinitetictactoe';
import { GomokuGame } from '../games/gomoku';
import { ReactionGame } from '../games/reaction';
import { RpsGame } from '../games/rps';
import { SpeedTapGame } from '../games/speedtap';
import { SequenceGame } from '../games/sequence';
import { StroopGame } from '../games/stroop';
import { friendService } from '../services/friendService';
import { invitationService } from '../services/invitationService';
import { statsService } from '../services/statsService';
import { messageService } from '../services/messageService';
import { coinService } from '../services/coinService';
import { shopService } from '../services/shopService';

interface Player {
  id: string;
  socket: Socket;
  nickname: string;
  userId?: number;
  avatarUrl?: string;
}

interface GameRoom {
  id: string;
  gameType: string;
  players: Player[];
  game: TicTacToeGame | InfiniteTicTacToeGame | GomokuGame | ReactionGame | RpsGame | SpeedTapGame | SequenceGame | StroopGame | null;
  status: 'waiting' | 'playing' | 'finished';
  rematchRequests?: Set<string>;
  turnTimer?: NodeJS.Timeout;
  turnStartTime?: number;
  isHardcore?: boolean;  // 하드코어 모드 여부
  roundTimer?: NodeJS.Timeout;  // 반응속도/스피드탭 게임용 라운드 타이머
}

// 턴 시간 제한 (밀리초)
const TURN_TIME_LIMIT_NORMAL = 30000; // 30초
const TURN_TIME_LIMIT_HARDCORE = 10000; // 10초 (하드코어)

function getTurnTimeLimit(room: GameRoom): number {
  return room.isHardcore ? TURN_TIME_LIMIT_HARDCORE : TURN_TIME_LIMIT_NORMAL;
}

// 게임방 관리
const rooms = new Map<string, GameRoom>();
// 매칭 대기열 (게임 타입별 + 하드코어 여부)
// key: "tictactoe_normal" 또는 "tictactoe_hardcore"
const matchQueues = new Map<string, Player[]>();
// 유저 ID별 소켓 매핑 (초대 알림용)
const userSockets = new Map<number, Socket>();

function getQueueKey(gameType: string, isHardcore: boolean): string {
  return `${gameType}_${isHardcore ? 'hardcore' : 'normal'}`;
}

// 턴 타이머 시작
function startTurnTimer(io: Server, room: GameRoom) {
  // 기존 타이머 정리
  if (room.turnTimer) {
    clearTimeout(room.turnTimer);
  }

  room.turnStartTime = Date.now();
  const timeLimit = getTurnTimeLimit(room);

  room.turnTimer = setTimeout(() => {
    handleTurnTimeout(io, room);
  }, timeLimit);
}

// 턴 타이머 정리
function clearTurnTimer(room: GameRoom) {
  if (room.turnTimer) {
    clearTimeout(room.turnTimer);
    room.turnTimer = undefined;
  }
  room.turnStartTime = undefined;
}

// 반응속도 게임 라운드 타이머 정리
function clearRoundTimer(room: GameRoom) {
  if (room.roundTimer) {
    clearTimeout(room.roundTimer);
    room.roundTimer = undefined;
  }
}

// 반응속도 게임 라운드 시작
function startReactionRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'reaction' || !(room.game instanceof ReactionGame)) return;

  const game = room.game;
  const { delay } = game.startRound();

  // 라운드 준비 상태 전송
  io.to(room.id).emit('reaction_round_ready', {
    round: game.getCurrentRound(),
    scores: game.getScores(),
  });

  console.log(`🚦 Round ${game.getCurrentRound()} ready, go in ${delay}ms`);

  // 랜덤 시간 후 GO!
  room.roundTimer = setTimeout(() => {
    game.setGo();
    io.to(room.id).emit('reaction_round_go', {
      round: game.getCurrentRound(),
    });
    console.log(`🟢 Round ${game.getCurrentRound()} GO!`);

    // 5초 내에 아무도 안 누르면 무승부 처리
    room.roundTimer = setTimeout(() => {
      if (game.getRoundState() === 'go') {
        io.to(room.id).emit('reaction_round_timeout', {
          round: game.getCurrentRound(),
        });

        // 게임 종료 체크
        if (game.isGameOver()) {
          finishReactionGame(io, room);
        } else {
          // 다음 라운드 시작 (1초 후)
          setTimeout(() => startReactionRound(io, room), 1000);
        }
      }
    }, 5000);
  }, delay);
}

// 반응속도 게임 종료 처리
async function finishReactionGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof ReactionGame)) return;

  room.status = 'finished';
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const scores = game.getScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  // 코인/연승 보상 결과 저장
  const rewardResults: { [key: string]: any } = {};

  // 통계 및 코인 업데이트
  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) {
        gameResult = 'draw';
      } else if (winnerIndex === i) {
        gameResult = 'win';
      } else {
        gameResult = 'loss';
      }
      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
        }

        // 코인/연승 처리
        if (opponent.userId) {
          const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        }
      } catch (err) {
        console.error('Failed to update stats:', err);
      }
    }
  }

  io.to(room.id).emit('game_end', {
    winner: winnerId,
    winnerNickname,
    isDraw,
    scores,
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 Reaction game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]}-${scores[1]})`);
}

// 가위바위보 라운드 시작
function startRpsRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'rps' || !(room.game instanceof RpsGame)) return;

  const game = room.game;
  game.startRound();

  const RPS_TIME_LIMIT = 10000; // 10초

  // 라운드 시작 알림
  io.to(room.id).emit('rps_round_start', {
    round: game.getCurrentRound(),
    scores: game.getScores(),
    timeLimit: RPS_TIME_LIMIT,
  });

  console.log(`✊ RPS Round ${game.getCurrentRound()} started`);

  // 10초 타임아웃 (선택 안 한 사람은 랜덤 선택)
  room.roundTimer = setTimeout(() => {
    if (!game.isGameOver() && (!game.hasChosen(0) || !game.hasChosen(1))) {
      // 선택 안 한 플레이어는 랜덤으로 선택
      if (!game.hasChosen(0)) {
        const randomChoice = game.setRandomChoice(0);
        console.log(`⏰ Player 0 timeout - random choice: ${randomChoice}`);
      }
      if (!game.hasChosen(1)) {
        const randomChoice = game.setRandomChoice(1);
        console.log(`⏰ Player 1 timeout - random choice: ${randomChoice}`);
      }

      // 라운드 결과 계산
      const roundResult = game.calculateRoundResult();
      const winner = roundResult.roundWinner !== null ? room.players[roundResult.roundWinner] : null;

      io.to(room.id).emit('rps_round_result', {
        round: game.getCurrentRound(),
        player0Choice: roundResult.player0Choice,
        player1Choice: roundResult.player1Choice,
        winnerIndex: roundResult.roundWinner,
        winnerId: winner?.id ?? null,
        winnerNickname: winner?.nickname ?? null,
        isDraw: roundResult.isDraw,
        isTimeout: true,
        scores: game.getScores(),
      });

      // 게임 종료 체크
      if (roundResult.gameOver) {
        finishRpsGame(io, room);
      } else {
        // 다음 라운드 시작
        setTimeout(() => startRpsRound(io, room), 2000);
      }
    }
  }, RPS_TIME_LIMIT);
}

// 가위바위보 게임 종료 처리
async function finishRpsGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof RpsGame)) return;

  room.status = 'finished';
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const scores = game.getScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  // 코인/연승 보상 결과 저장
  const rewardResults: { [key: string]: any } = {};

  // 통계 및 코인 업데이트
  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) {
        gameResult = 'draw';
      } else if (winnerIndex === i) {
        gameResult = 'win';
      } else {
        gameResult = 'loss';
      }
      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
        }

        // 코인/연승 처리
        if (opponent.userId) {
          const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        }
      } catch (err) {
        console.error('Failed to update stats:', err);
      }
    }
  }

  io.to(room.id).emit('game_end', {
    winner: winnerId,
    winnerNickname,
    isDraw,
    scores,
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 RPS game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]}-${scores[1]})`);
}

// 스피드탭 라운드 시작 (3초 카운트다운 후)
function startSpeedTapRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'speedtap' || !(room.game instanceof SpeedTapGame)) return;

  const game = room.game;
  game.startRound();

  const roundNum = game.getCurrentRound();
  const roundScores = game.getRoundScores();

  // 카운트다운 시작 알림
  io.to(room.id).emit('speedtap_countdown', {
    round: roundNum,
    roundScores: roundScores,
    countdown: 3,
  });

  console.log(`👆 SpeedTap Round ${roundNum} countdown started`);

  // 3초 후 실제 라운드 시작
  setTimeout(() => {
    // 방이 아직 유효한지 확인
    if (room.status !== 'playing') return;

    io.to(room.id).emit('speedtap_round_start', {
      round: roundNum,
      roundScores: roundScores,
      duration: SpeedTapGame.ROUND_TIME,
    });

    console.log(`👆 SpeedTap Round ${roundNum} started`);

    // 라운드 종료 타이머
    room.roundTimer = setTimeout(() => {
      endSpeedTapRound(io, room);
    }, SpeedTapGame.ROUND_TIME);
  }, 3000);
}

// 스피드탭 라운드 종료
async function endSpeedTapRound(io: Server, room: GameRoom) {
  if (!(room.game instanceof SpeedTapGame)) return;

  clearRoundTimer(room);
  const game = room.game;
  const result = game.endRound();

  const winner = result.roundWinner !== null ? room.players[result.roundWinner] : null;

  io.to(room.id).emit('speedtap_round_result', {
    round: game.getCurrentRound(),
    player0Taps: result.player0Taps,
    player1Taps: result.player1Taps,
    roundWinner: result.roundWinner,
    winnerId: winner?.id ?? null,
    winnerNickname: winner?.nickname ?? null,
    isDraw: result.isDraw,
    roundScores: game.getRoundScores(),
  });

  console.log(`👆 SpeedTap Round ${game.getCurrentRound()} ended: ${result.player0Taps} vs ${result.player1Taps}`);

  if (result.gameOver) {
    await finishSpeedTapGame(io, room);
  } else {
    // 2초 후 다음 라운드 시작
    setTimeout(() => startSpeedTapRound(io, room), 2000);
  }
}

// 스피드탭 게임 종료 처리
async function finishSpeedTapGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof SpeedTapGame)) return;

  room.status = 'finished';
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const roundScores = game.getRoundScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  // 코인/연승 보상 결과 저장
  const rewardResults: { [key: string]: any } = {};

  // 통계 및 코인 업데이트
  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) {
        gameResult = 'draw';
      } else if (winnerIndex === i) {
        gameResult = 'win';
      } else {
        gameResult = 'loss';
      }
      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
        }

        // 코인/연승 처리
        if (opponent.userId) {
          const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        }
      } catch (err) {
        console.error('Failed to update stats:', err);
      }
    }
  }

  io.to(room.id).emit('game_end', {
    winner: winnerId,
    winnerNickname,
    isDraw,
    roundScores,
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 SpeedTap game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${roundScores[0]}-${roundScores[1]})`);
}

// 순서 기억하기 라운드 시작
function startSequenceRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'sequence' || !(room.game instanceof SequenceGame)) return;

  const game = room.game;
  const { sequence, level } = game.startNewRound();
  const timeLimit = game.getTimeLimit();
  const showDelay = game.getShowDelay();
  const gapDuration = game.getIsHardcore() ? 100 : 180;

  // 시퀀스 보여주는 데 걸리는 시간 계산
  const showDuration = sequence.length * (showDelay + gapDuration) + 500; // 시작 딜레이 포함

  // 시퀀스 보여주기 이벤트
  io.to(room.id).emit('sequence_show', {
    sequence,
    level,
    showDelay,
    timeLimit,
  });

  console.log(`🧠 Sequence Level ${level} started (length: ${sequence.length}, timeLimit: ${timeLimit}ms)`);

  // 시퀀스 표시 후 + 제한시간 후 타임아웃 체크
  clearRoundTimer(room);
  room.roundTimer = setTimeout(async () => {
    // 완료하지 못한 플레이어들 타임아웃 처리
    for (let i = 0; i < 2; i++) {
      const inputs = game.getPlayerInputs()[i];
      const failed = game.getPlayerFailed()[i];
      if (!failed && inputs.length < sequence.length) {
        game.handleTimeout(i);
        io.to(room.id).emit('sequence_timeout', {
          playerIndex: i,
        });
        console.log(`⏰ Player ${i} timed out on level ${level}`);
      }
    }

    // 라운드 결과 확인
    if (game.bothPlayersCompleted()) {
      const roundResult = game.checkRoundResult();
      if (roundResult.gameOver) {
        await finishSequenceGame(io, room);
      } else if (roundResult.bothPassed) {
        io.to(room.id).emit('sequence_round_complete', {
          success: true,
          nextLevel: game.getCurrentLevel() + 1,
        });
        setTimeout(() => startSequenceRound(io, room), 2000);
      }
    }
  }, showDuration + timeLimit);
}

// 순서 기억하기 게임 종료 처리
async function finishSequenceGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof SequenceGame)) return;

  room.status = 'finished';
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const maxLevels = game.getPlayerMaxLevel();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  // 코인/연승 보상 결과 저장
  const rewardResults: { [key: string]: any } = {};

  // 통계 및 코인 업데이트
  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) {
        gameResult = 'draw';
      } else if (winnerIndex === i) {
        gameResult = 'win';
      } else {
        gameResult = 'loss';
      }
      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
        }

        // 코인/연승 처리
        if (opponent.userId) {
          const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        }
      } catch (err) {
        console.error('Failed to update stats:', err);
      }
    }
  }

  io.to(room.id).emit('game_end', {
    winner: winnerId,
    winnerNickname,
    isDraw,
    maxLevels,
    player0Level: maxLevels[0],
    player1Level: maxLevels[1],
    rewards: rewardResults,
  });

  console.log(`🏆 Sequence game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (Levels: ${maxLevels[0]} vs ${maxLevels[1]})`);
}

// 스트룹 게임 라운드 시작
function startStroopRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'stroop' || !(room.game instanceof StroopGame)) return;

  const game = room.game;
  const { word, color, round } = game.startRound();

  // 라운드 시작 알림
  io.to(room.id).emit('stroop_show', {
    word,
    color,
    round,
    scores: game.getScores(),
    isHardcore: game.getIsHardcore(),
    colors: game.getColors(),
  });

  console.log(`🎨 Stroop Round ${round}: "${word}" displayed in ${color}`);

  // 하드코어 모드: 시간 제한
  if (game.getIsHardcore()) {
    room.roundTimer = setTimeout(() => {
      if (game.getRoundState() === 'showing') {
        const timeoutResult = game.handleTimeout();

        const roundWinner = timeoutResult.roundWinner !== null ? room.players[timeoutResult.roundWinner] : null;

        io.to(room.id).emit('stroop_result', {
          round: game.getCurrentRound(),
          winnerId: roundWinner?.id ?? null,
          winnerNickname: roundWinner?.nickname ?? null,
          scores: game.getScores(),
          correctAnswer: game.getCurrentColor(),
          isTimeout: true,
        });

        console.log(`⏰ Stroop Round ${game.getCurrentRound()} timeout`);

        if (timeoutResult.gameOver) {
          finishStroopGame(io, room);
        } else {
          // 다음 라운드 시작 (2초 후)
          setTimeout(() => startStroopRound(io, room), 2000);
        }
      }
    }, StroopGame.TIME_LIMIT_HARDCORE);
  }
}

// 스트룹 게임 종료 처리
async function finishStroopGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof StroopGame)) return;

  room.status = 'finished';
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const scores = game.getScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  // 코인/연승 보상 결과 저장
  const rewardResults: { [key: string]: any } = {};

  // 통계 및 코인 업데이트
  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) {
        gameResult = 'draw';
      } else if (winnerIndex === i) {
        gameResult = 'win';
      } else {
        gameResult = 'loss';
      }
      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
        }

        // 코인/연승 처리
        if (opponent.userId) {
          const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        }
      } catch (err) {
        console.error('Failed to update stats:', err);
      }
    }
  }

  io.to(room.id).emit('game_end', {
    winner: winnerId,
    winnerNickname,
    isDraw,
    scores,
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 Stroop game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]}-${scores[1]})`);
}

// 시간 초과 처리 - 랜덤 위치에 두기 (턴제 게임 전용)
async function handleTurnTimeout(io: Server, room: GameRoom) {
  if (room.status !== 'playing' || !room.game) return;

  // 반응속도 게임은 턴 타임아웃 없음
  if (room.gameType === 'reaction') return;

  // 타입 가드: 턴제 게임만 처리
  if (!(room.game instanceof TicTacToeGame || room.game instanceof InfiniteTicTacToeGame || room.game instanceof GomokuGame)) {
    return;
  }

  const currentPlayerIndex = room.game.getCurrentPlayer();
  const currentPlayer = room.players[currentPlayerIndex];

  // 빈 칸 찾기
  const board = room.game.getBoard();
  const emptyPositions: number[] = [];
  for (let i = 0; i < board.length; i++) {
    if (board[i] === null) {
      emptyPositions.push(i);
    }
  }

  if (emptyPositions.length === 0) return;

  // 랜덤 위치 선택
  const randomPosition = emptyPositions[Math.floor(Math.random() * emptyPositions.length)];

  console.log(`⏰ Turn timeout: ${currentPlayer.nickname} - random move to position ${randomPosition}`);

  // 게임 진행
  const result = room.game.makeMove(randomPosition, currentPlayerIndex);

  if (!result.valid) {
    console.error('Random move failed:', result.message);
    return;
  }

  // 타임아웃 알림
  io.to(room.id).emit('turn_timeout', {
    playerId: currentPlayer.id,
    playerNickname: currentPlayer.nickname,
    position: randomPosition,
  });

  // 게임 상태 업데이트
  if (room.gameType === 'infinite_tictactoe' && room.game instanceof InfiniteTicTacToeGame) {
    const infiniteResult = result as { valid: boolean; gameOver?: boolean; winner?: number | null; removedPosition?: number };
    io.to(room.id).emit('game_update', {
      board: room.game.getBoard(),
      currentTurn: room.players[room.game.getCurrentPlayer()].id,
      lastMove: randomPosition,
      removedPosition: infiniteResult.removedPosition,
      moveHistory: room.game.getMoveHistory(),
      turnTimeLimit: getTurnTimeLimit(room),
      turnStartTime: Date.now(),
    });
  } else {
    io.to(room.id).emit('game_update', {
      board: room.game.getBoard(),
      currentTurn: room.players[room.game.getCurrentPlayer()].id,
      lastMove: randomPosition,
      turnTimeLimit: getTurnTimeLimit(room),
      turnStartTime: Date.now(),
    });
  }

  // 게임 종료 체크
  if (result.gameOver) {
    room.status = 'finished';
    clearTurnTimer(room);

    const winnerId = result.winner !== undefined && result.winner !== null
      ? room.players[result.winner].id
      : null;
    const winnerNickname = result.winner !== undefined && result.winner !== null
      ? room.players[result.winner].nickname
      : null;

    // 통계 업데이트
    for (let i = 0; i < room.players.length; i++) {
      const player = room.players[i];
      const opponent = room.players[i === 0 ? 1 : 0];
      if (player.userId) {
        let gameResult: 'win' | 'loss' | 'draw';
        if (result.isDraw) {
          gameResult = 'draw';
        } else if (result.winner === i) {
          gameResult = 'win';
        } else {
          gameResult = 'loss';
        }
        try {
          const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
          player.socket.emit('stats_updated', { stats });
          if (i === 0 && opponent.userId) {
            await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
          }
        } catch (err) {
          console.error('Failed to update stats:', err);
        }
      }
    }

    io.to(room.id).emit('game_end', {
      winner: winnerId,
      winnerNickname: winnerNickname,
      isDraw: result.isDraw || false,
      board: room.game.getBoard(),
    });
  } else {
    // 다음 턴 타이머 시작
    startTurnTimer(io, room);
  }
}

export function setupSocketHandlers(io: Server) {
  io.on('connection', (socket: Socket) => {
    console.log(`👤 Player connected: ${socket.id}`);

    // 플레이어 정보
    let currentPlayer: Player | null = null;
    let currentRoomId: string | null = null;

    // 로비 입장
    socket.on('join_lobby', async (data: { nickname: string; userId?: number; avatarUrl?: string }) => {
      console.log(`📥 join_lobby received:`, { nickname: data.nickname, userId: data.userId });

      currentPlayer = {
        id: socket.id,
        socket,
        nickname: data.nickname,
        userId: data.userId,
        avatarUrl: data.avatarUrl,
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
    socket.on('find_match', async (data: { gameType: string; isHardcore?: boolean }) => {
      if (!currentPlayer) {
        socket.emit('error', { message: 'Please join lobby first' });
        return;
      }

      const { gameType, isHardcore = false } = data;
      const queueKey = getQueueKey(gameType, isHardcore);

      if (!matchQueues.has(queueKey)) {
        matchQueues.set(queueKey, []);
      }

      const queue = matchQueues.get(queueKey)!;

      // 이미 대기열에 상대가 있으면 매칭
      if (queue.length > 0) {
        const opponent = queue.shift()!;

        // 방 생성
        const roomId = `${gameType}_${isHardcore ? 'hc_' : ''}${Date.now()}`;
        const room: GameRoom = {
          id: roomId,
          gameType,
          players: [opponent, currentPlayer],
          game: null,
          status: 'waiting',
          isHardcore,
        };

        // 게임 초기화
        if (gameType === 'tictactoe') {
          room.game = new TicTacToeGame();
        } else if (gameType === 'infinite_tictactoe') {
          room.game = new InfiniteTicTacToeGame();
        } else if (gameType === 'gomoku') {
          room.game = new GomokuGame();
        } else if (gameType === 'reaction') {
          room.game = new ReactionGame();
        } else if (gameType === 'rps') {
          room.game = new RpsGame();
        } else if (gameType === 'speedtap') {
          room.game = new SpeedTapGame();
        } else if (gameType === 'sequence') {
          room.game = new SequenceGame(isHardcore);
        } else if (gameType === 'stroop') {
          room.game = new StroopGame(isHardcore);
        }

        rooms.set(roomId, room);

        // 두 플레이어를 방에 조인
        opponent.socket.join(roomId);
        socket.join(roomId);
        currentRoomId = roomId;

        // 연승 정보 조회
        const opponentStreak = opponent.userId ? await coinService.getStreak(opponent.userId) : { currentStreak: 0 };
        const currentPlayerStreak = currentPlayer.userId ? await coinService.getStreak(currentPlayer.userId) : { currentStreak: 0 };

        // 프로필 설정 조회
        const opponentProfile = opponent.userId ? await shopService.getUserProfileSettings(opponent.userId) : null;
        const currentPlayerProfile = currentPlayer.userId ? await shopService.getUserProfileSettings(currentPlayer.userId) : null;

        // 오늘 서로 몇 번 만났는지
        let dailyMatchCount = 0;
        if (opponent.userId && currentPlayer.userId) {
          dailyMatchCount = await coinService.getDailyMatchCount(currentPlayer.userId, opponent.userId);
        }

        // 매칭 성공 알림
        io.to(roomId).emit('match_found', {
          roomId,
          gameType,
          isHardcore,
          players: [
            { id: opponent.id, nickname: opponent.nickname, userId: opponent.userId, avatarUrl: opponent.avatarUrl, streak: opponentStreak.currentStreak, profileSettings: opponentProfile },
            { id: currentPlayer.id, nickname: currentPlayer.nickname, userId: currentPlayer.userId, avatarUrl: currentPlayer.avatarUrl, streak: currentPlayerStreak.currentStreak, profileSettings: currentPlayerProfile },
          ],
          dailyMatchCount: dailyMatchCount + 1,  // 이번 게임 포함
        });

        console.log(`🎯 Match found: ${opponent.nickname} vs ${currentPlayer.nickname} ${isHardcore ? '(하드코어)' : ''}`);
        console.log(`🎮 gameType: '${gameType}'`);

        // 게임 시작
        room.status = 'playing';

        if (gameType === 'reaction') {
          // 반응속도 게임은 별도 시작 로직
          io.to(roomId).emit('game_start', {
            gameType: 'reaction',
          });
          // 1초 후 첫 라운드 시작
          setTimeout(() => startReactionRound(io, room), 1000);
        } else if (gameType === 'rps') {
          // 가위바위보 게임
          io.to(roomId).emit('game_start', {
            gameType: 'rps',
          });
          // 1초 후 첫 라운드 시작
          setTimeout(() => startRpsRound(io, room), 1000);
        } else if (gameType === 'speedtap') {
          // 스피드탭 게임
          io.to(roomId).emit('game_start', {
            gameType: 'speedtap',
          });
          // 1초 후 첫 라운드 시작
          setTimeout(() => startSpeedTapRound(io, room), 1000);
        } else if (gameType === 'sequence') {
          // 순서 기억하기 게임
          const seqGame = room.game as SequenceGame;
          io.to(roomId).emit('game_start', {
            gameType: 'sequence',
            gridSize: seqGame.getGridSize(),
            sequence: seqGame.getSequence(),
            level: seqGame.getCurrentLevel(),
            showDelay: seqGame.getShowDelay(),
            isHardcore: seqGame.getIsHardcore(),
            timeLimit: seqGame.getTimeLimit(),
          });
        } else if (gameType === 'stroop') {
          // 스트룹 게임
          const stroopGame = room.game as StroopGame;
          io.to(roomId).emit('game_start', {
            gameType: 'stroop',
            isHardcore: stroopGame.getIsHardcore(),
            colors: stroopGame.getColors(),
          });
          // 1초 후 첫 라운드 시작
          setTimeout(() => startStroopRound(io, room), 1000);
        } else {
          // 턴제 게임
          startTurnTimer(io, room);
          const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
          io.to(roomId).emit('game_start', {
            currentTurn: opponent.id, // 첫 번째 플레이어가 선공
            board: turnGame?.getBoard(),
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime: room.turnStartTime,
          });
        }
      } else {
        // 대기열에 추가
        queue.push(currentPlayer);
        socket.emit('waiting_for_match', { gameType, isHardcore });
        console.log(`⏳ ${currentPlayer.nickname} waiting for match (${gameType}${isHardcore ? ' 하드코어' : ''})`);
      }
    });

    // 매칭 취소
    socket.on('cancel_match', (data: { gameType: string; isHardcore?: boolean }) => {
      const { gameType, isHardcore = false } = data;
      const queueKey = getQueueKey(gameType, isHardcore);
      const queue = matchQueues.get(queueKey);
      if (queue) {
        const index = queue.findIndex(p => p.id === socket.id);
        if (index !== -1) {
          queue.splice(index, 1);
          socket.emit('match_cancelled');
        }
      }
    });

    // 게임 액션 (틱택토: 셀 클릭)
    socket.on('game_action', async (data: { roomId: string; action: any }) => {
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

        // 타이머 정리 및 재시작
        clearTurnTimer(room);

        // 게임 종료 체크
        if (result.gameOver) {
          room.status = 'finished';
          const winnerId = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].id
            : null;
          const winnerNickname = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].nickname
            : null;

          // 코인/연승 보상 결과 저장
          const rewardResults: { [key: string]: any } = {};

          // 통계 업데이트 및 기록 저장
          for (let i = 0; i < room.players.length; i++) {
            const player = room.players[i];
            const opponent = room.players[i === 0 ? 1 : 0];
            if (player.userId) {
              let gameResult: 'win' | 'loss' | 'draw';
              if (result.isDraw) {
                gameResult = 'draw';
              } else if (result.winner === i) {
                gameResult = 'win';
              } else {
                gameResult = 'loss';
              }
              try {
                const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
                player.socket.emit('stats_updated', { stats });

                // 게임 기록 저장 (첫 번째 플레이어만 저장하면 됨)
                if (i === 0 && opponent.userId) {
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
                }

                // 코인/연승 처리
                if (opponent.userId) {
                  const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
                  rewardResults[player.id] = reward;
                  player.socket.emit('coins_updated', {
                    coins: reward.totalCoins,
                    earned: reward.coinsEarned,
                    streak: reward.streakAfter,
                    streakBonus: reward.streakBonusEarned,
                  });
                }
              } catch (err) {
                console.error('Failed to update stats:', err);
              }
            }
          }

          io.to(data.roomId).emit('game_end', {
            winner: winnerId,
            winnerNickname: winnerNickname,
            isDraw: result.isDraw,
            board: room.game.getBoard(),
            rewards: rewardResults,
          });
          console.log(`🏆 Game ended: ${result.isDraw ? 'Draw' : winnerNickname + ' wins'}`);
        } else {
          // 게임 계속 - 다음 턴 타이머 시작
          startTurnTimer(io, room);

          // 게임 상태 업데이트 브로드캐스트
          io.to(data.roomId).emit('game_update', {
            board: room.game.getBoard(),
            currentTurn: room.players[room.game.getCurrentPlayer()].id,
            lastMove: data.action.position,
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime: room.turnStartTime,
          });
        }
      }

      // 무한 틱택토 게임 로직
      if (room.gameType === 'infinite_tictactoe' && room.game instanceof InfiniteTicTacToeGame) {
        const result = room.game.makeMove(data.action.position, playerIndex);

        if (!result.valid) {
          socket.emit('error', { message: result.message });
          return;
        }

        // 타이머 정리
        clearTurnTimer(room);

        // 게임 종료 체크
        if (result.gameOver) {
          room.status = 'finished';
          const winnerId = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].id
            : null;
          const winnerNickname = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].nickname
            : null;

          // 코인/연승 보상 결과 저장
          const rewardResults: { [key: string]: any } = {};

          // 통계 업데이트 및 기록 저장
          for (let i = 0; i < room.players.length; i++) {
            const player = room.players[i];
            const opponent = room.players[i === 0 ? 1 : 0];
            if (player.userId) {
              const gameResult: 'win' | 'loss' = result.winner === i ? 'win' : 'loss';
              try {
                const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
                player.socket.emit('stats_updated', { stats });

                // 게임 기록 저장 (첫 번째 플레이어만 저장하면 됨)
                if (i === 0 && opponent.userId) {
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
                }

                // 코인/연승 처리
                if (opponent.userId) {
                  const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
                  rewardResults[player.id] = reward;
                  player.socket.emit('coins_updated', {
                    coins: reward.totalCoins,
                    earned: reward.coinsEarned,
                    streak: reward.streakAfter,
                    streakBonus: reward.streakBonusEarned,
                  });
                }
              } catch (err) {
                console.error('Failed to update stats:', err);
              }
            }
          }

          io.to(data.roomId).emit('game_end', {
            winner: winnerId,
            winnerNickname: winnerNickname,
            isDraw: false,  // 무한 틱택토는 무승부 없음
            board: room.game.getBoard(),
            rewards: rewardResults,
          });
          console.log(`🏆 Infinite TicTacToe ended: ${winnerNickname} wins`);
        } else {
          // 게임 계속 - 다음 턴 타이머 시작
          startTurnTimer(io, room);

          // 게임 상태 업데이트 브로드캐스트
          io.to(data.roomId).emit('game_update', {
            board: room.game.getBoard(),
            currentTurn: room.players[room.game.getCurrentPlayer()].id,
            lastMove: data.action.position,
            removedPosition: result.removedPosition,
            moveHistory: room.game.getMoveHistory(),
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime: room.turnStartTime,
          });
        }
      }

      // 오목 게임 로직
      if (room.gameType === 'gomoku' && room.game instanceof GomokuGame) {
        const result = room.game.makeMove(data.action.position, playerIndex);

        if (!result.valid) {
          socket.emit('error', { message: result.message });
          return;
        }

        // 타이머 정리 및 재시작
        clearTurnTimer(room);

        // 게임 종료 체크
        if (result.gameOver) {
          room.status = 'finished';
          const winnerId = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].id
            : null;
          const winnerNickname = result.winner !== undefined && result.winner !== null
            ? room.players[result.winner].nickname
            : null;

          // 코인/연승 보상 결과 저장
          const rewardResults: { [key: string]: any } = {};

          // 통계 업데이트 및 기록 저장
          for (let i = 0; i < room.players.length; i++) {
            const player = room.players[i];
            const opponent = room.players[i === 0 ? 1 : 0];
            if (player.userId) {
              let gameResult: 'win' | 'loss' | 'draw';
              if (result.isDraw) {
                gameResult = 'draw';
              } else if (result.winner === i) {
                gameResult = 'win';
              } else {
                gameResult = 'loss';
              }
              try {
                const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
                player.socket.emit('stats_updated', { stats });

                // 게임 기록 저장 (첫 번째 플레이어만 저장하면 됨)
                if (i === 0 && opponent.userId) {
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult);
                }

                // 코인/연승 처리
                if (opponent.userId) {
                  const reward = await coinService.processGameReward(player.userId, opponent.userId, gameResult);
                  rewardResults[player.id] = reward;
                  player.socket.emit('coins_updated', {
                    coins: reward.totalCoins,
                    earned: reward.coinsEarned,
                    streak: reward.streakAfter,
                    streakBonus: reward.streakBonusEarned,
                  });
                }
              } catch (err) {
                console.error('Failed to update stats:', err);
              }
            }
          }

          io.to(data.roomId).emit('game_end', {
            winner: winnerId,
            winnerNickname: winnerNickname,
            isDraw: result.isDraw,
            board: room.game.getBoard(),
            rewards: rewardResults,
          });
          console.log(`🏆 Gomoku ended: ${result.isDraw ? 'Draw' : winnerNickname + ' wins'}`);
        } else {
          // 게임 계속 - 다음 턴 타이머 시작
          startTurnTimer(io, room);

          // 게임 상태 업데이트 브로드캐스트
          io.to(data.roomId).emit('game_update', {
            board: room.game.getBoard(),
            currentTurn: room.players[room.game.getCurrentPlayer()].id,
            lastMove: data.action.position,
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime: room.turnStartTime,
          });
        }
      }

      // 반응속도 게임 로직
      if (room.gameType === 'reaction' && room.game instanceof ReactionGame) {
        const result = room.game.playerPressed(playerIndex);

        if (!result.valid) {
          return; // 이미 눌렀거나 라운드가 진행 중이 아님
        }

        // 라운드 타이머 정리
        clearRoundTimer(room);

        // 라운드 결과 전송
        io.to(data.roomId).emit('reaction_round_result', {
          round: room.game.getCurrentRound(),
          falseStart: result.falseStart,
          winnerId: result.roundWinner !== undefined ? room.players[result.roundWinner].id : null,
          winnerNickname: result.roundWinner !== undefined ? room.players[result.roundWinner].nickname : null,
          reactionTime: result.reactionTime,
          scores: room.game.getScores(),
          pressedPlayerId: socket.id,
          pressedPlayerNickname: currentPlayer?.nickname,
        });

        if (result.falseStart) {
          console.log(`🔴 False start by ${currentPlayer?.nickname}!`);
        } else {
          console.log(`⚡ ${currentPlayer?.nickname} pressed in ${result.reactionTime}ms!`);
        }

        // 게임 종료 체크
        if (result.gameOver) {
          await finishReactionGame(io, room);
        } else {
          // 다음 라운드 시작 (2초 후)
          setTimeout(() => startReactionRound(io, room), 2000);
        }
      }

      // 가위바위보 게임 로직
      if (room.gameType === 'rps' && room.game instanceof RpsGame) {
        const choice = data.action.choice; // 'rock', 'paper', 'scissors'
        const result = room.game.makeChoice(playerIndex, choice);

        if (!result.valid) {
          return; // 이미 선택했거나 게임 종료
        }

        // 상대에게 내가 선택했다고 알림 (선택 내용은 안 보여줌)
        io.to(data.roomId).emit('rps_player_chosen', {
          playerId: socket.id,
          playerNickname: currentPlayer?.nickname,
        });

        console.log(`✊ ${currentPlayer?.nickname} chose ${choice}`);

        // 둘 다 선택했으면 결과 계산
        if (result.bothChosen) {
          // 라운드 타이머 정리
          clearRoundTimer(room);

          const roundResult = room.game.calculateRoundResult();

          // 라운드 결과 전송
          io.to(data.roomId).emit('rps_round_result', {
            round: room.game.getCurrentRound(),
            player0Choice: roundResult.player0Choice,
            player1Choice: roundResult.player1Choice,
            winnerIndex: roundResult.roundWinner,
            winnerId: roundResult.roundWinner !== null ? room.players[roundResult.roundWinner].id : null,
            winnerNickname: roundResult.roundWinner !== null ? room.players[roundResult.roundWinner].nickname : null,
            isDraw: roundResult.isDraw,
            scores: room.game.getScores(),
          });

          if (roundResult.isDraw) {
            console.log(`🤝 Round ${room.game.getCurrentRound()} is a draw!`);
          } else {
            console.log(`✊ Round ${room.game.getCurrentRound()}: ${room.players[roundResult.roundWinner!].nickname} wins!`);
          }

          // 게임 종료 체크
          if (roundResult.gameOver) {
            await finishRpsGame(io, room);
          } else {
            // 다음 라운드 시작 (2초 후)
            setTimeout(() => startRpsRound(io, room), 2000);
          }
        }
      }

      // 스피드탭 게임 로직
      if (room.gameType === 'speedtap' && room.game instanceof SpeedTapGame) {
        const result = room.game.tap(playerIndex);

        if (result.valid) {
          // 탭 카운트 업데이트 브로드캐스트
          io.to(data.roomId).emit('speedtap_tap', {
            playerId: socket.id,
            playerIndex,
            tapCount: result.tapCount,
            taps: room.game.getTaps(),
          });
        }
      }

      // 순서 기억하기 게임 로직
      if (room.gameType === 'sequence' && room.game instanceof SequenceGame) {
        const position = data.action.position as number;
        const result = room.game.handleInput(playerIndex, position);

        if (result.valid) {
          // 입력 결과 전송
          io.to(data.roomId).emit('sequence_input', {
            playerId: socket.id,
            playerIndex,
            position,
            correct: result.correct,
            inputIndex: result.inputIndex,
            completed: result.completed,
            failed: result.failed,
          });

          // 둘 다 현재 라운드 완료했는지 확인
          if (room.game.bothPlayersCompleted()) {
            const roundResult = room.game.checkRoundResult();

            if (roundResult.gameOver) {
              // 게임 종료
              await finishSequenceGame(io, room);
            } else if (roundResult.bothPassed) {
              // 둘 다 성공 - 다음 라운드 (2초 후)
              io.to(data.roomId).emit('sequence_round_complete', {
                success: true,
                nextLevel: room.game.getCurrentLevel() + 1,
              });
              setTimeout(() => startSequenceRound(io, room), 2000);
            }
          }
        }
      }

      // 스트룹 게임 로직
      if (room.gameType === 'stroop' && room.game instanceof StroopGame) {
        const selectedColor = data.action.selectedColor as string;
        const result = room.game.playerAnswer(playerIndex, selectedColor);

        if (!result.valid) {
          return; // 이미 답변했거나 라운드가 진행 중이 아님
        }

        // 타이머 정리 (하드코어 모드)
        if (room.game.getIsHardcore()) {
          clearRoundTimer(room);
        }

        // 라운드 종료 시
        if (result.roundOver) {
          const roundWinner = result.roundWinner !== null ? room.players[result.roundWinner] : null;

          io.to(data.roomId).emit('stroop_result', {
            round: room.game.getCurrentRound(),
            winnerId: roundWinner?.id ?? null,
            winnerNickname: roundWinner?.nickname ?? null,
            correct: result.correct,
            first: result.first,
            scores: room.game.getScores(),
            correctAnswer: room.game.getCurrentColor(),
            pressedPlayerId: socket.id,
            pressedPlayerNickname: currentPlayer?.nickname,
          });

          if (result.correct && result.first) {
            console.log(`🎨 ${currentPlayer?.nickname} got it right first!`);
          } else if (!result.correct) {
            console.log(`🎨 ${currentPlayer?.nickname} got it wrong!`);
          }

          // 게임 종료 체크
          if (result.gameOver) {
            await finishStroopGame(io, room);
          } else {
            // 다음 라운드 시작 (2초 후)
            setTimeout(() => startStroopRound(io, room), 2000);
          }
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

    // 친구 요청 보내기 (친구 코드로)
    socket.on('send_friend_request', async (data: { friendCode: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_request_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.sendFriendRequest(currentPlayer.userId, data.friendCode);
        socket.emit('friend_request_result', result);

        // 상대방에게 친구 요청 알림
        if (result.success && result.toUserId) {
          const friendSocket = userSockets.get(result.toUserId);
          if (friendSocket) {
            friendSocket.emit('friend_request_received', {
              fromUserId: currentPlayer.userId,
              fromNickname: currentPlayer.nickname
            });
          }
        }
      } catch (error) {
        socket.emit('friend_request_result', { success: false, message: '친구 요청 실패' });
      }
    });

    // 친구 요청 보내기 (유저 ID로 - 게임에서 만난 상대)
    socket.on('send_friend_request_by_user_id', async (data: { friendUserId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_request_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.sendFriendRequestByUserId(currentPlayer.userId, data.friendUserId);
        socket.emit('friend_request_result', result);

        // 상대방에게 친구 요청 알림
        if (result.success && result.toUserId) {
          const friendSocket = userSockets.get(result.toUserId);
          if (friendSocket) {
            friendSocket.emit('friend_request_received', {
              fromUserId: currentPlayer.userId,
              fromNickname: currentPlayer.nickname
            });
          }
        }
      } catch (error) {
        socket.emit('friend_request_result', { success: false, message: '친구 요청 실패' });
      }
    });

    // 친구 요청 목록 조회
    socket.on('get_friend_requests', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_requests_list', { received: [], sent: [] });
        return;
      }

      try {
        const received = await friendService.getReceivedFriendRequests(currentPlayer.userId);
        const sent = await friendService.getSentFriendRequests(currentPlayer.userId);
        socket.emit('friend_requests_list', { received, sent });
      } catch (error) {
        socket.emit('friend_requests_list', { received: [], sent: [] });
      }
    });

    // 친구 요청 수락
    socket.on('accept_friend_request', async (data: { requestId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_request_action_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.acceptFriendRequest(currentPlayer.userId, data.requestId);
        socket.emit('friend_request_action_result', { ...result, action: 'accept' });

        // 요청을 보낸 사람에게 알림
        if (result.success && result.friend) {
          const friendSocket = userSockets.get(result.friend.id);
          if (friendSocket) {
            const myCode = await friendService.getFriendCode(currentPlayer.userId);
            friendSocket.emit('friend_request_accepted', {
              id: currentPlayer.userId,
              nickname: currentPlayer.nickname,
              friendCode: myCode
            });
          }
        }
      } catch (error) {
        socket.emit('friend_request_action_result', { success: false, message: '수락 실패' });
      }
    });

    // 친구 요청 거절
    socket.on('decline_friend_request', async (data: { requestId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_request_action_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.declineFriendRequest(currentPlayer.userId, data.requestId);
        socket.emit('friend_request_action_result', { ...result, action: 'decline' });
      } catch (error) {
        socket.emit('friend_request_action_result', { success: false, message: '거절 실패' });
      }
    });

    // 보낸 친구 요청 취소
    socket.on('cancel_friend_request', async (data: { requestId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('friend_request_action_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.cancelFriendRequest(currentPlayer.userId, data.requestId);
        socket.emit('friend_request_action_result', { ...result, action: 'cancel' });
      } catch (error) {
        socket.emit('friend_request_action_result', { success: false, message: '취소 실패' });
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

    // 친구 메모 수정
    socket.on('update_friend_memo', async (data: { friendId: number; memo: string | null }) => {
      if (!currentPlayer?.userId) {
        socket.emit('update_friend_memo_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await friendService.updateFriendMemo(currentPlayer.userId, data.friendId, data.memo);
        socket.emit('update_friend_memo_result', { ...result, friendId: data.friendId, memo: data.memo });
      } catch (error) {
        socket.emit('update_friend_memo_result', { success: false, message: '메모 저장 실패' });
      }
    });

    // ====== 메시지 시스템 ======

    // 메시지 전송
    socket.on('send_message', async (data: { friendId: number; content: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('send_message_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      const content = data.content.trim();
      if (!content || content.length > 500) {
        socket.emit('send_message_result', { success: false, message: '메시지는 1-500자여야 합니다.' });
        return;
      }

      try {
        const message = await messageService.sendMessage(currentPlayer.userId, data.friendId, content);
        if (!message) {
          socket.emit('send_message_result', { success: false, message: '친구에게만 메시지를 보낼 수 있습니다.' });
          return;
        }

        socket.emit('send_message_result', { success: true, message });

        // 상대방에게 실시간 전송
        const friendSocket = userSockets.get(data.friendId);
        if (friendSocket) {
          friendSocket.emit('new_message', {
            message: { ...message, isMine: false }
          });
        }
      } catch (error) {
        socket.emit('send_message_result', { success: false, message: '메시지 전송 실패' });
      }
    });

    // 대화 내역 조회
    socket.on('get_messages', async (data: { friendId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('messages_list', { messages: [], friendId: data.friendId });
        return;
      }

      try {
        const messages = await messageService.getMessages(currentPlayer.userId, data.friendId);
        // 읽음 처리
        await messageService.markAsRead(currentPlayer.userId, data.friendId);
        socket.emit('messages_list', { messages, friendId: data.friendId });
      } catch (error) {
        socket.emit('messages_list', { messages: [], friendId: data.friendId });
      }
    });

    // 안 읽은 메시지 수 조회
    socket.on('get_unread_counts', async () => {
      console.log(`📥 get_unread_counts requested by user:`, currentPlayer?.userId);
      if (!currentPlayer?.userId) {
        socket.emit('unread_counts', { counts: {} });
        return;
      }

      try {
        const counts = await messageService.getUnreadCount(currentPlayer.userId);
        console.log(`✅ Sending unread counts:`, counts);
        socket.emit('unread_counts', { counts });
      } catch (error) {
        console.error('❌ get_unread_counts error:', error);
        socket.emit('unread_counts', { counts: {} });
      }
    });

    // 메시지 읽음 처리
    socket.on('mark_messages_read', async (data: { friendId: number }) => {
      if (!currentPlayer?.userId) return;

      try {
        await messageService.markAsRead(currentPlayer.userId, data.friendId);
        socket.emit('messages_marked_read', { friendId: data.friendId });
      } catch (error) {
        // 무시
      }
    });

    // ====== 게임 초대 시스템 ======

    // 게임 초대 보내기
    socket.on('invite_to_game', async (data: { friendId: number; gameType: string; isHardcore?: boolean }) => {
      if (!currentPlayer?.userId) {
        socket.emit('invite_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const invitation = await invitationService.createInvitation(
          currentPlayer.userId,
          data.friendId,
          data.gameType,
          data.isHardcore
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
        const isHardcore = invitation.isHardcore || false;
        const roomId = `${invitation.gameType}_${isHardcore ? 'hc_' : ''}invite_${Date.now()}`;
        const result = await invitationService.acceptInvitation(data.invitationId, roomId);

        if (!result.success) {
          socket.emit('accept_invitation_result', result);
          return;
        }

        // 초대한 사람 찾기
        const inviterSocket = userSockets.get(invitation.inviterId);
        const inviterPlayer: Player | null = inviterSocket ? {
          id: inviterSocket.id,
          socket: inviterSocket,
          nickname: invitation.inviterNickname,
          userId: invitation.inviterId,
          avatarUrl: undefined  // TODO: 초대자 아바타 URL 저장 필요
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
          status: 'waiting',
          isHardcore
        };

        // 게임 초기화
        if (invitation.gameType === 'tictactoe') {
          room.game = new TicTacToeGame();
        } else if (invitation.gameType === 'infinite_tictactoe') {
          room.game = new InfiniteTicTacToeGame();
        } else if (invitation.gameType === 'gomoku') {
          room.game = new GomokuGame();
        } else if (invitation.gameType === 'reaction') {
          room.game = new ReactionGame();
        } else if (invitation.gameType === 'rps') {
          room.game = new RpsGame();
        } else if (invitation.gameType === 'speedtap') {
          room.game = new SpeedTapGame();
        } else if (invitation.gameType === 'sequence') {
          room.game = new SequenceGame(isHardcore);
        } else if (invitation.gameType === 'stroop') {
          room.game = new StroopGame(isHardcore);
        }

        rooms.set(roomId, room);

        // 방 참가
        inviterSocket!.join(roomId);
        socket.join(roomId);
        currentRoomId = roomId;

        room.status = 'playing';

        const players = [
          { id: inviterPlayer.id, nickname: inviterPlayer.nickname, userId: inviterPlayer.userId, avatarUrl: inviterPlayer.avatarUrl },
          { id: currentPlayer.id, nickname: currentPlayer.nickname, userId: currentPlayer.userId, avatarUrl: currentPlayer.avatarUrl }
        ];

        if (invitation.gameType === 'reaction') {
          // 반응속도 게임
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            players
          });

          io.to(roomId).emit('game_start', {
            gameType: 'reaction',
          });

          setTimeout(() => startReactionRound(io, room), 1000);
        } else if (invitation.gameType === 'rps') {
          // 가위바위보 게임
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            players
          });

          io.to(roomId).emit('game_start', {
            gameType: 'rps',
          });

          setTimeout(() => startRpsRound(io, room), 1000);
        } else if (invitation.gameType === 'speedtap') {
          // 스피드탭 게임
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            players
          });

          io.to(roomId).emit('game_start', {
            gameType: 'speedtap',
          });

          setTimeout(() => startSpeedTapRound(io, room), 1000);
        } else if (invitation.gameType === 'sequence') {
          // 순서 기억하기 게임
          const seqGame = room.game as SequenceGame;
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            players
          });

          io.to(roomId).emit('game_start', {
            gameType: 'sequence',
            gridSize: seqGame.getGridSize(),
            sequence: seqGame.getSequence(),
            level: seqGame.getCurrentLevel(),
            showDelay: seqGame.getShowDelay(),
            isHardcore: seqGame.getIsHardcore(),
            timeLimit: seqGame.getTimeLimit(),
          });
        } else if (invitation.gameType === 'stroop') {
          // 스트룹 게임
          const stroopGame = room.game as StroopGame;
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: {
              players,
              isInvitation: true,
            }
          });

          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            isHardcore,
            players
          });

          io.to(roomId).emit('game_start', {
            gameType: 'stroop',
            isHardcore: stroopGame.getIsHardcore(),
            colors: stroopGame.getColors(),
          });

          setTimeout(() => startStroopRound(io, room), 1000);
        } else {
          // 턴제 게임
          startTurnTimer(io, room);
          const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
          const gameBoard = turnGame?.getBoard();
          const currentTurn = inviterPlayer.id;
          const turnStartTime = room.turnStartTime;

          // 초대 받은 사람에게 게임 상태 포함해서 전송
          socket.emit('accept_invitation_result', {
            success: true,
            roomId,
            gameType: invitation.gameType,
            // 게임 상태 포함
            gameState: {
              players,
              currentTurn,
              board: gameBoard,
              isInvitation: true,
              turnTimeLimit: getTurnTimeLimit(room),
              turnStartTime,
            }
          });

          // 초대자에게 수락 알림 (게임 상태 포함)
          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            // 게임 상태 포함
            gameState: {
              players,
              currentTurn,
              board: gameBoard,
              isInvitation: true,
              turnTimeLimit: getTurnTimeLimit(room),
              turnStartTime,
            }
          });

          // 양쪽에 매칭 성공 알림 (기존 리스너용)
          io.to(roomId).emit('match_found', {
            roomId,
            gameType: invitation.gameType,
            isInvitation: true,
            players
          });

          // 게임 시작 (기존 리스너용)
          io.to(roomId).emit('game_start', {
            currentTurn,
            board: gameBoard,
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime,
          });

          console.log(`🎮 Invitation game started: ${inviterPlayer.nickname} vs ${currentPlayer.nickname}`);
        }
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

    // ====== 통계 시스템 ======

    // 모든 게임 통계 조회
    socket.on('get_all_stats', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('all_stats', { stats: [] });
        return;
      }

      try {
        const stats = await statsService.getAllGameStats(currentPlayer.userId);
        socket.emit('all_stats', { stats });
      } catch (error) {
        socket.emit('all_stats', { stats: [] });
      }
    });

    // 최근 게임 기록 조회
    socket.on('get_recent_records', async (data?: { limit?: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('recent_records', { records: [] });
        return;
      }

      try {
        const records = await statsService.getRecentRecords(currentPlayer.userId, data?.limit || 20);
        socket.emit('recent_records', { records });
      } catch (error) {
        socket.emit('recent_records', { records: [] });
      }
    });

    // 특정 게임 통계 조회
    socket.on('get_game_stats', async (data: { gameType: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('game_stats', { stats: null });
        return;
      }

      try {
        const stats = await statsService.getGameStats(currentPlayer.userId, data.gameType);
        socket.emit('game_stats', { stats });
      } catch (error) {
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
        const mileage = await statsService.getMileage(currentPlayer.userId);
        socket.emit('mileage', { mileage });
      } catch (error) {
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
        const mileage = await statsService.addMileage(currentPlayer.userId, 10, 'ad_watch');
        socket.emit('ad_reward_result', { success: true, mileage, message: '10 마일리지가 지급되었습니다!' });
      } catch (error) {
        socket.emit('ad_reward_result', { success: false, message: '마일리지 지급 실패' });
      }
    });

    // 승률 초기화 (마일리지 사용)
    socket.on('reset_stats', async (data: { gameType: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('reset_stats_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      const RESET_COST = 100; // 승률 초기화 비용

      try {
        // 마일리지 차감
        const mileageResult = await statsService.useMileage(currentPlayer.userId, RESET_COST, `reset_stats_${data.gameType}`);
        if (!mileageResult.success) {
          socket.emit('reset_stats_result', { success: false, message: mileageResult.message, mileage: mileageResult.mileage });
          return;
        }

        // 통계 초기화
        const resetResult = await statsService.resetStats(currentPlayer.userId, data.gameType);
        if (!resetResult.success) {
          // 롤백: 마일리지 복구
          await statsService.addMileage(currentPlayer.userId, RESET_COST, 'reset_stats_rollback');
          socket.emit('reset_stats_result', { success: false, message: resetResult.message });
          return;
        }

        // 새 통계 조회
        const newStats = await statsService.getGameStats(currentPlayer.userId, data.gameType);
        socket.emit('reset_stats_result', {
          success: true,
          message: '승률이 초기화되었습니다.',
          stats: newStats,
          mileage: mileageResult.mileage
        });
      } catch (error) {
        socket.emit('reset_stats_result', { success: false, message: '승률 초기화 실패' });
      }
    });

    // 재대결 요청 (양쪽 모두 눌러야 시작)
    socket.on('rematch_request', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (room && room.status === 'finished') {
        // 재경기 요청 목록 초기화
        if (!room.rematchRequests) {
          room.rematchRequests = new Set();
        }

        // 현재 플레이어 요청 추가
        room.rematchRequests.add(socket.id);
        console.log(`🔄 Rematch requested by ${currentPlayer?.nickname} (${room.rematchRequests.size}/2)`);

        // 상대방에게 알림
        socket.to(data.roomId).emit('rematch_requested', {
          from: currentPlayer?.nickname,
          fromId: socket.id,
        });

        // 본인에게 대기 상태 알림
        socket.emit('rematch_waiting', {
          waiting: true,
        });

        // 두 명 모두 요청했으면 게임 시작
        if (room.rematchRequests.size >= 2) {
          // 게임 리셋
          if (room.gameType === 'tictactoe') {
            room.game = new TicTacToeGame();
          } else if (room.gameType === 'infinite_tictactoe') {
            room.game = new InfiniteTicTacToeGame();
          } else if (room.gameType === 'gomoku') {
            room.game = new GomokuGame();
          } else if (room.gameType === 'reaction') {
            room.game = new ReactionGame();
          } else if (room.gameType === 'rps') {
            room.game = new RpsGame();
          } else if (room.gameType === 'speedtap') {
            room.game = new SpeedTapGame();
          } else if (room.gameType === 'sequence') {
            room.game = new SequenceGame(room.isHardcore);
          } else if (room.gameType === 'stroop') {
            room.game = new StroopGame(room.isHardcore);
          }
          room.status = 'playing';
          room.rematchRequests.clear();

          // 플레이어 순서 교체 (선공/후공 바꾸기)
          room.players.reverse();

          if (room.gameType === 'reaction') {
            // 반응속도 게임 재대결
            io.to(data.roomId).emit('game_start', {
              gameType: 'reaction',
            });
            setTimeout(() => startReactionRound(io, room), 1000);
          } else if (room.gameType === 'rps') {
            // 가위바위보 게임 재대결
            io.to(data.roomId).emit('game_start', {
              gameType: 'rps',
            });
            setTimeout(() => startRpsRound(io, room), 1000);
          } else if (room.gameType === 'speedtap') {
            // 스피드탭 게임 재대결
            io.to(data.roomId).emit('game_start', {
              gameType: 'speedtap',
            });
            setTimeout(() => startSpeedTapRound(io, room), 1000);
          } else if (room.gameType === 'sequence') {
            // 순서 기억하기 게임 재대결
            const seqGame = room.game as SequenceGame;
            io.to(data.roomId).emit('game_start', {
              gameType: 'sequence',
              gridSize: seqGame.getGridSize(),
              sequence: seqGame.getSequence(),
              level: seqGame.getCurrentLevel(),
              showDelay: seqGame.getShowDelay(),
              isHardcore: seqGame.getIsHardcore(),
              timeLimit: seqGame.getTimeLimit(),
            });
          } else if (room.gameType === 'stroop') {
            // 스트룹 게임 재대결
            const stroopGame = room.game as StroopGame;
            io.to(data.roomId).emit('game_start', {
              gameType: 'stroop',
              isHardcore: stroopGame.getIsHardcore(),
              colors: stroopGame.getColors(),
            });
            setTimeout(() => startStroopRound(io, room), 1000);
          } else {
            // 턴제 게임
            startTurnTimer(io, room);
            const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
            io.to(data.roomId).emit('game_start', {
              currentTurn: room.players[0].id,
              board: turnGame?.getBoard(),
              turnTimeLimit: getTurnTimeLimit(room),
              turnStartTime: room.turnStartTime,
            });
          }
          console.log(`🎮 Rematch started: ${room.players[0].nickname} vs ${room.players[1].nickname}`);
        }
      }
    });

    // 재대결 취소
    socket.on('rematch_cancel', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (room && room.rematchRequests) {
        room.rematchRequests.delete(socket.id);
        socket.emit('rematch_waiting', { waiting: false });
        socket.to(data.roomId).emit('rematch_cancelled', {
          from: currentPlayer?.nickname,
        });
      }
    });

    // 방 나가기
    socket.on('leave_room', (data: { roomId: string }) => {
      leaveRoom(socket, data.roomId);
    });

    // ====== 상점 시스템 ======

    // 상점 아이템 목록 조회
    socket.on('get_shop_items', async (data?: { category?: string }) => {
      try {
        const items = await shopService.getShopItems(data?.category);
        socket.emit('shop_items', { items });
      } catch (error) {
        console.error('Get shop items error:', error);
        socket.emit('shop_items', { items: [] });
      }
    });

    // 유저 보유 아이템 조회
    socket.on('get_user_items', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('user_items', { items: [] });
        return;
      }

      try {
        const items = await shopService.getUserItems(currentPlayer.userId);
        socket.emit('user_items', { items });
      } catch (error) {
        console.error('Get user items error:', error);
        socket.emit('user_items', { items: [] });
      }
    });

    // 유저 프로필 설정 조회
    socket.on('get_profile_settings', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('profile_settings', { settings: null });
        return;
      }

      try {
        const settings = await shopService.getUserProfileSettings(currentPlayer.userId);
        socket.emit('profile_settings', { settings });
      } catch (error) {
        console.error('Get profile settings error:', error);
        socket.emit('profile_settings', { settings: null });
      }
    });

    // 아이템 구매
    socket.on('purchase_item', async (data: { itemId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('purchase_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await shopService.purchaseItem(currentPlayer.userId, data.itemId);
        socket.emit('purchase_result', result);

        // 코인 업데이트 이벤트도 전송
        if (result.success && result.coins !== undefined) {
          socket.emit('mileage', { mileage: result.coins });
        }
      } catch (error) {
        console.error('Purchase item error:', error);
        socket.emit('purchase_result', { success: false, message: '구매 중 오류가 발생했습니다.' });
      }
    });

    // 아이템 장착
    socket.on('equip_item', async (data: { itemId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('equip_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await shopService.equipItem(currentPlayer.userId, data.itemId);
        socket.emit('equip_result', result);
      } catch (error) {
        console.error('Equip item error:', error);
        socket.emit('equip_result', { success: false, message: '장착 중 오류가 발생했습니다.' });
      }
    });

    // 아이템 장착 해제
    socket.on('unequip_item', async (data: { category: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('unequip_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await shopService.unequipItem(currentPlayer.userId, data.category);
        socket.emit('unequip_result', result);
      } catch (error) {
        console.error('Unequip item error:', error);
        socket.emit('unequip_result', { success: false, message: '장착 해제 중 오류가 발생했습니다.' });
      }
    });

    // 1패 삭제권 사용
    socket.on('delete_loss', async (data: { gameType: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('delete_loss_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await shopService.deleteLoss(currentPlayer.userId, data.gameType);
        socket.emit('delete_loss_result', result);

        // 성공 시 코인 업데이트 이벤트 발송
        if (result.success && result.coins !== undefined) {
          socket.emit('coins_updated', {
            coins: result.coins,
            earned: -50, // 차감된 코인
            streak: 0,
            streakBonus: false,
          });

          // 통계도 업데이트 (stats 키로 감싸서 전송)
          if (result.stats) {
            socket.emit('stats_updated', { stats: result.stats });
          }
        }
      } catch (error) {
        console.error('Delete loss error:', error);
        socket.emit('delete_loss_result', { success: false, message: '패배 삭제 중 오류가 발생했습니다.' });
      }
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

    async function leaveRoom(socket: Socket, roomId: string) {
      const room = rooms.get(roomId);
      if (room) {
        // 타이머 정리
        clearTurnTimer(room);

        // 게임 중이었다면 탈주 처리 (전적 기록, 경험치 없음)
        if (room.status === 'playing') {
          const leavingPlayer = room.players.find(p => p.id === socket.id);
          const remainingPlayer = room.players.find(p => p.id !== socket.id);

          if (leavingPlayer && remainingPlayer) {
            // 먼저 상태를 finished로 변경 (두 번째 나가는 사람이 중복 기록 안 되게)
            room.status = 'finished';

            try {
              // 탈주자: 패배 기록 (경험치 없음)
              if (leavingPlayer.userId) {
                await statsService.recordGameResultNoExp(leavingPlayer.userId, room.gameType, 'loss');
                if (remainingPlayer.userId) {
                  await statsService.saveGameRecordNoExp(leavingPlayer.userId, remainingPlayer.userId, room.gameType, 'loss');
                }
              }
              // 남은 플레이어: 승리 기록 (경험치 없음)
              if (remainingPlayer.userId) {
                await statsService.recordGameResultNoExp(remainingPlayer.userId, room.gameType, 'win');
              }
              console.log(`🚪 Player quit: ${leavingPlayer.nickname} left, ${remainingPlayer.nickname} wins (no exp)`);
            } catch (err) {
              console.error('Failed to record quit game:', err);
            }
          }
        }

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
