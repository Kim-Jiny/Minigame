import { Server, Socket } from 'socket.io';
import { TicTacToeGame } from '../games/tictactoe';
import { InfiniteTicTacToeGame } from '../games/infinitetictactoe';
import { GomokuGame } from '../games/gomoku';
import { ReactionGame } from '../games/reaction';
import { RpsGame } from '../games/rps';
import { SpeedTapGame } from '../games/speedtap';
import { SequenceGame } from '../games/sequence';
import { StroopGame } from '../games/stroop';
import { HexagonGame } from '../games/hexagon';
import { PyramidGame } from '../games/pyramid';
import { HunminGame } from '../games/hunmin';
import { NumberBattleGame } from '../games/numberbattle';
import { CardFlipGame } from '../games/cardflip';
import { MathRaceGame } from '../games/mathrace';
import { ArrowDashGame } from '../games/arrowdash';
import { TimingGame } from '../games/timing';
import { SetGame } from '../games/set';
import { dictionaryService } from '../services/dictionaryService';
import { friendService } from '../services/friendService';
import { invitationService } from '../services/invitationService';
import { statsService } from '../services/statsService';
import { messageService } from '../services/messageService';
import { coinService } from '../services/coinService';
import { shopService } from '../services/shopService';
import { rankedService, RANKED_GAMES, HARDCORE_GAMES } from '../services/rankedService';
import { getPool } from '../config/database';
import { verifyToken } from '../utils/jwt';
import { findUserById, assertUserNotBanned } from '../services/userService';

// 유저 접속 기록 저장
async function saveUserSession(
  userId: number,
  ipAddress: string,
  deviceInfo: {
    platform?: string;
    osVersion?: string;
    deviceModel?: string;
    appVersion?: string;
    buildNumber?: string;
  }
) {
  const pool = getPool();
  if (!pool) return;

  await pool.query(
    `INSERT INTO dm_user_sessions (user_id, ip_address, platform, os_version, device_model, app_version, build_number)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      userId,
      ipAddress,
      deviceInfo.platform || null,
      deviceInfo.osVersion || null,
      deviceInfo.deviceModel || null,
      deviceInfo.appVersion || null,
      deviceInfo.buildNumber || null,
    ]
  );
}

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
  game: TicTacToeGame | InfiniteTicTacToeGame | GomokuGame | ReactionGame | RpsGame | SpeedTapGame | SequenceGame | StroopGame | HexagonGame | PyramidGame | HunminGame | NumberBattleGame | CardFlipGame | MathRaceGame | ArrowDashGame | TimingGame | SetGame | null;
  status: 'waiting' | 'playing' | 'finished';
  rematchRequests?: Set<string>;
  turnTimer?: NodeJS.Timeout;
  turnStartTime?: number;
  isHardcore?: boolean;  // 하드코어 모드 여부
  isInfinite?: boolean;  // 무한 모드 여부 (틱택토)
  roundTimer?: NodeJS.Timeout;  // 반응속도/스피드탭 게임용 라운드 타이머
  phaseTimer?: NodeJS.Timeout;  // 라운드 사이 대기/카운트다운용 타이머
  idleTimer?: NodeJS.Timeout;  // 헥사곤 60초 무도전 타이머
  buzzTimer?: NodeJS.Timeout;  // 헥사곤 10초 버저 답변 타이머
  skipTimer?: NodeJS.Timeout;  // 헥사곤 20초 스킵 활성화 타이머
  skipVotes?: Set<number>;     // 스킵 투표한 플레이어 인덱스
  isSolo?: boolean;  // 솔로 모드 여부
  soloStartAt?: number;  // [SET 솔로] 덱 소진 시간 측정 시작 시각(ms). 시간 기반 랭킹용.
  leftPlayerIds?: Set<string>;  // [SET 3·4인] 도중 이탈한 플레이어 소켓 id. 승자/보상에서 제외.
  endRequest?: { requesterId: string; agreed: Set<string> };  // [SET 무한] 게임 종료 합의 요청(요청자 자동 동의)
  isRanked?: boolean;  // 랭크전 여부
  rankedGames?: string[];  // 랭크전 게임 목록 (3개)
  rankedResults?: { gameType: string; winnerId: number | null }[];  // 랭크전 각 게임 결과
  rankedCurrentIndex?: number;  // 랭크전 현재 게임 인덱스
  reconnectPaused?: boolean;
  pendingRoundStart?: boolean;
  speedtapPhase?: 'countdown' | 'tapping';
  sequencePhase?: 'showing' | 'playing' | 'waiting';
  roundDeadlineAt?: number;
  phaseDeadlineAt?: number;
  pausedRoundRemainingMs?: number;
  pausedPhaseRemainingMs?: number;
}

// 랭크 매칭 대기열
interface RankedQueuePlayer extends Player {
  elo: number;
  joinedAt: number;
}
const rankedQueue: RankedQueuePlayer[] = [];

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
// 유저 ID별 현재 게임 룸 매핑 (게임 중인지 확인용)
const userRooms = new Map<number, string>();
// 초대 타임아웃 관리 (invitationId -> { timeout, inviterId, inviteeId })
// disconnect 시 소유자 기반으로 깨끗하게 cleanup 하기 위해 유저 id를 함께 저장.
interface InvitationTimeoutEntry {
  timeout: NodeJS.Timeout;
  inviterId: number;
  inviteeId: number;
}
const invitationTimeouts = new Map<number, InvitationTimeoutEntry>();
const INVITATION_TIMEOUT_MS = 30000; // 30초

// 재연결 유예 타이머 (게임 중 끊겼을 때 20초 대기)
const disconnectGraceTimers = new Map<number, NodeJS.Timeout>();
const disconnectContexts = new Map<number, { socket: Socket; roomId: string }>();
const expiredReconnectUsers = new Set<number>();
const RECONNECT_GRACE_MS = 20000; // 20초

function getQueueKey(gameType: string, isHardcore: boolean, isInfinite: boolean = false, maxPlayers: number = 2): string {
  let key = gameType;
  if (maxPlayers > 2) key += `_p${maxPlayers}`; // 3·4인 SET 등 인원별 큐 분리(2인은 기존 키 유지)
  if (isInfinite) key += '_infinite';
  if (isHardcore) key += '_hardcore';
  return key;
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
  room.roundDeadlineAt = undefined;
}

function clearPhaseTimer(room: GameRoom) {
  if (room.phaseTimer) {
    clearTimeout(room.phaseTimer);
    room.phaseTimer = undefined;
  }
  room.phaseDeadlineAt = undefined;
}

// 타이머 콜백에서 발생한 sync throw / async reject를 모두 흡수한다.
// 콜백이 async 함수를 fire-and-forget으로 호출하면 Promise rejection이
// unhandledRejection으로 새어나가 서버가 죽거나, 전역 핸들러가 있어도 해당 방의
// 상태가 finalize 안 된 채 방치된다. 이걸 한 곳에서 막는다.
function runTimerCallbackSafely(label: string, callback: () => void | Promise<void>) {
  try {
    const result = callback();
    if (result && typeof (result as Promise<void>).then === 'function') {
      (result as Promise<void>).catch((err) => {
        console.error(`[timer:${label}] async error:`, err);
      });
    }
  } catch (err) {
    console.error(`[timer:${label}] sync error:`, err);
  }
}

function scheduleRoundTimer(room: GameRoom, delay: number, callback: () => void) {
  clearRoundTimer(room);
  room.roundDeadlineAt = Date.now() + delay;
  room.roundTimer = setTimeout(() => {
    room.roundDeadlineAt = undefined;
    runTimerCallbackSafely('roundTimer', callback);
  }, delay);
}

function getRemainingMs(deadlineAt?: number, fallbackMs: number = 0): number {
  if (!deadlineAt) return fallbackMs;
  return Math.max(0, deadlineAt - Date.now());
}

function schedulePhaseTimer(room: GameRoom, delay: number, callback: () => void) {
  clearPhaseTimer(room);
  room.phaseDeadlineAt = Date.now() + delay;
  room.phaseTimer = setTimeout(() => {
    room.phaseDeadlineAt = undefined;
    runTimerCallbackSafely('phaseTimer', callback);
  }, delay);
}

function scheduleRoundStart(room: GameRoom, delay: number, callback: () => void) {
  room.pendingRoundStart = true;
  schedulePhaseTimer(room, delay, () => {
    room.pendingRoundStart = false;
    runTimerCallbackSafely('roundStart', callback);
  });
}

function pauseRoomForReconnect(room: GameRoom) {
  room.reconnectPaused = true;
  room.pausedRoundRemainingMs = getRemainingMs(room.roundDeadlineAt);
  room.pausedPhaseRemainingMs = getRemainingMs(room.phaseDeadlineAt);
  clearTurnTimer(room);
  clearRoundTimer(room);
  clearPhaseTimer(room);
  clearHexagonTimers(room);
  clearPyramidTimers(room);
  clearHunminTimers(room);
}

function emitSpeedTapCountdown(io: Server, room: GameRoom, countdown: number = 3) {
  if (!(room.game instanceof SpeedTapGame)) return;
  io.to(room.id).emit('speedtap_countdown', {
    round: room.game.getCurrentRound(),
    roundScores: room.game.getRoundScores(),
    countdown,
  });
}

function scheduleSpeedTapCountdown(io: Server, room: GameRoom, countdown: number = 3) {
  if (!(room.game instanceof SpeedTapGame)) return;
  room.speedtapPhase = 'countdown';
  emitSpeedTapCountdown(io, room, countdown);

  schedulePhaseTimer(room, countdown * 1000, () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
    if (!(room.game instanceof SpeedTapGame)) return;

    room.speedtapPhase = 'tapping';
    io.to(room.id).emit('speedtap_round_start', {
      round: room.game.getCurrentRound(),
      roundScores: room.game.getRoundScores(),
      duration: SpeedTapGame.ROUND_TIME,
    });

    scheduleRoundTimer(room, SpeedTapGame.ROUND_TIME, () => {
      endSpeedTapRound(io, room);
    });
  });
}

function emitSequenceResume(io: Server, room: GameRoom, timeLimit: number) {
  if (!(room.game instanceof SequenceGame)) return;
  io.to(room.id).emit('sequence_round_resumed', {
    sequence: room.game.getSequence(),
    level: room.game.getCurrentLevel(),
    timeLimit,
    remainingTimeMs: room.reconnectPaused
      ? (room.pausedRoundRemainingMs && room.pausedRoundRemainingMs > 0
          ? room.pausedRoundRemainingMs
          : timeLimit)
      : getRemainingMs(room.roundDeadlineAt, timeLimit),
    phase: room.sequencePhase ?? 'playing',
    playerInputs: room.game.getPlayerInputs(),
    playerFailed: room.game.getPlayerFailed(),
    playerMaxLevels: room.game.getPlayerMaxLevel(),
  });
}

function scheduleExistingSequencePhase(io: Server, room: GameRoom) {
  if (!(room.game instanceof SequenceGame)) return;
  const game = room.game;
  const showDelay = game.getShowDelay();
  const gapDuration = game.getIsHardcore() ? 100 : 180;
  const showDuration = game.getSequence().length * (showDelay + gapDuration) + 500;
  const timeLimit = game.getTimeLimit();

  room.sequencePhase = 'showing';
  schedulePhaseTimer(room, showDuration, () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
    room.sequencePhase = 'playing';
    scheduleSequenceInputTimeout(io, room, timeLimit, game.getCurrentLevel());
  });
}

function scheduleSequenceInputTimeout(io: Server, room: GameRoom, timeLimit: number, level: number) {
  scheduleRoundTimer(room, timeLimit, async () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
    if (!(room.game instanceof SequenceGame)) return;

    for (let i = 0; i < 2; i++) {
      const inputs = room.game.getPlayerInputs()[i];
      const failed = room.game.getPlayerFailed()[i];
      if (!failed && inputs.length < room.game.getSequence().length) {
        room.game.handleTimeout(i);
        io.to(room.id).emit('sequence_timeout', {
          playerIndex: i,
        });
        console.log(`⏰ Player ${i} timed out on level ${level}`);
      }
    }

    if (room.game.bothPlayersCompleted()) {
      room.sequencePhase = 'waiting';
      const roundResult = room.game.checkRoundResult();
      if (roundResult.gameOver) {
        await finishSequenceGame(io, room);
      } else if (roundResult.bothPassed) {
        io.to(room.id).emit('sequence_round_complete', {
          success: true,
          nextLevel: room.game.getCurrentLevel() + 1,
        });
        schedulePhaseTimer(room, 2000, () => startSequenceRound(io, room));
      }
    }
  });
}

function scheduleReactionTimeout(io: Server, room: GameRoom) {
  scheduleRoundTimer(room, 5000, () => {
    if (!(room.game instanceof ReactionGame)) return;
    if (room.reconnectPaused || room.status !== 'playing') return;
    if (room.game.getRoundState() === 'go') {
      io.to(room.id).emit('reaction_round_timeout', {
        round: room.game.getCurrentRound(),
      });

      if (room.game.isGameOver()) {
        finishReactionGame(io, room);
      } else {
        scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
      }
    }
  });
}

// 같은 방에서 종료 처리를 한 번만 수행하도록 보호
function markRoomFinishedOnce(room: GameRoom, reason: string): boolean {
  if (room.status === 'finished') {
    console.log(`⛔ Skip duplicate finish [${room.id}] reason=${reason}`);
    return false;
  }
  room.status = 'finished';
  return true;
}

// 반응속도 게임 라운드 시작
function startReactionRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'reaction' || !(room.game instanceof ReactionGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  const { delay } = game.startRound();

  // 라운드 준비 상태 전송
  io.to(room.id).emit('reaction_round_ready', {
    round: game.getCurrentRound(),
    scores: game.getScores(),
  });

  console.log(`🚦 Round ${game.getCurrentRound()} ready, go in ${delay}ms`);

  // 랜덤 시간 후 GO!
  schedulePhaseTimer(room, delay, () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
    if (!(room.game instanceof ReactionGame)) return;
    game.setGo();
    io.to(room.id).emit('reaction_round_go', {
      round: game.getCurrentRound(),
    });
    console.log(`🟢 Round ${game.getCurrentRound()} GO!`);
    scheduleReactionTimeout(io, room);
  });
}

// 반응속도 게임 종료 처리
async function finishReactionGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof ReactionGame)) return;
  if (!markRoomFinishedOnce(room, 'reaction_game_end')) return;
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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 가위바위보 라운드 시작
function startRpsRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'rps' || !(room.game instanceof RpsGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

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
  scheduleRoundTimer(room, RPS_TIME_LIMIT, () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
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
        scheduleRoundStart(room, 2000, () => startRpsRound(io, room));
      }
    }
  });
}

// 가위바위보 게임 종료 처리
async function finishRpsGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof RpsGame)) return;
  if (!markRoomFinishedOnce(room, 'rps_game_end')) return;
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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 스피드탭 라운드 시작 (3초 카운트다운 후)
function startSpeedTapRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'speedtap' || !(room.game instanceof SpeedTapGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  game.startRound();
  console.log(`👆 SpeedTap Round ${game.getCurrentRound()} countdown started`);
  scheduleSpeedTapCountdown(io, room);
}

// 스피드탭 라운드 종료
async function endSpeedTapRound(io: Server, room: GameRoom) {
  if (!(room.game instanceof SpeedTapGame)) return;

  clearRoundTimer(room);
  room.speedtapPhase = undefined;
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
    clearPhaseTimer(room);
    room.phaseTimer = setTimeout(() => startSpeedTapRound(io, room), 2000);
  }
}

// 스피드탭 게임 종료 처리
async function finishSpeedTapGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof SpeedTapGame)) return;
  if (!markRoomFinishedOnce(room, 'speedtap_game_end')) return;
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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 숫자배틀 게임 시작
function startNumberBattle(io: Server, room: GameRoom) {
  if (room.gameType !== 'numberbattle' || !(room.game instanceof NumberBattleGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  io.to(room.id).emit('numberbattle_start', {
    grid: game.getGrid(),
    duration: NumberBattleGame.GAME_TIME,
  });

  console.log(`🔢 NumberBattle started`);

  scheduleRoundTimer(room, NumberBattleGame.GAME_TIME, () => {
    finishNumberBattleByTimeout(io, room);
  });
}

// 숫자배틀 타임아웃 처리
async function finishNumberBattleByTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof NumberBattleGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  room.game.setGameOver();
  io.to(room.id).emit('numberbattle_timeout', {
    progress: room.game.getProgress(),
  });

  console.log(`⏰ NumberBattle timeout: progress ${room.game.getProgress()}`);
  await finishNumberBattleGame(io, room);
}

// 숫자배틀 게임 종료 처리
async function finishNumberBattleGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof NumberBattleGame)) return;
  if (!markRoomFinishedOnce(room, 'numberbattle_game_end')) return;
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const progress = game.getProgress();

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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
    progress,
    rewards: rewardResults,
  });

  console.log(`🏆 NumberBattle game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${progress[0]} vs ${progress[1]})`);

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// Set(셋) 게임 시작
function startSet(io: Server, room: GameRoom) {
  if (room.gameType !== 'set' || !(room.game instanceof SetGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  const infinite = game.getIsInfinite();
  const solo = room.isSolo === true;
  // 솔로(시간 랭킹): 보드가 노출되는 이 시점부터 시간을 측정한다.
  if (solo) room.soloStartAt = Date.now();
  io.to(room.id).emit('set_start', {
    board: game.getBoard(),
    scores: game.getScores(),
    deckRemaining: game.getDeckRemaining(),
    scoreToWin: infinite ? null : SetGame.SCORE_TO_WIN,
    duration: infinite ? null : SetGame.GAME_TIME,
    infinite,
    solo,
  });

  console.log(`🃏 Set started${solo ? ' (솔로)' : infinite ? ' (무한)' : ''}`);

  // 무한모드는 타이머가 없다 — 덱 소진 + 보드에 세트 없음으로만 종료.
  if (!infinite) {
    scheduleRoundTimer(room, SetGame.GAME_TIME, () => {
      finishSetByTimeout(io, room);
    });
  }
}

// Set 타임아웃 처리 — 점수 높은 쪽 승리
async function finishSetByTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof SetGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  room.game.setGameOver();
  io.to(room.id).emit('set_timeout', {
    scores: room.game.getScores(),
  });

  console.log(`⏰ Set timeout: scores ${room.game.getScores()}`);
  await finishSetGame(io, room);
}

// [SET 무한] 종료 합의 진행상황(동의 인원 / 활성 전체)을 방에 알린다.
function emitSetEndProgress(io: Server, room: GameRoom) {
  if (!room.endRequest) return;
  const active = room.players.filter(p => !room.leftPlayerIds?.has(p.id));
  io.to(room.id).emit('set_end_progress', {
    agreed: room.endRequest.agreed.size,
    total: active.length,
  });
}

// [SET 무한] 진행 중인 종료 요청을 취소하고 방에 알린다(이탈/끊김 시).
function cancelSetEndRequest(io: Server, room: GameRoom, byNickname: string) {
  if (!room.endRequest) return;
  room.endRequest = undefined;
  io.to(room.id).emit('set_end_cancelled', { nickname: byNickname });
}

// [SET 3·4인] 한 명이 도중 이탈했을 때의 처리.
// 게임을 멈추거나 끝내지 않고 계속 진행한다. 이탈자는 즉시 패배(경험치 없음) 기록 후
// 승자·보상 후보에서 제외하며, 활성 인원이 1명 이하가 되면 게임을 종료한다.
async function handleSetMultiLeave(io: Server, room: GameRoom, leavingSocketId: string) {
  if (!(room.game instanceof SetGame)) return;
  if (room.players.length <= 2) return;
  if (!room.leftPlayerIds) room.leftPlayerIds = new Set();
  if (room.leftPlayerIds.has(leavingSocketId)) return;

  const idx = room.players.findIndex(p => p.id === leavingSocketId);
  if (idx === -1) return;
  const leaver = room.players[idx];
  room.leftPlayerIds.add(leavingSocketId);
  if (leaver.userId) {
    userRooms.delete(leaver.userId);
    try {
      await statsService.recordGameResultNoExp(leaver.userId, room.gameType, 'loss');
    } catch (err) {
      console.error('Failed to record set multi leave:', err);
    }
  }

  io.to(room.id).emit('set_player_left', {
    playerId: leaver.id,
    playerIndex: idx,
    nickname: leaver.nickname,
  });

  // 종료 합의 진행 중이면 취소(투표 대상이 바뀌므로). 남은 사람이 다시 요청하면 됨.
  cancelSetEndRequest(io, room, leaver.nickname);

  const active = room.players.length - room.leftPlayerIds.size;
  console.log(`🚪 SET ${room.players.length}인: ${leaver.nickname} 이탈 (활성 ${active}명)`);

  if (active <= 1 && room.status === 'playing') {
    if (!room.game.isGameOver()) room.game.setGameOver();
    await finishSetGame(io, room);
  }
}

// Set 게임 종료 처리
async function finishSetGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof SetGame)) return;
  if (!markRoomFinishedOnce(room, 'set_game_end')) return;
  room.endRequest = undefined; // 종료 합의 진행 중이었어도 게임이 끝나면 정리
  clearRoundTimer(room);

  const game = room.game;
  const scores = game.getScores();

  // 승자 = 최다 득점자. 단 3·4인에서 도중 이탈한 플레이어는 승자 후보에서 제외한다.
  const left = room.leftPlayerIds;
  let winnerIndex = game.getWinner();
  if (left && left.size > 0) {
    let best = -1;
    let bestIdxs: number[] = [];
    for (let i = 0; i < room.players.length; i++) {
      if (left.has(room.players[i].id)) continue;
      if (scores[i] > best) { best = scores[i]; bestIdxs = [i]; }
      else if (scores[i] === best) bestIdxs.push(i);
    }
    winnerIndex = bestIdxs.length === 1 ? bestIdxs[0] : null;
  }

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};
  // 3·4인은 1:1 보상(상대 지정·일일제한·1:1 전적기록)이 성립하지 않으므로
  // 결과기반 멀티 보상 경로를 쓰고, dm_game_records(1:1 전적)는 기록하지 않는다.
  const isMulti = room.players.length > 2;

  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    // 이탈자는 이미 패배(경험치 없음)가 기록됐고 소켓도 없으므로 건너뛴다.
    if (left?.has(player.id)) continue;
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

        if (isMulti) {
          const reward = await coinService.processMultiplayerReward(player.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        } else {
          if (i === 0 && opponent.userId) {
            await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
              isRanked: room.isRanked,
              rankedMatchId: room.isRanked ? room.id : undefined,
              rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
            });
          }
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
    // N인: 클라가 점수↔플레이어를 인덱스로 매핑할 수 있게 순서대로 전달.
    players: room.players.map(p => ({ id: p.id, nickname: p.nickname })),
    rewards: rewardResults,
  });

  console.log(`🏆 Set game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores.join('-')})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// Set 솔로 종료 — 덱 소진까지 걸린 시간을 시간 랭킹(dm_set_rankings)에 저장.
async function finishSetSolo(io: Server, room: GameRoom) {
  if (!(room.game instanceof SetGame)) return;
  if (!markRoomFinishedOnce(room, 'set_solo_end')) return;
  clearRoundTimer(room);
  room.status = 'finished';

  const game = room.game;
  const scores = game.getScores();
  const setsFound = scores[0];
  const timeMs = room.soloStartAt ? Math.max(0, Date.now() - room.soloStartAt) : 0;
  const player = room.players[0];

  if (player?.userId) {
    try {
      const pool = getPool();
      if (pool) {
        await pool.query(
          `INSERT INTO dm_set_rankings (user_id, time_ms, sets_found, nickname)
           VALUES ($1, $2, $3, $4)`,
          [player.userId, timeMs, setsFound, player.nickname]
        );
      }
    } catch (err) {
      console.error('Failed to save set ranking:', err);
    }
    userRooms.delete(player.userId);
  }

  io.to(room.id).emit('game_end', {
    winner: null,
    winnerNickname: null,
    isDraw: false,
    scores,
    isSolo: true,
    timeMs,
    setsFound,
  });

  rooms.delete(room.id);
  console.log(`🃏 Set solo cleared: ${player?.nickname} ${setsFound}세트 ${timeMs}ms`);
}

// 사칙연산 스피드 게임 시작
function startMathrace(io: Server, room: GameRoom) {
  if (room.gameType !== 'mathrace' || !(room.game instanceof MathRaceGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  io.to(room.id).emit('mathrace_start', {
    problems: game.getProblemsForClient(),
    duration: MathRaceGame.GAME_TIME,
  });

  console.log(`🧮 MathRace started`);

  scheduleRoundTimer(room, MathRaceGame.GAME_TIME, () => {
    finishMathraceByTimeout(io, room);
  });
}

// 사칙연산 타임아웃 처리
async function finishMathraceByTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof MathRaceGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  room.game.setGameOver();
  io.to(room.id).emit('mathrace_timeout', {
    progress: room.game.getProgress(),
  });

  console.log(`⏰ MathRace timeout: progress ${room.game.getProgress()}`);
  await finishMathraceGame(io, room);
}

// 사칙연산 게임 종료 처리
async function finishMathraceGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof MathRaceGame)) return;
  if (!markRoomFinishedOnce(room, 'mathrace_game_end')) return;
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const progress = game.getProgress();

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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
    progress,
    rewards: rewardResults,
  });

  console.log(`🏆 MathRace game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${progress[0]} vs ${progress[1]})`);

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 방향 맞추기 게임 시작
function startArrowdash(io: Server, room: GameRoom) {
  if (room.gameType !== 'arrowdash' || !(room.game instanceof ArrowDashGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  io.to(room.id).emit('arrowdash_start', {
    arrows: game.getArrows(),
    duration: ArrowDashGame.GAME_TIME,
  });

  console.log(`➡️ ArrowDash started`);

  scheduleRoundTimer(room, ArrowDashGame.GAME_TIME, () => {
    finishArrowdashByTimeout(io, room);
  });
}

// 방향 맞추기 타임아웃 처리
async function finishArrowdashByTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof ArrowDashGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  room.game.setGameOver();
  io.to(room.id).emit('arrowdash_timeout', {
    progress: room.game.getProgress(),
  });

  console.log(`⏰ ArrowDash timeout: progress ${room.game.getProgress()}`);
  await finishArrowdashGame(io, room);
}

// 방향 맞추기 게임 종료 처리
async function finishArrowdashGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof ArrowDashGame)) return;
  if (!markRoomFinishedOnce(room, 'arrowdash_game_end')) return;
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const progress = game.getProgress();

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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
    progress,
    rewards: rewardResults,
  });

  console.log(`🏆 ArrowDash game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${progress[0]} vs ${progress[1]})`);

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 타이밍 맞추기 라운드 시작
function startTimingRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'timing' || !(room.game instanceof TimingGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  const { round, speed } = game.startRound();

  io.to(room.id).emit('timing_round_start', { round, speed });
  console.log(`⏱️ Timing Round ${round} started (speed: ${speed}ms)`);

  // 5초 타임아웃
  scheduleRoundTimer(room, TimingGame.ROUND_TIMEOUT, () => {
    timingRoundTimeout(io, room);
  });
}

// 타이밍 맞추기 라운드 타임아웃
function timingRoundTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof TimingGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  const game = room.game;
  const result = game.calculateRoundResult();

  io.to(room.id).emit('timing_round_result', {
    round: game.getCurrentRound(),
    positions: result.positions,
    roundScores: result.roundScores,
    totalScores: result.totalScores,
  });

  if (result.gameOver) {
    finishTimingGame(io, room);
  } else {
    scheduleRoundStart(room, 2000, () => startTimingRound(io, room));
  }
}

// 타이밍 맞추기 게임 종료 처리
async function finishTimingGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof TimingGame)) return;
  if (!markRoomFinishedOnce(room, 'timing_game_end')) return;
  clearRoundTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const totalScores = game.getTotalScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
            isRanked: room.isRanked,
            rankedMatchId: room.isRanked ? room.id : undefined,
            rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
          });
        }

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
    totalScores,
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 Timing game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${totalScores[0]} vs ${totalScores[1]})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 카드 뒤집기 게임 시작
function startCardFlip(io: Server, room: GameRoom) {
  if (room.gameType !== 'cardflip' || !(room.game instanceof CardFlipGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  io.to(room.id).emit('cardflip_start', {
    currentTurn: game.getCurrentTurn(),
    totalPairs: CardFlipGame.TOTAL_PAIRS,
    turnTime: CardFlipGame.TURN_TIME,
  });

  console.log(`🃏 CardFlip started`);

  // 첫 턴 타이머 시작
  startCardFlipTurn(io, room);
}

// 카드 뒤집기 턴 타이머 시작
function startCardFlipTurn(io: Server, room: GameRoom) {
  if (!(room.game instanceof CardFlipGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;

  io.to(room.id).emit('cardflip_turn', {
    currentTurn: room.game.getCurrentTurn(),
    turnTime: CardFlipGame.TURN_TIME,
  });

  scheduleRoundTimer(room, CardFlipGame.TURN_TIME, () => {
    handleCardFlipTimeout(io, room);
  });
}

// 카드 뒤집기 턴 타임아웃
function handleCardFlipTimeout(io: Server, room: GameRoom) {
  if (!(room.game instanceof CardFlipGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  if (room.game.isGameOver()) return;

  const result = room.game.handleTimeout();
  io.to(room.id).emit('cardflip_timeout', {
    positions: result.positions,
    nextTurn: result.nextTurn,
    turnTime: CardFlipGame.TURN_TIME,
  });

  console.log(`⏰ CardFlip turn timeout → nextTurn: ${result.nextTurn}`);

  // 새 턴 타이머 시작
  startCardFlipTurn(io, room);
}

// 카드 뒤집기 게임 종료
async function finishCardFlipGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof CardFlipGame)) return;
  if (!markRoomFinishedOnce(room, 'cardflip_game_end')) return;
  clearRoundTimer(room);
  clearPhaseTimer(room);

  const game = room.game;
  const winnerIndex = game.getWinner();
  const scores = game.getScores();

  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
            isRanked: room.isRanked,
            rankedMatchId: room.isRanked ? room.id : undefined,
            rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
          });
        }

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
    rewards: rewardResults,
  });

  console.log(`🏆 CardFlip game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]} vs ${scores[1]})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 순서 기억하기 라운드 시작
function startSequenceRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'sequence' || !(room.game instanceof SequenceGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

  const game = room.game;
  const { sequence, level } = game.startNewRound();
  const timeLimit = game.getTimeLimit();
  const showDelay = game.getShowDelay();
  const gapDuration = game.getIsHardcore() ? 100 : 180;

  // 시퀀스 보여주는 데 걸리는 시간 계산
  const showDuration = sequence.length * (showDelay + gapDuration) + 500; // 시작 딜레이 포함
  room.sequencePhase = 'showing';

  // 시퀀스 보여주기 이벤트
  io.to(room.id).emit('sequence_show', {
    sequence,
    level,
    showDelay,
    timeLimit,
  });

  console.log(`🧠 Sequence Level ${level} started (length: ${sequence.length}, timeLimit: ${timeLimit}ms)`);

  schedulePhaseTimer(room, showDuration, () => {
    if (room.reconnectPaused || room.status !== 'playing') return;
    room.sequencePhase = 'playing';
    emitSequenceResume(io, room, timeLimit);
    scheduleSequenceInputTimeout(io, room, timeLimit, level);
  });
}

// 순서 기억하기 게임 종료 처리
async function finishSequenceGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof SequenceGame)) return;
  if (!markRoomFinishedOnce(room, 'sequence_game_end')) return;
  clearRoundTimer(room);
  clearPhaseTimer(room);
  room.sequencePhase = undefined;

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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// 스트룹 게임 라운드 시작
function startStroopRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'stroop' || !(room.game instanceof StroopGame)) return;
  if (room.reconnectPaused || room.status !== 'playing') return;
  room.pendingRoundStart = false;

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
    scheduleRoundTimer(room, StroopGame.TIME_LIMIT_HARDCORE, () => {
      if (room.reconnectPaused || room.status !== 'playing') return;
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
          scheduleRoundStart(room, 2000, () => startStroopRound(io, room));
        }
      }
    });
  }
}

// 스트룹 게임 종료 처리
async function finishStroopGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof StroopGame)) return;
  if (!markRoomFinishedOnce(room, 'stroop_game_end')) return;
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
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

  // 랭크전인 경우 추가 처리
  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// ====== 헥사곤 게임 함수 ======

function clearHexagonTimers(room: GameRoom) {
  if (room.idleTimer) { clearTimeout(room.idleTimer); room.idleTimer = undefined; }
  if (room.buzzTimer) { clearTimeout(room.buzzTimer); room.buzzTimer = undefined; }
  if (room.skipTimer) { clearTimeout(room.skipTimer); room.skipTimer = undefined; }
  room.skipVotes = undefined;
}

// 헥사곤 라운드 시작 (암기 단계)
function startHexagonRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'hexagon' || !(room.game instanceof HexagonGame)) return;
  if (room.status === 'finished') return;

  const game = room.game;
  const { board, targetNumber, round, totalCombinations } = game.startRound();

  // 암기 시작 → 보드(숫자+알파벳) 전송
  io.to(room.id).emit('hexagon_round_start', {
    board,
    targetNumber,
    round,
    totalCombinations,
    memorizeTime: HexagonGame.MEMORIZE_TIME,
    scores: game.getScores(),
  });

  console.log(`🔷 Hexagon Round ${round}: target=${targetNumber}, combos=${totalCombinations}`);

  // 30초 후 암기 종료 → 플레이 시작
  room.roundTimer = setTimeout(() => {
    if (game.getRoundState() !== 'memorizing') return;
    const { letters } = game.startPlaying();

    io.to(room.id).emit('hexagon_play_start', {
      letters,
      targetNumber,
      round,
    });

    // 60초 무도전 타이머 + 20초 스킵 타이머 시작
    startHexagonIdleTimer(io, room);

    console.log(`🔷 Hexagon Round ${round}: memorizing ended, playing started`);
  }, HexagonGame.MEMORIZE_TIME);
}

// 60초 무도전 타이머 + 20초 스킵 활성화 타이머
function startHexagonIdleTimer(io: Server, room: GameRoom) {
  if (room.idleTimer) clearTimeout(room.idleTimer);
  if (room.skipTimer) clearTimeout(room.skipTimer);
  room.skipVotes = undefined;

  room.idleTimer = setTimeout(() => {
    if (!(room.game instanceof HexagonGame)) return;
    if (room.game.getRoundState() !== 'playing') return;
    finishHexagonRound(io, room);
  }, HexagonGame.ROUND_IDLE_TIMEOUT);

  // 2인 대전에서만 20초 후 스킵 버튼 활성화
  if (!room.isSolo && room.players.length === 2) {
    room.skipTimer = setTimeout(() => {
      if (!(room.game instanceof HexagonGame)) return;
      if (room.game.getRoundState() !== 'playing') return;
      room.skipVotes = new Set();
      io.to(room.id).emit('hexagon_skip_available', {});
      console.log(`🔷 Hexagon skip available in room ${room.id}`);
    }, HexagonGame.SKIP_AVAILABLE_TIME);
  }
}

// 10초 버저 답변 타이머
function startHexagonBuzzTimer(io: Server, room: GameRoom) {
  if (room.buzzTimer) clearTimeout(room.buzzTimer);
  room.buzzTimer = setTimeout(() => {
    if (!(room.game instanceof HexagonGame)) return;
    if (room.game.getRoundState() !== 'buzzing') return;

    const { scores } = room.game.buzzTimeout();
    io.to(room.id).emit('hexagon_buzz_timeout', { scores });

    // 60초 타이머 + 20초 스킵 타이머 재시작
    startHexagonIdleTimer(io, room);
  }, HexagonGame.BUZZ_TIME_LIMIT);
}

// 헥사곤 라운드 종료
function finishHexagonRound(io: Server, room: GameRoom) {
  if (!(room.game instanceof HexagonGame)) return;
  clearHexagonTimers(room);
  clearRoundTimer(room);

  const result = room.game.finishRound();
  io.to(room.id).emit('hexagon_round_end', {
    ...result,
    scores: room.game.getScores(),
  });

  console.log(`🔷 Hexagon Round ${result.round} ended: found ${result.foundCombinations.length}/${result.totalCombinations}`);

  // 게임 종료 체크
  if (room.game.checkGameOver()) {
    setTimeout(() => finishHexagonGame(io, room), 2000);
  } else {
    // 다음 라운드 (3초 후)
    setTimeout(() => startHexagonRound(io, room), 3000);
  }
}

// 헥사곤 게임 종료 처리
async function finishHexagonGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof HexagonGame)) return;
  if (!markRoomFinishedOnce(room, 'hexagon_game_end')) return;
  clearHexagonTimers(room);
  clearRoundTimer(room);

  const game = room.game;
  const scores = game.getScores();
  const isSolo = game.getIsSolo();

  if (isSolo) {
    // 솔로 모드: 최종 점수 기록
    const player = room.players[0];
    io.to(room.id).emit('game_end', {
      winner: null,
      winnerNickname: null,
      isDraw: false,
      scores,
      isSolo: true,
      roundResults: game.getRoundResults(),
    });

    // 솔로 랭킹 저장
    if (player.userId) {
      try {
        const pool = getPool();
        if (pool) {
          await pool.query(
            `INSERT INTO dm_hexagon_rankings (user_id, score, nickname)
             VALUES ($1, $2, $3)`,
            [player.userId, scores[0], player.nickname]
          );
        }
      } catch (err) {
        console.error('Failed to save hexagon ranking:', err);
      }
    }

    console.log(`🏆 Hexagon solo ended: ${player.nickname} scored ${scores[0]}`);
    return;
  }

  // 대전 모드
  const winnerIndex = game.getWinner();
  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};

  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) gameResult = 'draw';
      else if (winnerIndex === i) gameResult = 'win';
      else gameResult = 'loss';

      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
            isRanked: room.isRanked,
            rankedMatchId: room.isRanked ? room.id : undefined,
            rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
          });
        }
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

  console.log(`🏆 Hexagon game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]}-${scores[1]})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// ====== 수식피라미드 게임 함수 ======

function clearPyramidTimers(room: GameRoom) {
  if (room.idleTimer) { clearTimeout(room.idleTimer); room.idleTimer = undefined; }
  if (room.buzzTimer) { clearTimeout(room.buzzTimer); room.buzzTimer = undefined; }
  if (room.skipTimer) { clearTimeout(room.skipTimer); room.skipTimer = undefined; }
  room.skipVotes = undefined;
}

function startPyramidRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'pyramid' || !(room.game instanceof PyramidGame)) return;
  if (room.status === 'finished') return;

  const game = room.game;
  const { cards, targetNumber, round, validPaths } = game.startRound();

  io.to(room.id).emit('pyramid_round_start', {
    cards,
    targetNumber,
    round,
    scores: game.getScores(),
    validPaths,
  });

  console.log(`🔺 Pyramid Round ${round}: target=${targetNumber}, paths=${validPaths.length}`);

  // 60초 무도전 타이머 시작
  startPyramidIdleTimer(io, room);
}

function startPyramidIdleTimer(io: Server, room: GameRoom) {
  if (room.idleTimer) clearTimeout(room.idleTimer);
  if (room.skipTimer) clearTimeout(room.skipTimer);
  room.skipVotes = undefined;

  room.idleTimer = setTimeout(() => {
    if (!(room.game instanceof PyramidGame)) return;
    if (room.game.getRoundState() !== 'playing') return;
    finishPyramidRound(io, room);
  }, PyramidGame.ROUND_IDLE_TIMEOUT);

  // 2인 대전에서만 20초 후 스킵 버튼 활성화
  if (!room.isSolo && room.players.length === 2) {
    room.skipTimer = setTimeout(() => {
      if (!(room.game instanceof PyramidGame)) return;
      if (room.game.getRoundState() !== 'playing') return;
      room.skipVotes = new Set();
      io.to(room.id).emit('pyramid_skip_available', {});
      console.log(`🔺 Pyramid skip available in room ${room.id}`);
    }, PyramidGame.SKIP_AVAILABLE_TIME);
  }
}

function startPyramidBuzzTimer(io: Server, room: GameRoom) {
  if (room.buzzTimer) clearTimeout(room.buzzTimer);
  room.buzzTimer = setTimeout(() => {
    if (!(room.game instanceof PyramidGame)) return;
    if (room.game.getRoundState() !== 'buzzing') return;

    const { scores } = room.game.buzzTimeout();
    io.to(room.id).emit('pyramid_buzz_timeout', { scores });

    // 60초 타이머 재시작
    startPyramidIdleTimer(io, room);
  }, PyramidGame.BUZZ_TIME_LIMIT);
}

function finishPyramidRound(io: Server, room: GameRoom) {
  if (!(room.game instanceof PyramidGame)) return;
  clearPyramidTimers(room);

  const result = room.game.finishRound();
  io.to(room.id).emit('pyramid_round_end', {
    ...result,
    scores: room.game.getScores(),
  });

  console.log(`🔺 Pyramid Round ${result.round} ended`);

  if (room.game.checkGameOver()) {
    setTimeout(() => finishPyramidGame(io, room), 2000);
  } else {
    setTimeout(() => startPyramidRound(io, room), 3000);
  }
}

async function finishPyramidGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof PyramidGame)) return;
  if (!markRoomFinishedOnce(room, 'pyramid_game_end')) return;
  clearPyramidTimers(room);

  const game = room.game;
  const scores = game.getScores();

  // 솔로 모드: 랭킹 저장 후 game_end
  if (room.isSolo) {
    const player = room.players[0];
    if (player?.userId) {
      try {
        const pool = getPool();
        if (pool) {
          await pool.query(
            `INSERT INTO dm_pyramid_rankings (user_id, score, nickname)
             VALUES ($1, $2, $3)`,
            [player.userId, scores[0], player.nickname]
          );
        }
      } catch (err) {
        console.error('Failed to save pyramid solo ranking:', err);
      }
    }

    io.to(room.id).emit('game_end', {
      winner: null,
      winnerNickname: null,
      isDraw: false,
      scores,
      isSolo: true,
      roundResults: game.getRoundResults(),
    });

    if (player?.userId) userRooms.delete(player.userId);
    rooms.delete(room.id);
    console.log(`🔺 Pyramid solo finished: ${player?.nickname}, score=${scores[0]}`);
    return;
  }

  const winnerIndex = game.getWinner();
  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};

  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) gameResult = 'draw';
      else if (winnerIndex === i) gameResult = 'win';
      else gameResult = 'loss';

      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });
        if (i === 0 && opponent.userId) {
          await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
            isRanked: room.isRanked,
            rankedMatchId: room.isRanked ? room.id : undefined,
            rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
          });
        }
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

  console.log(`🏆 Pyramid game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores[0]}-${scores[1]})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// ====== 훈민정음 게임 헬퍼 함수 ======

function clearHunminTimers(room: GameRoom) {
  if (room.turnTimer) { clearTimeout(room.turnTimer); room.turnTimer = undefined; }
  if (room.skipTimer) { clearTimeout(room.skipTimer); room.skipTimer = undefined; }
}

function startHunminRound(io: Server, room: GameRoom) {
  if (room.gameType !== 'hunmin' || !(room.game instanceof HunminGame)) return;
  if (room.status === 'finished') return;

  const game = room.game;
  const { round, chosung, firstPlayer, scores, eliminated } = game.startRound();

  io.to(room.id).emit('hunmin_round_start', {
    round,
    chosung,
    firstPlayer,
    scores,
    eliminated, // 시작부터 탈락(영구 이탈) 인덱스
  });

  console.log(`📝 Hunmin Round ${round}: chosung=${chosung}, firstPlayer=${firstPlayer}`);

  // 첫 턴 타이머 시작
  startHunminTurnTimer(io, room);
}

function startHunminTurnTimer(io: Server, room: GameRoom) {
  clearHunminTimers(room);

  if (!(room.game instanceof HunminGame)) return;
  if (room.status === 'finished') return;

  const game = room.game;

  // 턴 시작 알림
  io.to(room.id).emit('hunmin_turn_start', {
    playerIndex: game.getCurrentTurnPlayer(),
    timeLimit: HunminGame.TURN_TIME_LIMIT,
  });

  room.turnStartTime = Date.now();
  room.turnTimer = setTimeout(() => {
    if (!(room.game instanceof HunminGame)) return;
    if (room.status !== 'playing') return;

    const result = game.handleTimeout();
    console.log(`⏰ Hunmin timeout: player ${result.eliminatedIndex} 탈락 (round ${game.getCurrentRound()})`);

    handleHunminElimination(io, room, result, 'timeout');
  }, HunminGame.TURN_TIME_LIMIT);
}

// [N인 탈락제] 탈락 결과 처리: 활성 1명만 남으면 라운드 마무리, 아니면 탈락 알림 후 다음 턴.
function handleHunminElimination(
  io: Server,
  room: GameRoom,
  result: { eliminatedIndex: number; roundEnded: boolean; nextPlayer?: number; winnerIndex?: number; scores: number[] },
  reason: string,
  failedWord?: string
) {
  if (!(room.game instanceof HunminGame)) return;
  if (result.roundEnded) {
    finishHunminRound(io, room, result.winnerIndex ?? -1, result.eliminatedIndex, reason, result.scores, failedWord);
  } else {
    io.to(room.id).emit('hunmin_player_eliminated', {
      playerIndex: result.eliminatedIndex,
      reason,
      failedWord: failedWord || null,
      nextPlayer: result.nextPlayer,
      scores: result.scores,
    });
    console.log(`💀 Hunmin: player ${result.eliminatedIndex} 탈락(${reason}) → 다음 턴 ${result.nextPlayer}`);
    startHunminTurnTimer(io, room);
  }
}

function finishHunminRound(
  io: Server,
  room: GameRoom,
  winnerIndex: number,
  loserIndex: number,
  reason: string,
  scores: number[],
  failedWord?: string
) {
  clearHunminTimers(room);

  if (!(room.game instanceof HunminGame)) return;

  io.to(room.id).emit('hunmin_round_end', {
    winnerIndex,
    loserIndex,
    reason,
    scores,
    round: room.game.getCurrentRound(),
    failedWord: failedWord || null,
  });

  console.log(`📝 Hunmin Round ${room.game.getCurrentRound()} ended: winner=${winnerIndex}, reason=${reason}`);

  if (room.game.checkGameOver()) {
    setTimeout(() => finishHunminGame(io, room), 2000);
  } else {
    setTimeout(() => startHunminRound(io, room), 3000);
  }
}

async function finishHunminGame(io: Server, room: GameRoom) {
  if (!(room.game instanceof HunminGame)) return;
  if (!markRoomFinishedOnce(room, 'hunmin_game_end')) return;
  clearHunminTimers(room);

  const game = room.game;
  const scores = game.getScores();
  const winnerIndex = game.getWinner();
  const winner = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winner?.id ?? null;
  const winnerNickname = winner?.nickname ?? null;
  const isDraw = winnerIndex === null;

  const rewardResults: { [key: string]: any } = {};
  // 3·4인은 1:1 보상(상대 지정·일일제한·1:1 전적)이 성립 안 하므로 결과기반 멀티 보상.
  const isMulti = room.players.length > 2;
  const left = new Set(game.getLeftPlayers());

  for (let i = 0; i < room.players.length; i++) {
    const player = room.players[i];
    if (left.has(i)) continue; // 이탈자는 이탈 시점에 패배 기록됨
    const opponent = room.players[i === 0 ? 1 : 0];
    if (player.userId) {
      let gameResult: 'win' | 'loss' | 'draw';
      if (isDraw) gameResult = 'draw';
      else if (winnerIndex === i) gameResult = 'win';
      else gameResult = 'loss';

      try {
        const stats = await statsService.recordGameResult(player.userId, room.gameType, gameResult);
        player.socket.emit('stats_updated', { stats });

        if (isMulti) {
          const reward = await coinService.processMultiplayerReward(player.userId, gameResult);
          rewardResults[player.id] = reward;
          player.socket.emit('coins_updated', {
            coins: reward.totalCoins,
            earned: reward.coinsEarned,
            streak: reward.streakAfter,
            streakBonus: reward.streakBonusEarned,
          });
        } else {
          if (i === 0 && opponent.userId) {
            await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
              isRanked: room.isRanked,
              rankedMatchId: room.isRanked ? room.id : undefined,
              rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
            });
          }
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
    players: room.players.map(p => ({ id: p.id, nickname: p.nickname })),
    roundResults: game.getRoundResults(),
    rewards: rewardResults,
  });

  console.log(`🏆 Hunmin game ended: ${isDraw ? 'Draw' : winnerNickname + ' wins'} (${scores.join('-')})`);

  if (room.isRanked) {
    await handleRankedGameEnd(io, room, winnerIndex);
  }
}

// [훈민정음 3·4인] 도중 영구 이탈 처리. 게임은 멈추지 않고 계속 진행한다.
// 이탈자는 즉시 패배(경험치 없음) 기록 후 모든 라운드·승자에서 제외. 비이탈 1명 이하면 게임 종료.
async function handleHunminMultiLeave(io: Server, room: GameRoom, leavingSocketId: string) {
  if (!(room.game instanceof HunminGame)) return;
  if (room.players.length <= 2) return;
  const idx = room.players.findIndex(p => p.id === leavingSocketId);
  if (idx === -1 || room.game.getLeftPlayers().includes(idx)) return;
  const leaver = room.players[idx];

  if (leaver.userId) {
    userRooms.delete(leaver.userId);
    try {
      await statsService.recordGameResultNoExp(leaver.userId, room.gameType, 'loss');
    } catch (err) {
      console.error('Failed to record hunmin multi leave:', err);
    }
  }

  const result = room.game.markLeft(idx); // 진행 중 라운드면 탈락 처리
  io.to(room.id).emit('hunmin_player_left', {
    playerId: leaver.id,
    playerIndex: idx,
    nickname: leaver.nickname,
  });
  console.log(`🚪 Hunmin ${room.players.length}인: ${leaver.nickname} 이탈`);

  if (room.status !== 'playing') return;
  if (room.game.checkGameOver()) {
    clearHunminTimers(room);
    await finishHunminGame(io, room);
  } else if (result.roundEnded) {
    finishHunminRound(io, room, result.winnerIndex ?? -1, idx, 'left', result.scores);
  } else if (room.game.getRoundState() === 'playing') {
    // 라운드 계속 — 현재(또는 넘어간) 턴 타이머 재시작
    startHunminTurnTimer(io, room);
  }
}

// 재연결 시 게임 상태 전송
function emitRejoinState(socket: Socket, room: GameRoom, userId: number) {
  const playerIndex = room.players.findIndex(p => p.userId === userId);

  if (room.gameType === 'reaction' && room.game instanceof ReactionGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'reaction',
      roomId: room.id,
      round: game.getCurrentRound(),
      scores: game.getScores(),
      roundState: game.getRoundState(),
      playerIndex,
    });
  } else if (room.gameType === 'rps' && room.game instanceof RpsGame) {
    const game = room.game;
    const choices = game.getChoices();
    socket.emit('rejoin_game_state', {
      gameType: 'rps',
      roomId: room.id,
      round: game.getCurrentRound(),
      scores: game.getScores(),
      playerIndex,
      myChoice: choices[playerIndex] ?? null,
      opponentChosen: choices[playerIndex === 0 ? 1 : 0] !== null,
    });
  } else if (room.gameType === 'speedtap' && room.game instanceof SpeedTapGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'speedtap',
      roomId: room.id,
      round: game.getCurrentRound(),
      roundScores: game.getRoundScores(),
      taps: game.getTaps(),
      roundInProgress: game.isRoundInProgress(),
      speedtapPhase: room.speedtapPhase ?? 'countdown',
      playerIndex,
    });
  } else if (room.gameType === 'sequence' && room.game instanceof SequenceGame) {
    const game = room.game;
    const playerInputs = game.getPlayerInputs();
    const playerFailed = game.getPlayerFailed();
    const maxLevels = game.getPlayerMaxLevel();
    socket.emit('rejoin_game_state', {
      gameType: 'sequence',
      roomId: room.id,
      sequence: game.getSequence(),
      level: game.getCurrentLevel(),
      gridSize: game.getGridSize(),
      timeLimit: game.getTimeLimit(),
      remainingTimeMs: room.sequencePhase === 'playing'
        ? (room.pausedRoundRemainingMs && room.pausedRoundRemainingMs > 0
            ? room.pausedRoundRemainingMs
            : game.getTimeLimit())
        : game.getTimeLimit(),
      showDelay: game.getShowDelay(),
      isHardcore: game.getIsHardcore(),
      phase: room.sequencePhase ?? 'playing',
      myInputs: playerInputs[playerIndex],
      myFailed: playerFailed[playerIndex],
      opponentFailed: playerFailed[playerIndex === 0 ? 1 : 0],
      myMaxLevel: maxLevels[playerIndex],
      opponentMaxLevel: maxLevels[playerIndex === 0 ? 1 : 0],
      playerIndex,
    });
  } else if (room.gameType === 'stroop' && room.game instanceof StroopGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'stroop',
      roomId: room.id,
      round: game.getCurrentRound(),
      scores: game.getScores(),
      roundState: game.getRoundState(),
      word: game.getCurrentWord(),
      color: game.getCurrentColor(),
      isHardcore: game.getIsHardcore(),
      colors: game.getColors(),
      remainingTimeMs: game.getRoundState() === 'showing' && game.getIsHardcore()
        ? (room.pausedRoundRemainingMs && room.pausedRoundRemainingMs > 0
            ? room.pausedRoundRemainingMs
            : StroopGame.TIME_LIMIT_HARDCORE)
        : undefined,
      playerIndex,
    });
  } else if (room.gameType === 'hexagon' && room.game instanceof HexagonGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'hexagon',
      roomId: room.id,
      board: game.getBoard(),
      letters: game.getLettersOnly(),
      targetNumber: game.getTargetNumber(),
      round: game.getCurrentRound(),
      scores: game.getScores(),
      roundState: game.getRoundState(),
      buzzingPlayer: game.getBuzzingPlayer(),
      foundCombinations: game.getFoundCombinations(),
      totalCombinations: game.getValidCombinationCount(),
      remainingCombinations: game.getRemainingCombinationCount(),
      isSolo: game.getIsSolo(),
      playerIndex,
    });
  } else if (room.gameType === 'pyramid' && room.game instanceof PyramidGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'pyramid',
      roomId: room.id,
      cards: game.getCards(),
      targetNumber: game.getTargetNumber(),
      round: game.getCurrentRound(),
      scores: game.getScores(),
      roundState: game.getRoundState(),
      buzzingPlayer: game.getBuzzingPlayer(),
      validPaths: game.getValidPaths(),
      playerIndex,
    });
  } else if (room.gameType === 'hunmin' && room.game instanceof HunminGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'hunmin',
      roomId: room.id,
      round: game.getCurrentRound(),
      chosung: game.getCurrentChosung(),
      scores: game.getScores(),
      roundState: game.getRoundState(),
      usedWords: game.getUsedWords(),
      currentTurnPlayer: game.getCurrentTurnPlayer(),
      eliminated: game.getEliminated(), // N인: 이번 라운드 탈락자
      leftPlayers: game.getLeftPlayers(), // N인: 영구 이탈자
      playerIndex,
    });
  } else if (room.gameType === 'numberbattle' && room.game instanceof NumberBattleGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'numberbattle',
      roomId: room.id,
      grid: game.getGrid(),
      progress: game.getProgress(),
      remainingTimeMs: getRemainingMs(room.roundDeadlineAt, NumberBattleGame.GAME_TIME),
      playerIndex,
    });
  } else if (room.gameType === 'set' && room.game instanceof SetGame) {
    const game = room.game;
    const infinite = game.getIsInfinite();
    socket.emit('rejoin_game_state', {
      gameType: 'set',
      roomId: room.id,
      board: game.getBoard(),
      scores: game.getScores(),
      deckRemaining: game.getDeckRemaining(),
      scoreToWin: infinite ? null : SetGame.SCORE_TO_WIN,
      remainingTimeMs: infinite ? null : getRemainingMs(room.roundDeadlineAt, SetGame.GAME_TIME),
      infinite,
      playerIndex,
    });
  } else if (room.gameType === 'mathrace' && room.game instanceof MathRaceGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'mathrace',
      roomId: room.id,
      problems: game.getProblemsForClient(),
      progress: game.getProgress(),
      remainingTimeMs: getRemainingMs(room.roundDeadlineAt, MathRaceGame.GAME_TIME),
      playerIndex,
    });
  } else if (room.gameType === 'arrowdash' && room.game instanceof ArrowDashGame) {
    const game = room.game;
    socket.emit('rejoin_game_state', {
      gameType: 'arrowdash',
      roomId: room.id,
      arrows: game.getArrows(),
      progress: game.getProgress(),
      remainingTimeMs: getRemainingMs(room.roundDeadlineAt, ArrowDashGame.GAME_TIME),
      playerIndex,
    });
  } else if (room.gameType === 'timing' && room.game instanceof TimingGame) {
    const state = room.game.getState();
    socket.emit('rejoin_game_state', {
      gameType: 'timing',
      roomId: room.id,
      round: state.round,
      totalScores: state.totalScores,
      speed: state.speed,
      playerIndex,
      hasPlayerStopped: state.hasPlayerStopped[playerIndex],
    });
  } else if (room.gameType === 'cardflip' && room.game instanceof CardFlipGame) {
    const game = room.game;
    const state = game.getState();
    socket.emit('rejoin_game_state', {
      gameType: 'cardflip',
      roomId: room.id,
      cards: game.getCards(),
      matched: state.matched,
      scores: state.scores,
      currentTurn: state.currentTurn,
      flippedCards: state.flippedCards,
      flippedSymbols: state.flippedSymbols,
      remainingTimeMs: getRemainingMs(room.roundDeadlineAt, CardFlipGame.TURN_TIME),
      playerIndex,
    });
  } else {
    // 기타 게임: 최소 상태만 전송 (서버 타이머가 계속 돌고 있으므로 다음 이벤트부터 정상 수신)
    socket.emit('rejoin_game_state', {
      gameType: room.gameType,
      roomId: room.id,
      playerIndex,
    });
  }
}

function resumePausedGame(io: Server, room: GameRoom) {
  if (!room.reconnectPaused || room.status !== 'playing') return;

  const pausedRoundRemainingMs = room.pausedRoundRemainingMs;
  const pausedPhaseRemainingMs = room.pausedPhaseRemainingMs;
  room.reconnectPaused = false;
  room.pausedRoundRemainingMs = undefined;
  room.pausedPhaseRemainingMs = undefined;

  if (room.pendingRoundStart) {
    const startDelay = Math.max(0, pausedPhaseRemainingMs ?? 1000);
    if (room.gameType === 'reaction') {
      scheduleRoundStart(room, startDelay, () => startReactionRound(io, room));
      return;
    }
    if (room.gameType === 'rps') {
      scheduleRoundStart(room, startDelay, () => startRpsRound(io, room));
      return;
    }
    if (room.gameType === 'speedtap') {
      scheduleRoundStart(room, startDelay, () => startSpeedTapRound(io, room));
      return;
    }
    if (room.gameType === 'numberbattle') {
      scheduleRoundStart(room, startDelay, () => startNumberBattle(io, room));
      return;
    }
    if (room.gameType === 'set') {
      scheduleRoundStart(room, startDelay, () => startSet(io, room));
      return;
    }
    if (room.gameType === 'mathrace') {
      scheduleRoundStart(room, startDelay, () => startMathrace(io, room));
      return;
    }
    if (room.gameType === 'arrowdash') {
      scheduleRoundStart(room, startDelay, () => startArrowdash(io, room));
      return;
    }
    if (room.gameType === 'timing') {
      scheduleRoundStart(room, startDelay, () => startTimingRound(io, room));
      return;
    }
    if (room.gameType === 'cardflip') {
      scheduleRoundStart(room, startDelay, () => startCardFlip(io, room));
      return;
    }
    if (room.gameType === 'stroop') {
      scheduleRoundStart(room, startDelay, () => startStroopRound(io, room));
      return;
    }
  }

  if (room.gameType === 'reaction' && room.game instanceof ReactionGame) {
    const game = room.game;
    if (game.getRoundState() === 'ready') {
      io.to(room.id).emit('reaction_round_ready', {
        round: game.getCurrentRound(),
        scores: game.getScores(),
      });
      schedulePhaseTimer(room, Math.max(0, pausedPhaseRemainingMs ?? 1000), () => {
        if (room.reconnectPaused || room.status !== 'playing') return;
        if (!(room.game instanceof ReactionGame)) return;
        room.game.setGo();
        io.to(room.id).emit('reaction_round_go', {
          round: room.game.getCurrentRound(),
        });
        scheduleReactionTimeout(io, room);
      });
      return;
    }

    if (game.getRoundState() === 'go') {
      io.to(room.id).emit('reaction_round_go', {
        round: game.getCurrentRound(),
      });
      scheduleRoundTimer(room, Math.max(0, pausedRoundRemainingMs ?? 5000), () => {
        if (!(room.game instanceof ReactionGame)) return;
        if (room.reconnectPaused || room.status !== 'playing') return;
        if (room.game.getRoundState() === 'go') {
          io.to(room.id).emit('reaction_round_timeout', {
            round: room.game.getCurrentRound(),
          });

          if (room.game.isGameOver()) {
            finishReactionGame(io, room);
          } else {
            scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
          }
        }
      });
      return;
    }

    if (game.getRoundState() === 'finished' && !game.isGameOver()) {
      scheduleRoundStart(room, Math.max(0, pausedPhaseRemainingMs ?? 1000), () => startReactionRound(io, room));
    }
    return;
  }

  if (room.gameType === 'rps' && room.game instanceof RpsGame) {
    const game = room.game;
    const choices = game.getChoices();
    io.to(room.id).emit('rps_round_start', {
      round: game.getCurrentRound(),
      scores: game.getScores(),
      timeLimit: Math.max(0, pausedRoundRemainingMs ?? 10000),
    });

    if (choices[0] !== null) {
      io.to(room.id).emit('rps_player_chosen', {
        playerId: room.players[0]?.id,
      });
    }
    if (choices[1] !== null) {
      io.to(room.id).emit('rps_player_chosen', {
        playerId: room.players[1]?.id,
      });
    }

    scheduleRoundTimer(room, Math.max(0, pausedRoundRemainingMs ?? 10000), () => {
      if (room.reconnectPaused || room.status !== 'playing') return;
      if (!(room.game instanceof RpsGame)) return;
      if (!room.game.isGameOver() && (!room.game.hasChosen(0) || !room.game.hasChosen(1))) {
        if (!room.game.hasChosen(0)) {
          room.game.setRandomChoice(0);
        }
        if (!room.game.hasChosen(1)) {
          room.game.setRandomChoice(1);
        }

        const roundResult = room.game.calculateRoundResult();
        const winner = roundResult.roundWinner !== null ? room.players[roundResult.roundWinner] : null;
        io.to(room.id).emit('rps_round_result', {
          round: room.game.getCurrentRound(),
          player0Choice: roundResult.player0Choice,
          player1Choice: roundResult.player1Choice,
          winnerIndex: roundResult.roundWinner,
          winnerId: winner?.id ?? null,
          winnerNickname: winner?.nickname ?? null,
          isDraw: roundResult.isDraw,
          isTimeout: true,
          scores: room.game.getScores(),
        });

        if (roundResult.gameOver) {
          finishRpsGame(io, room);
        } else {
          scheduleRoundStart(room, 2000, () => startRpsRound(io, room));
        }
      }
    });
    return;
  }

  if (room.gameType === 'speedtap' && room.game instanceof SpeedTapGame) {
    const game = room.game;
    if (room.speedtapPhase === 'tapping' && game.isRoundInProgress()) {
      const remainingMs = Math.max(0, pausedRoundRemainingMs ?? SpeedTapGame.ROUND_TIME);
      io.to(room.id).emit('speedtap_round_resumed', {
        round: game.getCurrentRound(),
        roundScores: game.getRoundScores(),
        taps: game.getTaps(),
        duration: remainingMs,
      });
      scheduleRoundTimer(room, remainingMs, () => endSpeedTapRound(io, room));
      return;
    }

    if (room.speedtapPhase === 'countdown') {
      scheduleSpeedTapCountdown(
        io,
        room,
        Math.max(1, Math.ceil((pausedPhaseRemainingMs ?? 3000) / 1000)),
      );
      return;
    }

    startSpeedTapRound(io, room);
    return;
  }

  if (room.gameType === 'numberbattle' && room.game instanceof NumberBattleGame) {
    const game = room.game;
    const remainingMs = Math.max(0, pausedRoundRemainingMs ?? NumberBattleGame.GAME_TIME);
    io.to(room.id).emit('numberbattle_resumed', {
      grid: game.getGrid(),
      progress: game.getProgress(),
      duration: remainingMs,
    });
    scheduleRoundTimer(room, remainingMs, () => finishNumberBattleByTimeout(io, room));
    return;
  }

  if (room.gameType === 'set' && room.game instanceof SetGame) {
    const game = room.game;
    const infinite = game.getIsInfinite();
    const remainingMs = Math.max(0, pausedRoundRemainingMs ?? SetGame.GAME_TIME);
    io.to(room.id).emit('set_resumed', {
      board: game.getBoard(),
      scores: game.getScores(),
      deckRemaining: game.getDeckRemaining(),
      duration: infinite ? null : remainingMs,
      infinite,
    });
    // 무한모드는 타이머를 다시 걸지 않는다.
    if (!infinite) {
      scheduleRoundTimer(room, remainingMs, () => finishSetByTimeout(io, room));
    }
    return;
  }

  if (room.gameType === 'mathrace' && room.game instanceof MathRaceGame) {
    const game = room.game;
    const remainingMs = Math.max(0, pausedRoundRemainingMs ?? MathRaceGame.GAME_TIME);
    io.to(room.id).emit('mathrace_resumed', {
      problems: game.getProblemsForClient(),
      progress: game.getProgress(),
      duration: remainingMs,
    });
    scheduleRoundTimer(room, remainingMs, () => finishMathraceByTimeout(io, room));
    return;
  }

  if (room.gameType === 'arrowdash' && room.game instanceof ArrowDashGame) {
    const game = room.game;
    const remainingMs = Math.max(0, pausedRoundRemainingMs ?? ArrowDashGame.GAME_TIME);
    io.to(room.id).emit('arrowdash_resumed', {
      arrows: game.getArrows(),
      progress: game.getProgress(),
      duration: remainingMs,
    });
    scheduleRoundTimer(room, remainingMs, () => finishArrowdashByTimeout(io, room));
    return;
  }

  if (room.gameType === 'timing' && room.game instanceof TimingGame) {
    const state = room.game.getState();
    const remainingMs = Math.max(0, pausedRoundRemainingMs ?? TimingGame.ROUND_TIMEOUT);
    io.to(room.id).emit('timing_resumed', {
      round: state.round,
      totalScores: state.totalScores,
      speed: state.speed,
    });
    scheduleRoundTimer(room, remainingMs, () => timingRoundTimeout(io, room));
    return;
  }

  if (room.gameType === 'cardflip' && room.game instanceof CardFlipGame) {
    const game = room.game;
    const state = game.getState();

    // 2장이 뒤집힌 채 일시정지된 경우 (불일치 1.5초 딜레이 중 끊김)
    if (state.flippedCards.length === 2) {
      const phaseMs = Math.max(0, pausedPhaseRemainingMs ?? CardFlipGame.FLIP_DELAY);

      io.to(room.id).emit('cardflip_resumed', {
        cards: game.getCards(),
        matched: state.matched,
        scores: state.scores,
        currentTurn: state.currentTurn,
        flippedCards: state.flippedCards,
        flippedSymbols: state.flippedSymbols,
        turnTime: phaseMs, // 남은 페이즈 시간 (곧 cardflip_result → cardflip_turn이 올 것)
        isPhaseWaiting: true,
      });

      const flippedPositions = state.flippedCards;
      schedulePhaseTimer(room, phaseMs, () => {
        if (!(room.game instanceof CardFlipGame)) return;
        if (room.reconnectPaused || room.status !== 'playing') return;
        room.game.clearFlipped();
        io.to(room.id).emit('cardflip_result', {
          matched: false,
          positions: flippedPositions,
          scores: room.game.getScores(),
          nextTurn: room.game.getCurrentTurn(),
          matchedPositions: room.game.getMatched(),
        });
        startCardFlipTurn(io, room);
      });
    } else {
      // 0~1장 뒤집힌 상태 → 정상 턴 타이머 재시작
      const remainingMs = Math.max(0, pausedRoundRemainingMs ?? CardFlipGame.TURN_TIME);

      io.to(room.id).emit('cardflip_resumed', {
        cards: game.getCards(),
        matched: state.matched,
        scores: state.scores,
        currentTurn: state.currentTurn,
        flippedCards: state.flippedCards,
        flippedSymbols: state.flippedSymbols,
        turnTime: remainingMs, // 실제 남은 턴 시간
      });

      scheduleRoundTimer(room, remainingMs, () => handleCardFlipTimeout(io, room));
    }
    return;
  }

  if (room.gameType === 'sequence' && room.game instanceof SequenceGame) {
    const game = room.game;
    const timeLimit = game.getTimeLimit();
    const resumedSequenceTimeLimit =
      pausedRoundRemainingMs && pausedRoundRemainingMs > 0
        ? pausedRoundRemainingMs
        : timeLimit;
    if (room.sequencePhase === 'waiting') {
      emitSequenceResume(io, room, timeLimit);
      schedulePhaseTimer(room, Math.max(0, pausedPhaseRemainingMs ?? 2000), () => startSequenceRound(io, room));
      return;
    }

    if (room.sequencePhase === 'showing') {
      const sequence = game.getSequence();
      const showDelay = game.getShowDelay();
      const gapDuration = game.getIsHardcore() ? 100 : 180;
      const showDuration = sequence.length * (showDelay + gapDuration) + 500;
      const remainingShowMs = Math.max(0, pausedPhaseRemainingMs ?? showDuration);

      io.to(room.id).emit('sequence_show', {
        sequence,
        level: game.getCurrentLevel(),
        showDelay,
        timeLimit,
        remainingShowMs,
        isReconnectResume: true,
      });

      schedulePhaseTimer(room, remainingShowMs, () => {
        if (room.reconnectPaused || room.status !== 'playing') return;
        room.sequencePhase = 'playing';
        emitSequenceResume(io, room, timeLimit);
        scheduleSequenceInputTimeout(
          io,
          room,
          resumedSequenceTimeLimit,
          game.getCurrentLevel(),
        );
      });
      return;
    }

    emitSequenceResume(io, room, timeLimit);
    scheduleSequenceInputTimeout(
      io,
      room,
      resumedSequenceTimeLimit,
      game.getCurrentLevel(),
    );
    return;
  }

  if (room.gameType === 'stroop' && room.game instanceof StroopGame) {
    const game = room.game;
    if (game.getRoundState() === 'showing') {
      io.to(room.id).emit('stroop_show', {
        word: game.getCurrentWord(),
        color: game.getCurrentColor(),
        round: game.getCurrentRound(),
        scores: game.getScores(),
        isHardcore: game.getIsHardcore(),
        colors: game.getColors(),
        remainingTimeMs: Math.max(0, pausedRoundRemainingMs ?? StroopGame.TIME_LIMIT_HARDCORE),
      });

      if (game.getIsHardcore()) {
        scheduleRoundTimer(room, Math.max(0, pausedRoundRemainingMs ?? StroopGame.TIME_LIMIT_HARDCORE), () => {
          if (room.reconnectPaused || room.status !== 'playing') return;
          if (!(room.game instanceof StroopGame)) return;
          if (room.game.getRoundState() === 'showing') {
            const timeoutResult = room.game.handleTimeout();
            const roundWinner = timeoutResult.roundWinner !== null ? room.players[timeoutResult.roundWinner] : null;
            io.to(room.id).emit('stroop_result', {
              round: room.game.getCurrentRound(),
              winnerId: roundWinner?.id ?? null,
              winnerNickname: roundWinner?.nickname ?? null,
              scores: room.game.getScores(),
              correctAnswer: room.game.getCurrentColor(),
              isTimeout: true,
            });

            if (timeoutResult.gameOver) {
              finishStroopGame(io, room);
            } else {
              scheduleRoundStart(room, 2000, () => startStroopRound(io, room));
            }
          }
        });
      }
      return;
    }

    if (game.getRoundState() === 'finished' && !game.isGameOver()) {
      scheduleRoundStart(room, Math.max(0, pausedPhaseRemainingMs ?? 1000), () => startStroopRound(io, room));
    }
  }
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
    if (!markRoomFinishedOnce(room, 'turn_timeout')) return;
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
            await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

// 랭크 매칭 시도
async function tryRankedMatch(io: Server, player: RankedQueuePlayer) {
  // 대기열에서 본인 제외하고 매칭 가능한 상대 찾기
  const playerIndex = rankedQueue.findIndex(p => p.id === player.id);
  if (playerIndex === -1) {
    console.log(`🔍 [tryRankedMatch] Player ${player.nickname} not in queue anymore`);
    return; // 이미 대기열에서 나감
  }

  console.log(`🔍 [tryRankedMatch] Queue size: ${rankedQueue.length}, Players: ${rankedQueue.map(p => `${p.nickname}(${p.elo})`).join(', ')}`);

  const now = Date.now();
  const waitTime = now - player.joinedAt;

  // ELO 범위 계산 (대기 시간에 따라 확장)
  // 처음: ±100, 10초마다 ±50씩 확장, 최대 ±400
  const baseRange = 100;
  const extraRange = Math.min(300, Math.floor(waitTime / 10000) * 50);
  const eloRange = baseRange + extraRange;

  for (let i = 0; i < rankedQueue.length; i++) {
    if (i === playerIndex) continue;

    const opponent = rankedQueue[i];
    const eloDiff = Math.abs(player.elo - opponent.elo);

    console.log(`🔍 [tryRankedMatch] Checking ${player.nickname}(${player.elo}) vs ${opponent.nickname}(${opponent.elo}), diff: ${eloDiff}, range: ${eloRange}`);

    if (eloDiff <= eloRange) {
      // 매칭 성공! 대기열에서 제거
      console.log(`✅ [tryRankedMatch] Match found! ${player.nickname} vs ${opponent.nickname}`);
      rankedQueue.splice(Math.max(playerIndex, i), 1);
      rankedQueue.splice(Math.min(playerIndex, i), 1);

      // 랭크 게임 시작
      await startRankedMatch(io, player, opponent);
      return;
    }
  }

  // 매칭 못 찾으면 5초 후 재시도
  console.log(`⏳ [tryRankedMatch] No match for ${player.nickname}, retrying in 5s...`);
  setTimeout(() => tryRankedMatch(io, player), 5000);
}

// 랭크 매치 시작
async function startRankedMatch(io: Server, player1: RankedQueuePlayer, player2: RankedQueuePlayer) {
  // 랜덤 3개 게임 선택
  const games = rankedService.selectRandomGames();

  // 방 생성
  const roomId = `ranked_${Date.now()}`;
  const room: GameRoom = {
    id: roomId,
    gameType: games[0], // 첫 번째 게임으로 시작
    players: [player1, player2],
    game: null,
    status: 'waiting',
    isRanked: true,
    rankedGames: games,
    rankedResults: [],
    rankedCurrentIndex: 0,
    isHardcore: rankedService.isHardcoreGame(games[0]),
  };

  rooms.set(roomId, room);

  // 방 참가
  player1.socket.join(roomId);
  player2.socket.join(roomId);

  // 유저별 현재 게임 룸 기록 (랭크전용)
  if (player1.userId) userRooms.set(player1.userId, roomId);
  if (player2.userId) userRooms.set(player2.userId, roomId);

  // 랭크 통계 조회
  const player1Stats = await rankedService.getRankedStats(player1.userId!);
  const player2Stats = await rankedService.getRankedStats(player2.userId!);

  // 매칭 성공 알림
  io.to(roomId).emit('ranked_match_found', {
    roomId,
    games,
    currentGameIndex: 0,
    currentGame: games[0],
    isHardcore: room.isHardcore,
    players: [
      {
        id: player1.id,
        nickname: player1.nickname,
        userId: player1.userId,
        elo: player1Stats.elo,
        tier: player1Stats.tier,
        tierColor: player1Stats.tierColor,
      },
      {
        id: player2.id,
        nickname: player2.nickname,
        userId: player2.userId,
        elo: player2Stats.elo,
        tier: player2Stats.tier,
        tierColor: player2Stats.tierColor,
      },
    ],
  });

  console.log(`🏆 Ranked match found: ${player1.nickname} (${player1Stats.elo}) vs ${player2.nickname} (${player2Stats.elo})`);
  console.log(`🎮 Games: ${games.join(', ')}`);

  // 2초 후 첫 게임 시작
  setTimeout(() => startRankedGame(io, room), 2000);
}

// 랭크전 개별 게임 시작
async function startRankedGame(io: Server, room: GameRoom) {
  console.log(`🎮 [startRankedGame] Called for room ${room.id}, gameIndex: ${room.rankedCurrentIndex}, players in room: ${room.players.length}, status: ${room.status}`);

  // 플레이어가 부족한 경우 게임 시작 취소 (한 명이 나간 경우)
  if (room.players.length < 2) {
    console.log(`❌ [startRankedGame] Not enough players in room ${room.id} (${room.players.length}), aborting game start`);
    return;
  }

  if (!room.rankedGames || room.rankedCurrentIndex === undefined) {
    console.log(`❌ [startRankedGame] Invalid room state - rankedGames: ${room.rankedGames}, rankedCurrentIndex: ${room.rankedCurrentIndex}`);
    return;
  }

  const gameType = room.rankedGames![room.rankedCurrentIndex!];
  const isHardcore = rankedService.isHardcoreGame(gameType);

  // 플레이어들을 다시 방에 join (이전 게임 화면에서 나갈 때 leave 했을 수 있음)
  for (const player of room.players) {
    if (player.socket && player.socket.connected) {
      player.socket.join(room.id);
      console.log(`🔄 [startRankedGame] Re-joined player ${player.nickname} to room ${room.id}`);
    }
  }

  // 프로필 설정 및 연승 정보 조회
  const playerProfiles = await Promise.all(
    room.players.map(async (p) => {
      const profile = p.userId ? await shopService.getUserProfileSettings(p.userId) : null;
      const streak = p.userId ? await coinService.getStreak(p.userId) : { currentStreak: 0 };
      return {
        id: p.id,
        nickname: p.nickname,
        userId: p.userId,
        avatarUrl: p.avatarUrl,
        streak: streak.currentStreak,
        profileSettings: profile,
      };
    })
  );

  room.gameType = gameType;
  room.isHardcore = isHardcore;
  room.status = 'playing';

  // 게임 인스턴스 생성
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
  } else if (gameType === 'numberbattle') {
    room.game = new NumberBattleGame();
  } else if (gameType === 'set') {
    room.game = new SetGame();
  } else if (gameType === 'mathrace') {
    room.game = new MathRaceGame();
  } else if (gameType === 'arrowdash') {
    room.game = new ArrowDashGame();
  } else if (gameType === 'timing') {
    room.game = new TimingGame();
  } else if (gameType === 'cardflip') {
    room.game = new CardFlipGame();
  } else if (gameType === 'sequence') {
    room.game = new SequenceGame(isHardcore);
  } else if (gameType === 'stroop') {
    room.game = new StroopGame(isHardcore);
  } else if (gameType === 'hexagon') {
    room.game = new HexagonGame(false);
  } else if (gameType === 'hunmin') {
    room.game = new HunminGame();
  }

  // 게임 시작 알림
  console.log(`📤 [startRankedGame] Emitting ranked_game_start to room ${room.id}: gameIndex=${room.rankedCurrentIndex}, gameType=${gameType}`);
  io.to(room.id).emit('ranked_game_start', {
    gameIndex: room.rankedCurrentIndex,
    gameType,
    isHardcore,
    results: room.rankedResults,
  });

  // 클라이언트가 게임 화면으로 이동할 시간을 주고 match_found + game_start 전송
  setTimeout(() => {
    // 플레이어가 나갔는지 다시 확인
    if (room.status === 'finished' || room.players.length < 2) {
      console.log(`❌ [startRankedGame] Room ${room.id} is no longer valid (status: ${room.status}, players: ${room.players.length}), aborting match_found/game_start`);
      return;
    }
    console.log(`📤 [startRankedGame] Emitting match_found to room ${room.id} (1.5s after ranked_game_start)`);
    console.log(`📤 [startRankedGame] Players in room: ${room.players.map(p => p.nickname).join(', ')}`);
    // GameProvider를 위한 match_found 이벤트 전송 (프로필 정보 포함)
    io.to(room.id).emit('match_found', {
      roomId: room.id,
      players: playerProfiles,
      isRanked: true,
      isHardcore,
    });
    console.log(`📤 [startRankedGame] match_found emitted`);

    // 게임 타입별 시작
    console.log(`📤 [startRankedGame] Emitting game_start for gameType=${gameType}`);
    if (gameType === 'reaction') {
      io.to(room.id).emit('game_start', { gameType: 'reaction' });
      console.log(`📤 [startRankedGame] game_start emitted for reaction`);
      scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
    } else if (gameType === 'rps') {
      io.to(room.id).emit('game_start', { gameType: 'rps' });
      console.log(`📤 [startRankedGame] game_start emitted for rps`);
      scheduleRoundStart(room, 1000, () => startRpsRound(io, room));
    } else if (gameType === 'speedtap') {
      io.to(room.id).emit('game_start', { gameType: 'speedtap' });
      console.log(`📤 [startRankedGame] game_start emitted for speedtap`);
      scheduleRoundStart(room, 1000, () => startSpeedTapRound(io, room));
    } else if (gameType === 'numberbattle') {
      io.to(room.id).emit('game_start', { gameType: 'numberbattle' });
      console.log(`📤 [startRankedGame] game_start emitted for numberbattle`);
      scheduleRoundStart(room, 1000, () => startNumberBattle(io, room));
    } else if (gameType === 'set') {
      io.to(room.id).emit('game_start', { gameType: 'set' });
      scheduleRoundStart(room, 1000, () => startSet(io, room));
    } else if (gameType === 'mathrace') {
      io.to(room.id).emit('game_start', { gameType: 'mathrace' });
      console.log(`📤 [startRankedGame] game_start emitted for mathrace`);
      scheduleRoundStart(room, 1000, () => startMathrace(io, room));
    } else if (gameType === 'arrowdash') {
      io.to(room.id).emit('game_start', { gameType: 'arrowdash' });
      console.log(`📤 [startRankedGame] game_start emitted for arrowdash`);
      scheduleRoundStart(room, 1000, () => startArrowdash(io, room));
    } else if (gameType === 'timing') {
      io.to(room.id).emit('game_start', { gameType: 'timing' });
      console.log(`📤 [startRankedGame] game_start emitted for timing`);
      scheduleRoundStart(room, 1000, () => startTimingRound(io, room));
    } else if (gameType === 'cardflip') {
      io.to(room.id).emit('game_start', { gameType: 'cardflip' });
      console.log(`📤 [startRankedGame] game_start emitted for cardflip`);
      scheduleRoundStart(room, 1000, () => startCardFlip(io, room));
    } else if (gameType === 'sequence') {
      const seqGame = room.game as SequenceGame;
      io.to(room.id).emit('game_start', {
        gameType: 'sequence',
        gridSize: seqGame.getGridSize(),
        sequence: seqGame.getSequence(),
        level: seqGame.getCurrentLevel(),
        showDelay: seqGame.getShowDelay(),
        isHardcore: seqGame.getIsHardcore(),
        timeLimit: seqGame.getTimeLimit(),
      });
      console.log(`📤 [startRankedGame] game_start emitted for sequence`);
      scheduleExistingSequencePhase(io, room);
    } else if (gameType === 'stroop') {
      const stroopGame = room.game as StroopGame;
      io.to(room.id).emit('game_start', {
        gameType: 'stroop',
        isHardcore: stroopGame.getIsHardcore(),
        colors: stroopGame.getColors(),
      });
      console.log(`📤 [startRankedGame] game_start emitted for stroop`);
      scheduleRoundStart(room, 1000, () => startStroopRound(io, room));
    } else if (gameType === 'hexagon') {
      io.to(room.id).emit('game_start', {
        gameType: 'hexagon',
        isSolo: false,
      });
      console.log(`📤 [startRankedGame] game_start emitted for hexagon`);
      setTimeout(() => startHexagonRound(io, room), 1000);
    } else if (gameType === 'hunmin') {
      io.to(room.id).emit('game_start', {
        gameType: 'hunmin',
      });
      console.log(`📤 [startRankedGame] game_start emitted for hunmin`);
      setTimeout(() => startHunminRound(io, room), 1000);
    } else {
      // 턴제 게임
      startTurnTimer(io, room);
      const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
      io.to(room.id).emit('game_start', {
        currentTurn: room.players[0].id,
        board: turnGame?.getBoard(),
        turnTimeLimit: getTurnTimeLimit(room),
        turnStartTime: room.turnStartTime,
      });
      console.log(`📤 [startRankedGame] game_start emitted for turn-based game (${gameType})`);
    }
  }, 1500); // 1.5초 딜레이

  console.log(`🎮 Ranked game ${room.rankedCurrentIndex! + 1}/3 started: ${gameType} ${isHardcore ? '(하드코어)' : ''}`);
}

// 랭크전 개별 게임 종료 처리
async function handleRankedGameEnd(io: Server, room: GameRoom, winnerIndex: number | null) {
  try {
    await handleRankedGameEndInner(io, room, winnerIndex);
  } catch (err) {
    console.error('[handleRankedGameEnd] fatal error:', err);
  }
}

async function handleRankedGameEndInner(io: Server, room: GameRoom, winnerIndex: number | null) {
  if (!room.isRanked) return;

  // 플레이어가 나갔을 수 있으므로 안전하게 접근
  const winnerPlayer = winnerIndex !== null ? room.players[winnerIndex] : null;
  const winnerId = winnerPlayer?.userId ?? null;

  // 결과 기록
  room.rankedResults!.push({
    gameType: room.gameType,
    winnerId: winnerId ?? null,
  });

  // 현재 스코어 계산 (플레이어가 나갔을 수 있으므로 안전하게 접근)
  const player1Id = room.players[0]?.userId;
  const player2Id = room.players[1]?.userId;
  const player1Wins = room.rankedResults!.filter(r => r.winnerId === player1Id).length;
  const player2Wins = room.rankedResults!.filter(r => r.winnerId === player2Id).length;

  // 게임 결과 알림
  io.to(room.id).emit('ranked_game_end', {
    gameIndex: room.rankedCurrentIndex,
    gameType: room.gameType,
    winnerId: winnerId,
    winnerNickname: winnerPlayer?.nickname ?? null,
    results: room.rankedResults,
    score: [player1Wins, player2Wins],
  });

  console.log(`🏆 Ranked game ${room.rankedCurrentIndex! + 1}/3 ended: ${room.gameType} - Score: ${player1Wins}-${player2Wins}`);

  // 3판이 모두 끝났는지 확인
  const allGamesPlayed = room.rankedResults!.length >= 3;

  // 2승 달성 체크 또는 3판 모두 종료
  if (player1Wins >= 2 || player2Wins >= 2) {
    // Bo3 종료 - 2승 달성
    await finishRankedMatch(io, room, player1Wins >= 2 ? 0 : 1);
  } else if (allGamesPlayed) {
    // 3판 모두 종료됨 - 무승부가 있어서 2승에 도달 못함
    // 더 많이 이긴 사람이 승자, 동점이면 LP 높은 쪽이 패배 (30% 페널티)
    if (player1Wins > player2Wins) {
      console.log(`🏆 Ranked match ended by win count: Player 1 wins (${player1Wins}-${player2Wins})`);
      await finishRankedMatch(io, room, 0);
    } else if (player2Wins > player1Wins) {
      console.log(`🏆 Ranked match ended by win count: Player 2 wins (${player1Wins}-${player2Wins})`);
      await finishRankedMatch(io, room, 1);
    } else {
      // 완전 동점 (예: 1-1-1 무승부) - LP 높은 쪽이 패배 (30% 페널티)
      console.log(`🤝 Ranked match is a draw (${player1Wins}-${player2Wins}) - higher ELO loses with 30% penalty`);
      await finishRankedMatchAsDraw(io, room);
    }
  } else {
    // 다음 게임
    room.rankedCurrentIndex!++;
    room.status = 'finished'; // 잠시 finished로 설정

    console.log(`⏳ [handleRankedGameEnd] Scheduling next game (index ${room.rankedCurrentIndex}) in 5 seconds...`);
    console.log(`⏳ [handleRankedGameEnd] Next game will be: ${room.rankedGames![room.rankedCurrentIndex!]}`);
    console.log(`⏳ [handleRankedGameEnd] Players still in room: ${room.players.map(p => `${p.nickname} (${p.id})`).join(', ')}`);

    // 5초 후 다음 게임 시작 (클라이언트가 게임 화면에서 나올 시간 확보)
    setTimeout(() => {
      try {
        console.log(`🎮 [handleRankedGameEnd] Starting next game now for room ${room.id}`);
        console.log(`🎮 [handleRankedGameEnd] Room still exists: ${rooms.has(room.id)}`);
        console.log(`🎮 [handleRankedGameEnd] Players count: ${room.players.length}`);
        if (room.players.length < 2) {
          console.log(`❌ [handleRankedGameEnd] Not enough players! Aborting next game.`);
          return;
        }
        startRankedGame(io, room);
      } catch (err) {
        console.error('[handleRankedGameEnd] next game timer error:', err);
      }
    }, 5000);
  }
}

// 랭크 매치 최종 종료
async function finishRankedMatch(io: Server, room: GameRoom, winnerIndex: number) {
  room.status = 'finished';
  clearTurnTimer(room);
  clearRoundTimer(room);

  const winner = room.players[winnerIndex];
  const loser = room.players[winnerIndex === 0 ? 1 : 0];

  if (!winner.userId || !loser.userId) {
    console.error('Ranked match finished but players missing userId');
    return;
  }

  // ELO 업데이트
  const result = await rankedService.updateRankedResult(
    winner.userId,
    loser.userId,
    room.rankedResults!.map(r => ({
      gameType: r.gameType,
      winnerId: r.winnerId!,
    }))
  );

  // 결과 알림
  io.to(room.id).emit('ranked_match_end', {
    winnerId: winner.userId,
    winnerNickname: winner.nickname,
    loserId: loser.userId,
    loserNickname: loser.nickname,
    results: room.rankedResults,
    winnerStats: result.winnerStats,
    loserStats: result.loserStats,
    winnerEloChange: result.winnerEloChange,
    loserEloChange: result.loserEloChange,
  });

  console.log(`🏆 Ranked match ended: ${winner.nickname} wins! (+${result.winnerEloChange} ELO)`);
  console.log(`   ${loser.nickname} loses (${result.loserEloChange} ELO)`);
}

// 랭크 매치 무승부 종료 (LP 높은 쪽이 30% 페널티로 패배)
async function finishRankedMatchAsDraw(io: Server, room: GameRoom) {
  room.status = 'finished';
  clearTurnTimer(room);
  clearRoundTimer(room);

  const player1 = room.players[0];
  const player2 = room.players[1];

  if (!player1.userId || !player2.userId) {
    console.error('Ranked match finished but players missing userId');
    return;
  }

  // 두 플레이어의 현재 ELO 조회
  const player1Stats = await rankedService.getRankedStats(player1.userId);
  const player2Stats = await rankedService.getRankedStats(player2.userId);

  // LP가 높은 쪽이 패자, 낮은 쪽이 승자
  let winner: typeof player1;
  let loser: typeof player1;
  let winnerStats: typeof player1Stats;
  let loserStats: typeof player1Stats;

  if (player1Stats.elo >= player2Stats.elo) {
    // Player1이 ELO가 높거나 같으면 Player1이 패배
    winner = player2;
    loser = player1;
    winnerStats = player2Stats;
    loserStats = player1Stats;
  } else {
    // Player2가 ELO가 높으면 Player2가 패배
    winner = player1;
    loser = player2;
    winnerStats = player1Stats;
    loserStats = player2Stats;
  }

  // 무승부이므로 30% 페널티만 적용
  const result = await rankedService.updateRankedResultAsDraw(
    winner.userId!,
    loser.userId!,
    room.rankedResults!.map(r => ({
      gameType: r.gameType,
      winnerId: r.winnerId!,
    }))
  );

  // 결과 알림
  io.to(room.id).emit('ranked_match_end', {
    winnerId: winner.userId,
    winnerNickname: winner.nickname,
    loserId: loser.userId,
    loserNickname: loser.nickname,
    results: room.rankedResults,
    winnerStats: result.winnerStats,
    loserStats: result.loserStats,
    winnerEloChange: result.winnerEloChange,
    loserEloChange: result.loserEloChange,
    isDraw: true,  // 무승부 플래그
  });

  console.log(`🤝 Ranked match draw: ${winner.nickname} wins (higher ELO opponent) (+${result.winnerEloChange} ELO)`);
  console.log(`   ${loser.nickname} loses with 30% penalty (${result.loserEloChange} ELO)`);
}

export function setupSocketHandlers(io: Server) {
  io.on('connection', (socket: Socket) => {
    console.log(`👤 Player connected: ${socket.id}`);

    // 플레이어 정보
    let currentPlayer: Player | null = null;
    let currentRoomId: string | null = null;

    // 로비 입장 / 인증
    // 신규 클라이언트는 핸드셰이크(socket.handshake.auth)로, 구버전 클라이언트는
    // join_lobby 이벤트로 인증 정보를 보낸다. 두 경로 모두 handleAuth 로 처리한다.
    let authenticated = false;
    const handleAuth = async (data: {
      nickname: string;
      userId?: number;
      avatarUrl?: string;
      token?: string;
      deviceInfo?: {
        platform?: string;
        osVersion?: string;
        deviceModel?: string;
        appVersion?: string;
        buildNumber?: string;
      };
    }) => {
      if (authenticated) return;
      authenticated = true;
      console.log(`📥 auth received:`, { nickname: data.nickname, userId: data.userId });

      let verifiedUserId: number | undefined;
      let verifiedNickname = data.nickname;
      let verifiedAvatarUrl = data.avatarUrl;

      if (data.token) {
        const payload = verifyToken(data.token);
        if (!payload) {
          socket.emit('auth_error', { message: 'Invalid or expired token' });
          return;
        }

        try {
          const user = await findUserById(payload.userId);
          if (!user) {
            socket.emit('auth_error', { message: 'User not found' });
            return;
          }

          await assertUserNotBanned(user.id);

          verifiedUserId = user.id;
          verifiedNickname = user.nickname;
          verifiedAvatarUrl = user.avatar_url ?? undefined;
        } catch (error) {
          socket.emit('auth_error', {
            message: error instanceof Error ? error.message : 'Authentication failed',
          });
          return;
        }
      } else if (data.userId != null) {
        socket.emit('auth_error', { message: 'Authentication required' });
        return;
      }

      try {
        currentPlayer = {
          id: socket.id,
          socket,
          nickname: verifiedNickname,
          userId: verifiedUserId,
          avatarUrl: verifiedAvatarUrl,
        };
      } catch (error) {
        socket.emit('auth_error', {
          message: error instanceof Error ? error.message : 'Failed to join lobby',
        });
        return;
      }

      // 유저 ID가 있으면 소켓 매핑
      if (verifiedUserId) {
        userSockets.set(verifiedUserId, socket);
        console.log(`👤 User ${verifiedUserId} mapped to socket ${socket.id}`);

        // 친구 코드 자동 생성 (없으면)
        try {
          const code = await friendService.generateFriendCode(verifiedUserId);
          console.log(`🔑 Friend code for user ${verifiedUserId}: ${code}`);
        } catch (error) {
          console.error('Failed to generate friend code:', error);
        }

        // 접속 기록 저장
        if (data.deviceInfo) {
          try {
            const ipAddress = socket.handshake.headers['x-forwarded-for'] as string ||
                              socket.handshake.address ||
                              'unknown';
            await saveUserSession(verifiedUserId, ipAddress, data.deviceInfo);
            console.log(`📱 Session saved for user ${verifiedUserId}: ${data.deviceInfo.platform} ${data.deviceInfo.osVersion}`);
          } catch (error) {
            console.error('Failed to save user session:', error);
          }
        }
      } else {
        console.log(`⚠️ No authenticated userId provided for ${data.nickname}`);
      }

      // 재연결 유예 중인 유저 체크 → 게임 복귀
      if (verifiedUserId && disconnectGraceTimers.has(verifiedUserId)) {
        clearTimeout(disconnectGraceTimers.get(verifiedUserId)!);
        disconnectGraceTimers.delete(verifiedUserId);
        disconnectContexts.delete(verifiedUserId);
        expiredReconnectUsers.delete(verifiedUserId);
        console.log(`🔄 User ${verifiedUserId} reconnected within grace period`);

        const existingRoomId = userRooms.get(verifiedUserId);
        if (existingRoomId) {
          const room = rooms.get(existingRoomId);
          if (room && (room.status === 'playing' || room.status === 'waiting')) {
            const playerInRoom = room.players.find(p => p.userId === verifiedUserId);
            if (playerInRoom) {
              // 소켓 교체
              playerInRoom.socket = socket;
              playerInRoom.id = socket.id;
              playerInRoom.nickname = verifiedNickname;
              playerInRoom.avatarUrl = verifiedAvatarUrl;
              socket.join(existingRoomId);
              currentRoomId = existingRoomId;
              currentPlayer = playerInRoom;

              // 상대에게 재연결 알림
              socket.to(existingRoomId).emit('opponent_reconnected');

              // 게임 상태 전송
              emitRejoinState(socket, room, verifiedUserId);
              resumePausedGame(io, room);

              console.log(`✅ User ${verifiedUserId} rejoined room ${existingRoomId}`);
            }
          }
        }
      }

      if (verifiedUserId && expiredReconnectUsers.has(verifiedUserId)) {
        expiredReconnectUsers.delete(verifiedUserId);
        socket.emit('reconnect_failed', {
          reason: 'grace_expired',
        });
      }

      socket.emit('lobby_joined', { success: true });
      console.log(`🎮 ${verifiedNickname} joined lobby`);
    };

    // 신규 클라이언트: 핸드셰이크 auth 로 connection 시점에 즉시 인증.
    const handshakeAuth = socket.handshake.auth as {
      nickname?: string;
      userId?: number;
      avatarUrl?: string;
      token?: string;
      deviceInfo?: {
        platform?: string;
        osVersion?: string;
        deviceModel?: string;
        appVersion?: string;
        buildNumber?: string;
      };
    };
    if (handshakeAuth && (handshakeAuth.nickname || handshakeAuth.token)) {
      void handleAuth(handshakeAuth as { nickname: string });
    }

    // 구버전 클라이언트 호환: join_lobby 이벤트로도 인증 가능.
    socket.on('join_lobby', handleAuth);

    // 방 ID 설정 (초대 게임에서 초대자용)
    socket.on('set_room_id', (data: { roomId: string }) => {
      console.log(`🏠 set_room_id: ${currentPlayer?.nickname} -> ${data.roomId}`);
      currentRoomId = data.roomId;
    });

    // 헥사곤 솔로 모드 시작
    socket.on('hexagon_solo_start', async () => {
      if (!currentPlayer) return;

      const roomId = `hexagon_solo_${socket.id}_${Date.now()}`;
      const room: GameRoom = {
        id: roomId,
        gameType: 'hexagon',
        players: [currentPlayer],
        game: new HexagonGame(true),
        status: 'playing',
        isSolo: true,
      };
      rooms.set(roomId, room);
      socket.join(roomId);
      currentRoomId = roomId;

      if (currentPlayer.userId) userRooms.set(currentPlayer.userId, roomId);

      socket.emit('hexagon_solo_ready', { roomId });

      io.to(roomId).emit('game_start', {
        gameType: 'hexagon',
        isSolo: true,
      });

      setTimeout(() => startHexagonRound(io, room), 1000);
      console.log(`🔷 Hexagon solo started: ${currentPlayer.nickname}`);
    });

    // 헥사곤 솔로 도전 종료 (기록 저장)
    socket.on('hexagon_solo_end', async (data: { roomId: string }) => {
      if (!currentPlayer) return;
      const room = rooms.get(data.roomId);
      if (!room || !(room.game instanceof HexagonGame) || !room.isSolo) return;
      if (room.status === 'finished') return;

      // 타이머 정리
      clearHexagonTimers(room);
      clearRoundTimer(room);

      const game = room.game;
      const scores = game.getScores();

      // 현재 라운드가 진행 중이면 종료 처리
      if (game.getRoundState() !== 'waiting' && game.getRoundState() !== 'finished') {
        game.finishRound();
      }

      room.status = 'finished';

      // 랭킹 저장
      if (currentPlayer.userId) {
        try {
          const pool = getPool();
          if (pool) {
            await pool.query(
              `INSERT INTO dm_hexagon_rankings (user_id, score, nickname)
               VALUES ($1, $2, $3)`,
              [currentPlayer.userId, scores[0], currentPlayer.nickname]
            );
          }
        } catch (err) {
          console.error('Failed to save hexagon ranking:', err);
        }
      }

      socket.emit('game_end', {
        winner: null,
        winnerNickname: null,
        isDraw: false,
        scores,
        isSolo: true,
        roundResults: game.getRoundResults(),
      });

      // 방 정리
      if (currentPlayer.userId) userRooms.delete(currentPlayer.userId);
      rooms.delete(data.roomId);

      console.log(`🔷 Hexagon solo ended by player: ${currentPlayer.nickname}, score=${scores[0]}`);
    });

    // 헥사곤 랭킹 조회
    socket.on('hexagon_get_rankings', async (data: { limit?: number }) => {
      try {
        const pool = getPool();
        if (!pool) {
          socket.emit('hexagon_rankings', { rankings: [] });
          return;
        }
        const limit = data?.limit || 50;
        const result = await pool.query(
          `SELECT user_id, nickname, MAX(score) as score, MAX(created_at) as created_at
           FROM dm_hexagon_rankings
           GROUP BY user_id, nickname
           ORDER BY score DESC
           LIMIT $1`,
          [limit]
        );
        socket.emit('hexagon_rankings', { rankings: result.rows });
      } catch (err) {
        console.error('Failed to get hexagon rankings:', err);
        socket.emit('hexagon_rankings', { rankings: [] });
      }
    });

    // 헥사곤 라운드 스킵 요청
    socket.on('hexagon_skip_round', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (!room || room.gameType !== 'hexagon' || !(room.game instanceof HexagonGame)) return;
      if (room.status !== 'playing' || room.game.getRoundState() !== 'playing') return;
      if (!room.skipVotes) return; // 스킵 아직 활성화 안 됨

      const playerIndex = room.players.findIndex(p => p.id === socket.id);
      if (playerIndex === -1) return;

      room.skipVotes.add(playerIndex);
      console.log(`🔷 Hexagon skip vote: player ${playerIndex} in room ${room.id} (${room.skipVotes.size}/2)`);

      // 상대에게 스킵 투표 알림
      socket.to(data.roomId).emit('hexagon_skip_voted', { playerIndex });

      // 양쪽 모두 투표하면 라운드 종료
      if (room.skipVotes.size >= 2) {
        console.log(`🔷 Hexagon round skipped by both players in room ${room.id}`);
        finishHexagonRound(io, room);
      }
    });

    // 피라미드 솔로 모드 시작
    socket.on('pyramid_solo_start', async () => {
      if (!currentPlayer) return;

      const roomId = `pyramid_solo_${socket.id}_${Date.now()}`;
      const room: GameRoom = {
        id: roomId,
        gameType: 'pyramid',
        players: [currentPlayer],
        game: new PyramidGame(true),
        status: 'playing',
        isSolo: true,
      };
      rooms.set(roomId, room);
      socket.join(roomId);
      currentRoomId = roomId;

      if (currentPlayer.userId) userRooms.set(currentPlayer.userId, roomId);

      socket.emit('pyramid_solo_ready', { roomId });

      io.to(roomId).emit('game_start', {
        gameType: 'pyramid',
        isSolo: true,
      });

      setTimeout(() => startPyramidRound(io, room), 1000);
      console.log(`🔺 Pyramid solo started: ${currentPlayer.nickname}`);
    });

    // 피라미드 솔로 도전 종료 (기록 저장)
    socket.on('pyramid_solo_end', async (data: { roomId: string }) => {
      if (!currentPlayer) return;
      const room = rooms.get(data.roomId);
      if (!room || !(room.game instanceof PyramidGame) || !room.isSolo) return;
      if (room.status === 'finished') return;

      clearPyramidTimers(room);

      const game = room.game;
      const scores = game.getScores();

      if (game.getRoundState() !== 'waiting' && game.getRoundState() !== 'finished') {
        game.finishRound();
      }

      room.status = 'finished';

      // 랭킹 저장
      if (currentPlayer.userId) {
        try {
          const pool = getPool();
          if (pool) {
            await pool.query(
              `INSERT INTO dm_pyramid_rankings (user_id, score, nickname)
               VALUES ($1, $2, $3)`,
              [currentPlayer.userId, scores[0], currentPlayer.nickname]
            );
          }
        } catch (err) {
          console.error('Failed to save pyramid ranking:', err);
        }
      }

      socket.emit('game_end', {
        winner: null,
        winnerNickname: null,
        isDraw: false,
        scores,
        isSolo: true,
        roundResults: game.getRoundResults(),
      });

      if (currentPlayer.userId) userRooms.delete(currentPlayer.userId);
      rooms.delete(data.roomId);

      console.log(`🔺 Pyramid solo ended by player: ${currentPlayer.nickname}, score=${scores[0]}`);
    });

    // 피라미드 랭킹 조회
    socket.on('pyramid_get_rankings', async (data: { limit?: number }) => {
      try {
        const pool = getPool();
        if (!pool) {
          socket.emit('pyramid_rankings', { rankings: [] });
          return;
        }
        const limit = data?.limit || 50;
        const result = await pool.query(
          `SELECT user_id, nickname, MAX(score) as score, MAX(created_at) as created_at
           FROM dm_pyramid_rankings
           GROUP BY user_id, nickname
           ORDER BY score DESC
           LIMIT $1`,
          [limit]
        );
        socket.emit('pyramid_rankings', { rankings: result.rows });
      } catch (err) {
        console.error('Failed to get pyramid rankings:', err);
        socket.emit('pyramid_rankings', { rankings: [] });
      }
    });

    // Set 솔로 도전 시작 — 덱 끝까지 가는 무한모드 SetGame을 1인 방으로 구동.
    socket.on('set_solo_start', async () => {
      if (!currentPlayer) return;

      const roomId = `set_solo_${socket.id}_${Date.now()}`;
      const room: GameRoom = {
        id: roomId,
        gameType: 'set',
        players: [currentPlayer],
        game: new SetGame(true), // 무한: 6점 선취 없이 덱 소진까지
        status: 'playing',
        isSolo: true,
      };
      rooms.set(roomId, room);
      socket.join(roomId);
      currentRoomId = roomId;

      if (currentPlayer.userId) userRooms.set(currentPlayer.userId, roomId);

      socket.emit('set_solo_ready', { roomId });

      // 보드 노출 + 시간 측정 시작(startSet 내부에서 soloStartAt 설정).
      setTimeout(() => startSet(io, room), 1000);
      console.log(`🃏 Set solo started: ${currentPlayer.nickname}`);
    });

    // Set 솔로 랭킹 조회 — 시간(ms) 오름차순, 유저별 최고 기록.
    socket.on('set_get_rankings', async (data: { limit?: number }) => {
      try {
        const pool = getPool();
        if (!pool) {
          socket.emit('set_rankings', { rankings: [] });
          return;
        }
        const limit = data?.limit || 50;
        const result = await pool.query(
          `SELECT * FROM (
             SELECT DISTINCT ON (user_id) user_id, nickname, time_ms, sets_found, created_at
             FROM dm_set_rankings
             ORDER BY user_id, time_ms ASC
           ) best
           ORDER BY time_ms ASC
           LIMIT $1`,
          [limit]
        );
        socket.emit('set_rankings', { rankings: result.rows });
      } catch (err) {
        console.error('Failed to get set rankings:', err);
        socket.emit('set_rankings', { rankings: [] });
      }
    });

    // [SET 무한] 게임 종료 합의 요청 — 무한모드 대결에서만. 요청자는 자동 동의,
    // 나머지(활성 플레이어)가 모두 동의하면 현재 점수로 게임을 종료한다.
    socket.on('set_request_end', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (!room || room.status !== 'playing') return;
      if (room.gameType !== 'set' || !(room.game instanceof SetGame)) return;
      if (!room.game.getIsInfinite() || room.isSolo) return; // 무한 대결만
      if (room.players.length < 2 || room.endRequest) return;
      const requester = room.players.find(p => p.id === socket.id);
      if (!requester || room.leftPlayerIds?.has(socket.id)) return;

      room.endRequest = { requesterId: socket.id, agreed: new Set([socket.id]) };
      socket.to(room.id).emit('set_end_requested', {
        requesterId: socket.id,
        nickname: requester.nickname,
      });
      emitSetEndProgress(io, room);
      console.log(`🛑 SET 종료요청: ${requester.nickname}`);
    });

    socket.on('set_end_vote', async (data: { roomId: string; agree: boolean }) => {
      const room = rooms.get(data.roomId);
      if (!room || !room.endRequest || room.status !== 'playing') return;
      if (!(room.game instanceof SetGame)) return;
      const voter = room.players.find(p => p.id === socket.id);
      if (!voter || room.leftPlayerIds?.has(socket.id)) return;

      if (!data.agree) {
        // 한 명이라도 거절 → 요청 취소
        room.endRequest = undefined;
        io.to(room.id).emit('set_end_cancelled', { nickname: voter.nickname });
        console.log(`🛑 SET 종료요청 거절: ${voter.nickname}`);
        return;
      }

      room.endRequest.agreed.add(socket.id);
      const active = room.players.filter(p => !room.leftPlayerIds?.has(p.id));
      const allAgreed =
        active.length > 0 && active.every(p => room.endRequest!.agreed.has(p.id));
      if (allAgreed) {
        room.endRequest = undefined;
        if (!room.game.isGameOver()) room.game.setGameOver(); // 현재 점수로 승부 확정
        console.log(`🛑 SET 종료요청 전원동의 → 종료`);
        await finishSetGame(io, room);
      } else {
        emitSetEndProgress(io, room);
      }
    });

    // 피라미드 라운드 스킵 요청
    socket.on('pyramid_skip_round', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (!room || room.gameType !== 'pyramid' || !(room.game instanceof PyramidGame)) return;
      if (room.status !== 'playing' || room.game.getRoundState() !== 'playing') return;
      if (!room.skipVotes) return; // 스킵 아직 활성화 안 됨

      const playerIndex = room.players.findIndex(p => p.id === socket.id);
      if (playerIndex === -1) return;

      room.skipVotes.add(playerIndex);
      console.log(`🔺 Pyramid skip vote: player ${playerIndex} in room ${room.id} (${room.skipVotes.size}/2)`);

      // 상대에게 스킵 투표 알림
      socket.to(data.roomId).emit('pyramid_skip_voted', { playerIndex });

      // 양쪽 모두 투표하면 라운드 종료
      if (room.skipVotes.size >= 2) {
        console.log(`🔺 Pyramid round skipped by both players in room ${room.id}`);
        finishPyramidRound(io, room);
      }
    });

    // 게임 매칭 요청
    socket.on('find_match', async (data: { gameType: string; isHardcore?: boolean; isInfinite?: boolean; maxPlayers?: number }) => {
      if (!currentPlayer) {
        socket.emit('error', { message: 'Please join lobby first' });
        return;
      }

      const { gameType, isHardcore = false, isInfinite = false } = data;
      const maxPlayers = Math.min(4, Math.max(2, data.maxPlayers ?? 2));

      // [3·4인] N인 매칭 — 기존 2인 경로와 완전히 분리. SET·훈민정음이 maxPlayers>2 를 보낸다.
      // 큐가 N명 찰 때까지 대기하다 방을 생성한다(랭크·친구초대 미지원, 랜덤매칭 전용).
      if ((gameType === 'set' || gameType === 'hunmin') && maxPlayers > 2) {
        const key = getQueueKey(gameType, isHardcore, isInfinite, maxPlayers);
        if (!matchQueues.has(key)) matchQueues.set(key, []);
        const q = matchQueues.get(key)!;
        // 같은 소켓이 큐에 중복으로 들어가지 않게 방어
        const dupIdx = q.findIndex(p => p.id === socket.id);
        if (dupIdx !== -1) q.splice(dupIdx, 1);

        if (q.length >= maxPlayers - 1) {
          const others = q.splice(0, maxPlayers - 1);
          const players = [...others, currentPlayer];
          const roomId = `${gameType}_${isInfinite ? 'inf_' : ''}p${maxPlayers}_${Date.now()}`;
          const game = gameType === 'hunmin'
            ? new HunminGame(maxPlayers)
            : new SetGame(isInfinite, maxPlayers);
          const room: GameRoom = {
            id: roomId,
            gameType,
            players,
            game,
            status: 'waiting',
            isHardcore,
            isInfinite,
          };
          rooms.set(roomId, room);
          for (const p of players) {
            p.socket.join(roomId);
            if (p.userId) userRooms.set(p.userId, roomId);
          }
          currentRoomId = roomId;

          const playerInfos = await Promise.all(players.map(async (p) => ({
            id: p.id,
            nickname: p.nickname,
            userId: p.userId,
            avatarUrl: p.avatarUrl,
            streak: p.userId ? (await coinService.getStreak(p.userId)).currentStreak : 0,
            profileSettings: p.userId ? await shopService.getUserProfileSettings(p.userId) : null,
          })));

          io.to(roomId).emit('match_found', {
            roomId,
            gameType,
            isHardcore,
            isInfinite,
            maxPlayers,
            players: playerInfos,
            dailyMatchCount: 0,
          });
          console.log(`🎯 ${gameType.toUpperCase()} ${maxPlayers}인 매칭: ${players.map(p => p.nickname).join(', ')} ${isInfinite ? '(무한)' : ''}`);

          room.status = 'playing';
          if (gameType === 'hunmin') {
            io.to(roomId).emit('game_start', { gameType: 'hunmin' });
            scheduleRoundStart(room, 1000, () => startHunminRound(io, room));
          } else {
            scheduleRoundStart(room, 1000, () => startSet(io, room));
          }
        } else {
          q.push(currentPlayer);
          socket.emit('match_waiting', { gameType, maxPlayers, waiting: q.length });
          console.log(`⏳ ${gameType.toUpperCase()} ${maxPlayers}인 대기: ${currentPlayer.nickname} (${q.length}/${maxPlayers})`);
        }
        return;
      }

      const queueKey = getQueueKey(gameType, isHardcore, isInfinite);

      if (!matchQueues.has(queueKey)) {
        matchQueues.set(queueKey, []);
      }

      const queue = matchQueues.get(queueKey)!;

      // 이미 대기열에 상대가 있으면 매칭
      if (queue.length > 0) {
        const opponent = queue.shift()!;

        // 방 생성
        const roomId = `${gameType}_${isInfinite ? 'inf_' : ''}${isHardcore ? 'hc_' : ''}${Date.now()}`;
        const room: GameRoom = {
          id: roomId,
          // 무한모드 틱택토만 게임타입을 바꾼다. SET 등 다른 게임의 무한모드는
          // gameType은 그대로 두고 isInfinite 플래그로 변형을 처리한다.
          gameType: (gameType === 'tictactoe' && isInfinite) ? 'infinite_tictactoe' : gameType,
          players: [opponent, currentPlayer],
          game: null,
          status: 'waiting',
          isHardcore,
          isInfinite,
        };

        // 게임 초기화
        if (gameType === 'tictactoe' && isInfinite) {
          room.game = new InfiniteTicTacToeGame();
        } else if (gameType === 'tictactoe') {
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
        } else if (gameType === 'numberbattle') {
          room.game = new NumberBattleGame();
        } else if (gameType === 'set') {
          room.game = new SetGame(isInfinite);
        } else if (gameType === 'mathrace') {
          room.game = new MathRaceGame();
        } else if (gameType === 'arrowdash') {
          room.game = new ArrowDashGame();
        } else if (gameType === 'timing') {
          room.game = new TimingGame();
        } else if (gameType === 'cardflip') {
          room.game = new CardFlipGame();
        } else if (gameType === 'sequence') {
          room.game = new SequenceGame(isHardcore);
        } else if (gameType === 'stroop') {
          room.game = new StroopGame(isHardcore);
        } else if (gameType === 'hexagon') {
          room.game = new HexagonGame(false);
        } else if (gameType === 'pyramid') {
          room.game = new PyramidGame();
        } else if (gameType === 'hunmin') {
          room.game = new HunminGame();
        }

        rooms.set(roomId, room);

        // 두 플레이어를 방에 조인
        opponent.socket.join(roomId);
        socket.join(roomId);
        currentRoomId = roomId;

        // 유저별 현재 게임 룸 기록
        if (currentPlayer.userId) userRooms.set(currentPlayer.userId, roomId);
        if (opponent.userId) userRooms.set(opponent.userId, roomId);

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
          gameType: room.gameType,  // 무한모드면 infinite_tictactoe
          isHardcore,
          isInfinite,
          players: [
            { id: opponent.id, nickname: opponent.nickname, userId: opponent.userId, avatarUrl: opponent.avatarUrl, streak: opponentStreak.currentStreak, profileSettings: opponentProfile },
            { id: currentPlayer.id, nickname: currentPlayer.nickname, userId: currentPlayer.userId, avatarUrl: currentPlayer.avatarUrl, streak: currentPlayerStreak.currentStreak, profileSettings: currentPlayerProfile },
          ],
          dailyMatchCount: dailyMatchCount + 1,  // 이번 게임 포함
        });

        console.log(`🎯 Match found: ${opponent.nickname} vs ${currentPlayer.nickname} ${isInfinite ? '(무한)' : ''} ${isHardcore ? '(하드코어)' : ''}`);
        console.log(`🎮 gameType: '${gameType}'`);

        // 게임 시작
        room.status = 'playing';

        if (gameType === 'reaction') {
          // 반응속도 게임은 별도 시작 로직
          io.to(roomId).emit('game_start', {
            gameType: 'reaction',
          });
          // 1초 후 첫 라운드 시작
          scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
        } else if (gameType === 'rps') {
          // 가위바위보 게임
          io.to(roomId).emit('game_start', {
            gameType: 'rps',
          });
          // 1초 후 첫 라운드 시작
          scheduleRoundStart(room, 1000, () => startRpsRound(io, room));
        } else if (gameType === 'speedtap') {
          // 스피드탭 게임
          io.to(roomId).emit('game_start', {
            gameType: 'speedtap',
          });
          // 1초 후 첫 라운드 시작
          scheduleRoundStart(room, 1000, () => startSpeedTapRound(io, room));
        } else if (gameType === 'numberbattle') {
          // 숫자배틀 게임
          io.to(roomId).emit('game_start', {
            gameType: 'numberbattle',
          });
          scheduleRoundStart(room, 1000, () => startNumberBattle(io, room));
        } else if (gameType === 'set') {
          // Set 게임
          io.to(roomId).emit('game_start', {
            gameType: 'set',
          });
          scheduleRoundStart(room, 1000, () => startSet(io, room));
        } else if (gameType === 'mathrace') {
          // 사칙연산 스피드 게임
          io.to(roomId).emit('game_start', {
            gameType: 'mathrace',
          });
          scheduleRoundStart(room, 1000, () => startMathrace(io, room));
        } else if (gameType === 'arrowdash') {
          // 방향 맞추기 게임
          io.to(roomId).emit('game_start', {
            gameType: 'arrowdash',
          });
          scheduleRoundStart(room, 1000, () => startArrowdash(io, room));
        } else if (gameType === 'timing') {
          // 타이밍 맞추기 게임
          io.to(roomId).emit('game_start', {
            gameType: 'timing',
          });
          scheduleRoundStart(room, 1000, () => startTimingRound(io, room));
        } else if (gameType === 'cardflip') {
          // 카드 뒤집기 게임
          io.to(roomId).emit('game_start', {
            gameType: 'cardflip',
          });
          scheduleRoundStart(room, 1000, () => startCardFlip(io, room));
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
          scheduleExistingSequencePhase(io, room);
        } else if (gameType === 'stroop') {
          // 스트룹 게임
          const stroopGame = room.game as StroopGame;
          io.to(roomId).emit('game_start', {
            gameType: 'stroop',
            isHardcore: stroopGame.getIsHardcore(),
            colors: stroopGame.getColors(),
          });
          // 1초 후 첫 라운드 시작
          scheduleRoundStart(room, 1000, () => startStroopRound(io, room));
        } else if (gameType === 'hexagon') {
          // 헥사곤 게임
          io.to(roomId).emit('game_start', {
            gameType: 'hexagon',
            isSolo: false,
          });
          setTimeout(() => startHexagonRound(io, room), 1000);
        } else if (gameType === 'pyramid') {
          // 수식피라미드 게임
          io.to(roomId).emit('game_start', {
            gameType: 'pyramid',
          });
          setTimeout(() => startPyramidRound(io, room), 1000);
        } else if (gameType === 'hunmin') {
          // 훈민정음 게임
          io.to(roomId).emit('game_start', {
            gameType: 'hunmin',
          });
          setTimeout(() => startHunminRound(io, room), 1000);
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
    socket.on('cancel_match', (data: { gameType: string; isHardcore?: boolean; isInfinite?: boolean; maxPlayers?: number }) => {
      const { gameType, isHardcore = false, isInfinite = false } = data;
      const maxPlayers = Math.min(4, Math.max(2, data.maxPlayers ?? 2));
      const queueKey = getQueueKey(gameType, isHardcore, isInfinite, maxPlayers);
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
      // 이 핸들러 내부 어디서든 발생한 throw/reject가 프로세스나 다른 방에
      // 영향을 주지 않도록 최상위 try/catch로 감싼다. Stroop 등 타임아웃 기반
      // 게임에서 finalize 경로가 실패하면 양쪽 클라가 동시에 ping timeout으로
      // 연결 끊김을 판정하는 문제를 방지하기 위함.
      try {
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

      // 클라이언트 입력 검증: 보드 기반 게임(tictactoe 계열)은 position이 정수여야 한다.
      // NaN/음수/소수/undefined를 그대로 makeMove에 넘기면 배열 접근 에러로 게임이 깨진다.
      const isBoardGame =
        room.gameType === 'tictactoe' ||
        room.gameType === 'gomoku' ||
        room.gameType === 'infinite_tictactoe';
      if (isBoardGame) {
        const pos = data?.action?.position;
        if (typeof pos !== 'number' || !Number.isInteger(pos) || pos < 0 || pos >= 10000) {
          socket.emit('error', { message: 'Invalid move position' });
          return;
        }
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
          if (!markRoomFinishedOnce(room, 'tictactoe_game_end')) return;
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
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

          // 랭크전인 경우 추가 처리
          if (room.isRanked) {
            try {
              await handleRankedGameEnd(io, room, result.isDraw ? null : result.winner ?? null);
            } catch (err) {
              console.error('handleRankedGameEnd failed:', err);
            }
          }
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
          if (!markRoomFinishedOnce(room, 'infinite_tictactoe_game_end')) return;
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
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

          // 랭크전인 경우 추가 처리
          if (room.isRanked) {
            await handleRankedGameEnd(io, room, result.winner ?? null);
          }
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
          if (!markRoomFinishedOnce(room, 'gomoku_game_end')) return;
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
                  await statsService.saveGameRecord(player.userId, opponent.userId, room.gameType, gameResult, {
                    isRanked: room.isRanked,
                    rankedMatchId: room.isRanked ? room.id : undefined,
                    rankedGameIndex: room.isRanked ? room.rankedCurrentIndex : undefined,
                  });
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

          // 랭크전인 경우 추가 처리
          if (room.isRanked) {
            await handleRankedGameEnd(io, room, result.isDraw ? null : result.winner ?? null);
          }
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
          scheduleRoundStart(room, 2000, () => startReactionRound(io, room));
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
            scheduleRoundStart(room, 2000, () => startRpsRound(io, room));
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

      // 숫자배틀 게임 로직
      if (room.gameType === 'numberbattle' && room.game instanceof NumberBattleGame) {
        const row = data.action.row as number;
        const col = data.action.col as number;
        const result = room.game.tap(playerIndex, row, col);

        if (result.valid) {
          io.to(data.roomId).emit('numberbattle_tap', {
            playerId: socket.id,
            playerIndex,
            row,
            col,
            progress: room.game.getProgress(),
          });

          // 25 완성 시 게임 종료
          if (room.game.isGameOver()) {
            await finishNumberBattleGame(io, room);
          }
        }
      }

      // Set 게임 로직
      if (room.gameType === 'set' && room.game instanceof SetGame) {
        const cards = data.action.cards as number[];
        const result = room.game.claim(playerIndex, cards);

        if (result.valid) {
          io.to(data.roomId).emit('set_claimed', {
            playerId: socket.id,
            playerIndex,
            board: result.board,
            scores: result.scores,
            deckRemaining: result.deckRemaining,
            claimedCards: result.claimedCards,
          });

          if (room.game.isGameOver()) {
            // 솔로(시간 랭킹)는 대전용 보상/전적 경로 대신 솔로 종료 경로로.
            if (room.isSolo) {
              await finishSetSolo(io, room);
            } else {
              await finishSetGame(io, room);
            }
          }
        } else {
          // 거절: 오답이면 점수 -1이 반영됐을 수 있으니 방 전체에 점수 동기화 + 거절 알림.
          // (빨강/잠금 피드백은 클레임한 플레이어 클라에서만 처리)
          io.to(data.roomId).emit('set_claim_rejected', {
            playerIndex,
            reason: result.reason,
            scores: result.scores ?? room.game.getScores(),
          });
        }
      }

      // 사칙연�� 스피드 게임 로직
      if (room.gameType === 'mathrace' && room.game instanceof MathRaceGame) {
        const problemIndex = data.action.problemIndex as number;
        const answer = data.action.answer as number;
        const result = room.game.checkAnswer(playerIndex, problemIndex, answer);

        io.to(data.roomId).emit('mathrace_answer', {
          playerId: socket.id,
          playerIndex,
          problemIndex,
          correct: result.correct,
          progress: result.progress,
        });

        // 10문제 완성 시 게임 종료
        if (result.gameOver) {
          await finishMathraceGame(io, room);
        }
      }

      // 방향 맞추기 게임 로직
      if (room.gameType === 'arrowdash' && room.game instanceof ArrowDashGame) {
        const arrowIndex = data.action.arrowIndex as number;
        const direction = data.action.direction as string;
        const result = room.game.checkDirection(playerIndex, arrowIndex, direction);

        io.to(data.roomId).emit('arrowdash_answer', {
          playerId: socket.id,
          playerIndex,
          arrowIndex,
          correct: result.correct,
          progress: result.progress,
        });

        // 30개 완성 시 게임 종료
        if (result.gameOver) {
          await finishArrowdashGame(io, room);
        }
      }

      // 타이밍 맞추기 게임 로직
      if (room.gameType === 'timing' && room.game instanceof TimingGame) {
        if (data.action.type === 'stop' && !room.game.isGameOver()) {
          const position = Number(data.action.position);
          if (isNaN(position)) return;
          const result = room.game.playerStop(playerIndex, position);

          if (!result.valid) {
            return;
          }

          // 상대에게 내가 멈췄다고 알림
          io.to(data.roomId).emit('timing_player_stopped', {
            playerIndex,
          });

          console.log(`⏱️ Player ${playerIndex} stopped at ${position.toFixed(3)}`);

          // 둘 다 멈추면 결과 계산
          if (result.bothDone) {
            clearRoundTimer(room);

            const roundResult = room.game.calculateRoundResult();

            io.to(data.roomId).emit('timing_round_result', {
              round: room.game.getCurrentRound(),
              positions: roundResult.positions,
              roundScores: roundResult.roundScores,
              totalScores: roundResult.totalScores,
            });

            if (roundResult.gameOver) {
              await finishTimingGame(io, room);
            } else {
              scheduleRoundStart(room, 2000, () => startTimingRound(io, room));
            }
          }
        }
      }

      // 카드 뒤집기 게임 로직
      if (room.gameType === 'cardflip' && room.game instanceof CardFlipGame) {
        const position = data.action.position as number;
        const result = room.game.flipCard(playerIndex, position);

        if (result.valid) {
          // 카드 1장 공개
          io.to(data.roomId).emit('cardflip_flip', {
            playerIndex,
            position,
            symbol: result.symbol,
          });

          if (result.isSecondFlip) {
            // checkMatch가 flippedCards를 비우므로, 미리 저장
            const flippedBeforeCheck = room.game.getFlippedCards();
            const matchResult = room.game.checkMatch();

            if (matchResult.matched) {
              // 짝 맞음 → 즉시 결과 전송
              clearRoundTimer(room);
              io.to(data.roomId).emit('cardflip_result', {
                matched: true,
                positions: flippedBeforeCheck,
                scores: room.game.getScores(),
                nextTurn: matchResult.nextTurn,
                matchedPositions: room.game.getMatched(),
              });

              if (matchResult.gameOver) {
                await finishCardFlipGame(io, room);
              } else {
                // 같은 플레이어 턴 → 타이머 재시작
                startCardFlipTurn(io, room);
              }
            } else {
              // 짝 안 맞음 → 1.5초 후 카드 원복 + 턴 전환
              clearRoundTimer(room);
              const flippedPositions = room.game.getFlippedCards();
              schedulePhaseTimer(room, CardFlipGame.FLIP_DELAY, () => {
                if (!(room.game instanceof CardFlipGame)) return;
                if (room.reconnectPaused || room.status !== 'playing') return;
                room.game.clearFlipped();
                io.to(data.roomId).emit('cardflip_result', {
                  matched: false,
                  positions: flippedPositions,
                  scores: room.game.getScores(),
                  nextTurn: room.game.getCurrentTurn(),
                  matchedPositions: room.game.getMatched(),
                });
                startCardFlipTurn(io, room);
              });
            }
          }
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
              room.sequencePhase = 'waiting';
              io.to(data.roomId).emit('sequence_round_complete', {
                success: true,
                nextLevel: room.game.getCurrentLevel() + 1,
              });
              scheduleRoundStart(room, 2000, () => startSequenceRound(io, room));
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
            scheduleRoundStart(room, 2000, () => startStroopRound(io, room));
          }
        }
      }

      // 헥사곤 게임 로직
      if (room.gameType === 'hexagon' && room.game instanceof HexagonGame) {
        const action = data.action;

        if (action.type === 'buzz') {
          // 버저 누르기
          const result = room.game.buzz(playerIndex);
          if (!result.valid) return;

          // 타이머 멈추고 10초 버저 타이머 시작
          if (room.idleTimer) { clearTimeout(room.idleTimer); room.idleTimer = undefined; }
          // 스킵 상태 초기화 (활동 발생)
          if (room.skipTimer) { clearTimeout(room.skipTimer); room.skipTimer = undefined; }
          room.skipVotes = undefined;
          startHexagonBuzzTimer(io, room);

          io.to(data.roomId).emit('hexagon_buzz', {
            playerIndex,
            playerId: socket.id,
            playerNickname: currentPlayer?.nickname,
          });
        } else if (action.type === 'answer') {
          // 답변 제출
          const cellIndices = action.cellIndices as number[];
          const result = room.game.submitAnswer(playerIndex, cellIndices);
          if (!result.valid) return;

          // 버저 타이머 정리
          if (room.buzzTimer) { clearTimeout(room.buzzTimer); room.buzzTimer = undefined; }

          io.to(data.roomId).emit('hexagon_answer_result', {
            playerIndex,
            playerId: socket.id,
            playerNickname: currentPlayer?.nickname,
            correct: result.correct,
            letters: result.letters,
            alreadyFound: result.alreadyFound,
            scores: result.scores,
            remainingCombinations: result.remainingCombinations,
            foundCombinations: room.game.getFoundCombinations(),
          });

          if (result.correct) {
            console.log(`🔷 ${currentPlayer?.nickname} found ${result.letters}!`);
          } else {
            console.log(`🔷 ${currentPlayer?.nickname} wrong answer: ${result.letters}`);
          }

          // 모든 조합을 찾았으면 라운드 종료
          if (result.remainingCombinations === 0) {
            finishHexagonRound(io, room);
          } else {
            // 60초 타이머 + 20초 스킵 타이머 재시작
            startHexagonIdleTimer(io, room);
          }
        }
      }

      // 수식피라미드 게임 로직
      if (room.gameType === 'pyramid' && room.game instanceof PyramidGame) {
        const action = data.action;

        if (action.type === 'buzz') {
          const result = room.game.buzz(playerIndex);
          if (!result.valid) return;

          if (room.idleTimer) { clearTimeout(room.idleTimer); room.idleTimer = undefined; }
          // 스킵 상태 초기화 (활동 발생)
          if (room.skipTimer) { clearTimeout(room.skipTimer); room.skipTimer = undefined; }
          room.skipVotes = undefined;
          startPyramidBuzzTimer(io, room);

          io.to(data.roomId).emit('pyramid_buzz', {
            playerIndex,
            playerId: socket.id,
            playerNickname: currentPlayer?.nickname,
          });
        } else if (action.type === 'answer') {
          const sequence = action.sequence as number[];
          const result = room.game.submitAnswer(playerIndex, sequence);
          if (!result.valid) return;

          if (room.buzzTimer) { clearTimeout(room.buzzTimer); room.buzzTimer = undefined; }

          io.to(data.roomId).emit('pyramid_answer_result', {
            playerIndex,
            playerId: socket.id,
            playerNickname: currentPlayer?.nickname,
            correct: result.correct,
            scores: result.scores,
            sequence,
            calculationSteps: result.calculationSteps,
          });

          if (result.correct) {
            console.log(`🔺 ${currentPlayer?.nickname} solved pyramid!`);
            // 정답이면 라운드 종료
            finishPyramidRound(io, room);
          } else {
            console.log(`🔺 ${currentPlayer?.nickname} wrong answer`);
            // 오답이면 60초 타이머 재시작
            startPyramidIdleTimer(io, room);
          }
        }
      }

      // 훈민정음 게임 로직
      if (room.gameType === 'hunmin' && room.game instanceof HunminGame) {
        const action = data.action;

        if (action.type === 'submit_word') {
          const word = (action.word as string || '').trim();
          const game = room.game;

          // 기본 검증 (턴/길이/초성/중복)
          const basicResult = game.submitWord(playerIndex, word);

          if (!basicResult.valid) {
            // 기본 검증 실패 → 즉시 라운드 패배
            const reason = basicResult.reason!;

            if (reason === 'not_your_turn' || reason === 'round_not_playing') {
              socket.emit('error', { message: reason });
              return;
            }

            // 초성 불일치, 중복 단어, 길이 오류 등 → 패배
            socket.emit('hunmin_word_rejected', {
              word,
              playerIndex,
              reason,
            });

            clearHunminTimers(room);
            const elimResult = game.eliminate(playerIndex, reason);
            handleHunminElimination(io, room, elimResult, reason, word);
            return;
          }

          // 사전 검증
          const dictResult = await dictionaryService.isValidWord(word);

          if (!dictResult.valid) {
            // 사전에 없는 단어 → 탈락
            io.to(data.roomId).emit('hunmin_word_rejected', {
              word,
              playerIndex,
              reason: 'not_in_dictionary',
            });

            clearHunminTimers(room);
            const elimResult = game.eliminate(playerIndex, 'not_in_dictionary');
            handleHunminElimination(io, room, elimResult, 'not_in_dictionary', word);
            return;
          }

          // 단어 확정
          const confirmResult = game.confirmWordValid(playerIndex, word);

          io.to(data.roomId).emit('hunmin_word_accepted', {
            word,
            playerIndex,
            usedWords: confirmResult.usedWords,
            nextPlayer: confirmResult.nextPlayer,
          });

          console.log(`📝 ${currentPlayer?.nickname} submitted: ${word} (source: ${dictResult.source})`);

          // 다음 턴 타이머 시작
          startHunminTurnTimer(io, room);
        }
      }
      } catch (err) {
        console.error('[game_action] unhandled error:', err, 'roomId:', data?.roomId, 'action:', data?.action);
        try {
          socket.emit('error', { message: '게임 처리 중 오류가 발생했습니다' });
        } catch {
          // socket이 이미 닫혔으면 무시
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
        socket.emit('remove_friend_result', { success: false, message: '로그인이 필요합니다.', friendId: data.friendId });
        return;
      }

      try {
        const result = await friendService.removeFriend(currentPlayer.userId, data.friendId);
        socket.emit('remove_friend_result', { ...result, friendId: data.friendId });
      } catch (error) {
        socket.emit('remove_friend_result', { success: false, message: '친구 삭제 실패', friendId: data.friendId });
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
        // 상대방이 온라인인지 확인
        const friendSocket = userSockets.get(data.friendId);
        if (!friendSocket) {
          socket.emit('invite_result', { success: false, message: '상대방이 오프라인입니다.' });
          return;
        }

        // 상대방이 게임 중인지 확인
        const friendRoomId = userRooms.get(data.friendId);
        if (friendRoomId) {
          const friendRoom = rooms.get(friendRoomId);
          if (friendRoom && (friendRoom.status === 'playing' || friendRoom.status === 'waiting')) {
            socket.emit('invite_result', { success: false, message: '상대방이 게임 중입니다.', reason: 'busy' });
            return;
          }
        }

        const invitation = await invitationService.createInvitation(
          currentPlayer.userId,
          data.friendId,
          data.gameType,
          data.isHardcore
        );

        // 중복 초대 차단됨
        if (!invitation) {
          socket.emit('invite_result', { success: false, message: '이미 초대를 보냈습니다.' });
          return;
        }

        socket.emit('invite_result', { success: true, invitation });

        // 상대방에게 초대 알림
        friendSocket.emit('game_invitation', { invitation });

        // 초대 타임아웃 설정 (30초)
        // async setTimeout 콜백에서 발생한 에러가 unhandledRejection으로 새어나가
        // 프로세스를 죽이지 않도록 try/catch로 감싼다.
        const timeoutId = setTimeout(async () => {
          try {
            // 초대가 아직 pending 상태인지 확인
            const currentInvitation = await invitationService.getInvitation(invitation.id);
            if (currentInvitation && currentInvitation.status === 'pending') {
              // 초대 만료 처리
              await invitationService.expireInvitation(invitation.id);

              // 초대자에게 만료 알림
              socket.emit('invitation_expired', {
                invitationId: invitation.id,
                friendNickname: currentInvitation.inviteeNickname,
                message: '초대가 만료되었습니다.'
              });

              // 피초대자에게도 알림 (초대 목록에서 제거)
              const inviteeSocket = userSockets.get(data.friendId);
              if (inviteeSocket) {
                inviteeSocket.emit('invitation_expired', {
                  invitationId: invitation.id,
                  message: '초대가 만료되었습니다.'
                });
              }
            }
          } catch (err) {
            console.error('[invitation timeout] failed to expire invitation:', err);
          } finally {
            invitationTimeouts.delete(invitation.id);
          }
        }, INVITATION_TIMEOUT_MS);

        invitationTimeouts.set(invitation.id, {
          timeout: timeoutId,
          inviterId: currentPlayer.userId,
          inviteeId: data.friendId,
        });
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
        socket.emit('accept_invitation_result', {
          success: false,
          message: '로그인이 필요합니다.',
          invitationId: data.invitationId,
        });
        return;
      }

      try {
        const invitation = await invitationService.getInvitation(data.invitationId);
        if (!invitation) {
          socket.emit('accept_invitation_result', {
            success: false,
            message: '초대를 찾을 수 없습니다.',
            invitationId: data.invitationId,
          });
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
          socket.emit('accept_invitation_result', {
            success: false,
            message: '초대한 사람이 오프라인입니다.',
            invitationId: data.invitationId,
          });
          return;
        }

        // 게임방 생성
        const isHardcore = invitation.isHardcore || false;
        const roomId = `${invitation.gameType}_${isHardcore ? 'hc_' : ''}invite_${Date.now()}`;
        const result = await invitationService.acceptInvitation(data.invitationId, roomId);

        if (!result.success) {
          socket.emit('accept_invitation_result', {
            ...result,
            invitationId: data.invitationId,
          });
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
        } else if (invitation.gameType === 'numberbattle') {
          room.game = new NumberBattleGame();
        } else if (invitation.gameType === 'set') {
          room.game = new SetGame();
        } else if (invitation.gameType === 'mathrace') {
          room.game = new MathRaceGame();
        } else if (invitation.gameType === 'arrowdash') {
          room.game = new ArrowDashGame();
        } else if (invitation.gameType === 'timing') {
          room.game = new TimingGame();
        } else if (invitation.gameType === 'cardflip') {
          room.game = new CardFlipGame();
        } else if (invitation.gameType === 'sequence') {
          room.game = new SequenceGame(isHardcore);
        } else if (invitation.gameType === 'stroop') {
          room.game = new StroopGame(isHardcore);
        } else if (invitation.gameType === 'hexagon') {
          room.game = new HexagonGame(false);
        } else if (invitation.gameType === 'pyramid') {
          room.game = new PyramidGame();
        } else if (invitation.gameType === 'hunmin') {
          room.game = new HunminGame();
        }

        rooms.set(roomId, room);

        // 방 참가
        inviterSocket!.join(roomId);
        socket.join(roomId);
        currentRoomId = roomId;

        // 유저별 현재 게임 룸 기록
        if (currentPlayer.userId) userRooms.set(currentPlayer.userId, roomId);
        if (invitation.inviterId) userRooms.set(invitation.inviterId, roomId);

        // 초대 타임아웃 정리
        const pendingInvite = invitationTimeouts.get(data.invitationId);
        if (pendingInvite) {
          clearTimeout(pendingInvite.timeout);
          invitationTimeouts.delete(data.invitationId);
        }

        room.status = 'playing';

        const players = [
          { id: inviterPlayer.id, nickname: inviterPlayer.nickname, userId: inviterPlayer.userId, avatarUrl: inviterPlayer.avatarUrl },
          { id: currentPlayer.id, nickname: currentPlayer.nickname, userId: currentPlayer.userId, avatarUrl: currentPlayer.avatarUrl }
        ];

        if (invitation.gameType === 'reaction') {
          // 반응속도 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'reaction',
            });

            scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
          }, 500);
        } else if (invitation.gameType === 'rps') {
          // 가위바위보 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'rps',
            });

            scheduleRoundStart(room, 1000, () => startRpsRound(io, room));
          }, 500);
        } else if (invitation.gameType === 'speedtap') {
          // 스피드탭 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'speedtap',
            });

            scheduleRoundStart(room, 1000, () => startSpeedTapRound(io, room));
          }, 500);
        } else if (invitation.gameType === 'numberbattle') {
          // 숫자배틀 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'numberbattle',
            });

            scheduleRoundStart(room, 1000, () => startNumberBattle(io, room));
          }, 500);
        } else if (invitation.gameType === 'set') {
          // Set 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'set',
            });

            scheduleRoundStart(room, 1000, () => startSet(io, room));
          }, 500);
        } else if (invitation.gameType === 'mathrace') {
          // 사칙연산 스피드 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'mathrace',
            });

            scheduleRoundStart(room, 1000, () => startMathrace(io, room));
          }, 500);
        } else if (invitation.gameType === 'arrowdash') {
          // 방향 맞추기 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'arrowdash',
            });

            scheduleRoundStart(room, 1000, () => startArrowdash(io, room));
          }, 500);
        } else if (invitation.gameType === 'timing') {
          // 타이밍 맞추기 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'timing',
            });

            scheduleRoundStart(room, 1000, () => startTimingRound(io, room));
          }, 500);
        } else if (invitation.gameType === 'cardflip') {
          // 카드 뒤집기 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'cardflip',
            });

            scheduleRoundStart(room, 1000, () => startCardFlip(io, room));
          }, 500);
        } else if (invitation.gameType === 'sequence') {
          // 순서 기억하기 게임
          const seqGame = room.game as SequenceGame;
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
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
            scheduleExistingSequencePhase(io, room);
          }, 500);
        } else if (invitation.gameType === 'stroop') {
          // 스트룹 게임
          const stroopGame = room.game as StroopGame;
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
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

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
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

            scheduleRoundStart(room, 1000, () => startStroopRound(io, room));
          }, 500);
        } else if (invitation.gameType === 'hexagon') {
          // 헥사곤 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
            roomId,
            gameType: invitation.gameType,
            gameState: { players, isInvitation: true }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: { players, isInvitation: true }
          });

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'hexagon',
              isSolo: false,
            });

            setTimeout(() => startHexagonRound(io, room), 1000);
          }, 500);
        } else if (invitation.gameType === 'pyramid') {
          // 수식피라미드 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
            roomId,
            gameType: invitation.gameType,
            gameState: { players, isInvitation: true }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: { players, isInvitation: true }
          });

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'pyramid',
            });

            setTimeout(() => startPyramidRound(io, room), 1000);
          }, 500);
        } else if (invitation.gameType === 'hunmin') {
          // 훈민정음 게임
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
            roomId,
            gameType: invitation.gameType,
            gameState: { players, isInvitation: true }
          });

          inviterSocket!.emit('invitation_accepted', {
            roomId,
            gameType: invitation.gameType,
            acceptedBy: currentPlayer.nickname,
            gameState: { players, isInvitation: true }
          });

          setTimeout(() => {
            io.to(roomId).emit('match_found', {
              roomId,
              gameType: invitation.gameType,
              isInvitation: true,
              players
            });

            io.to(roomId).emit('game_start', {
              gameType: 'hunmin',
            });

            setTimeout(() => startHunminRound(io, room), 1000);
          }, 500);
        } else {
          // 턴제 게임
          const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
          const gameBoard = turnGame?.getBoard();
          const currentTurn = inviterPlayer.id;

          // 초대 받은 사람에게 게임 상태 포함해서 전송
          socket.emit('accept_invitation_result', {
            success: true,
            invitationId: data.invitationId,
            roomId,
            gameType: invitation.gameType,
            // 게임 상태 포함
            gameState: {
              players,
              currentTurn,
              board: gameBoard,
              isInvitation: true,
              turnTimeLimit: getTurnTimeLimit(room),
              turnStartTime: null,
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
              turnStartTime: null,
            }
          });

          // 클라이언트가 게임 화면으로 이동하고 소켓 리스너를 설정할 시간을 줌
          setTimeout(() => {
            // 턴 타이머는 match_found/game_start 전송 직전에 시작
            startTurnTimer(io, room);
            const turnStartTime = room.turnStartTime;

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

            console.log(`🎮 Invitation game started: ${inviterPlayer.nickname} vs ${currentPlayer?.nickname}`);
          }, 500);
        }
      } catch (error) {
        socket.emit('accept_invitation_result', {
          success: false,
          message: '초대 수락 실패',
          invitationId: data.invitationId,
        });
      }
    });

    // 초대 거절
    socket.on('decline_invitation', async (data: { invitationId: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('decline_invitation_result', {
          success: false,
          message: '로그인이 필요합니다.',
          invitationId: data.invitationId,
        });
        return;
      }

      try {
        const invitation = await invitationService.getInvitation(data.invitationId);
        const result = await invitationService.declineInvitation(data.invitationId);
        socket.emit('decline_invitation_result', {
          ...result,
          invitationId: data.invitationId,
        });

        // 초대 타임아웃 정리
        const pendingInvite = invitationTimeouts.get(data.invitationId);
        if (pendingInvite) {
          clearTimeout(pendingInvite.timeout);
          invitationTimeouts.delete(data.invitationId);
        }

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
        socket.emit('decline_invitation_result', {
          success: false,
          message: '초대 거절 실패',
          invitationId: data.invitationId,
        });
      }
    });

    // ====== 랭크 시스템 ======

    // 랭크 매칭 찾기
    socket.on('find_ranked_match', async () => {
      console.log(`🎮 [find_ranked_match] Called by socket ${socket.id}, currentPlayer:`, currentPlayer?.nickname, 'userId:', currentPlayer?.userId);

      if (!currentPlayer?.userId) {
        console.log(`❌ [find_ranked_match] No userId for socket ${socket.id}`);
        socket.emit('error', { message: '로그인이 필요합니다.' });
        return;
      }

      // 이미 대기열에 있는지 확인
      const existingIndex = rankedQueue.findIndex(p => p.id === socket.id);
      if (existingIndex !== -1) {
        console.log(`⚠️ [find_ranked_match] ${currentPlayer.nickname} already in queue`);
        socket.emit('waiting_for_ranked_match', { message: '이미 매칭 대기 중입니다.' });
        return;
      }

      // 랭크 통계 조회
      console.log(`📊 [find_ranked_match] Getting stats for userId ${currentPlayer.userId}`);
      const stats = await rankedService.getRankedStats(currentPlayer.userId);
      console.log(`📊 [find_ranked_match] Stats:`, stats);

      // 대기열에 추가
      const queuePlayer: RankedQueuePlayer = {
        ...currentPlayer,
        elo: stats.elo,
        joinedAt: Date.now(),
      };
      rankedQueue.push(queuePlayer);

      socket.emit('waiting_for_ranked_match', {
        elo: stats.elo,
        tier: stats.tier,
      });
      console.log(`⏳ ${currentPlayer.nickname} (ELO: ${stats.elo}) waiting for ranked match`);

      // 매칭 시도
      tryRankedMatch(io, queuePlayer);
    });

    // 랭크 매칭 취소
    socket.on('cancel_ranked_match', () => {
      const index = rankedQueue.findIndex(p => p.id === socket.id);
      if (index !== -1) {
        rankedQueue.splice(index, 1);
        socket.emit('ranked_match_cancelled');
        console.log(`❌ ${currentPlayer?.nickname} cancelled ranked match`);
      }
    });

    // 랭크 통계 조회
    socket.on('get_ranked_stats', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('ranked_stats', { stats: null });
        return;
      }

      try {
        const stats = await rankedService.getRankedStats(currentPlayer.userId);
        socket.emit('ranked_stats', { stats });
      } catch (error) {
        socket.emit('ranked_stats', { stats: null });
      }
    });

    // 리더보드 조회
    socket.on('get_leaderboard', async (data?: { limit?: number; offset?: number }) => {
      console.log('📊 get_leaderboard requested');
      try {
        const leaderboard = await rankedService.getLeaderboard(
          data?.limit || 100,
          data?.offset || 0
        );
        console.log(`📊 Leaderboard: ${leaderboard.length} entries`);
        socket.emit('leaderboard', { leaderboard });
      } catch (error) {
        console.error('📊 Leaderboard error:', error);
        socket.emit('leaderboard', { leaderboard: [] });
      }
    });

    // 내 순위 조회
    socket.on('get_my_rank', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('my_rank', { rank: null });
        return;
      }

      try {
        const rank = await rankedService.getUserRank(currentPlayer.userId);
        socket.emit('my_rank', { rank });
      } catch (error) {
        socket.emit('my_rank', { rank: null });
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

    // 광고 설정 조회 헬퍼
    async function getAdConfig(): Promise<{ rewardCoins: number; dailyLimit: number; enabled: boolean }> {
      const pool = getPool();
      if (!pool) return { rewardCoins: 50, dailyLimit: 7, enabled: true };
      try {
        const result = await pool.query('SELECT config_key, config_value FROM dm_ad_config');
        const config: Record<string, string> = {};
        result.rows.forEach((r: any) => { config[r.config_key] = r.config_value; });
        return {
          rewardCoins: parseInt(config['reward_coins']) || 50,
          dailyLimit: parseInt(config['reward_daily_limit']) || 7,
          enabled: config['reward_enabled'] !== 'false',
        };
      } catch {
        return { rewardCoins: 50, dailyLimit: 7, enabled: true };
      }
    }

    // 오늘 광고 시청 횟수 조회 헬퍼
    async function getTodayAdCount(userId: number): Promise<number> {
      const pool = getPool();
      if (!pool) return 0;
      try {
        const result = await pool.query(
          "SELECT COUNT(*) FROM dm_mileage_history WHERE user_id = $1 AND reason = 'ad_reward' AND created_at >= CURRENT_DATE",
          [userId]
        );
        return parseInt(result.rows[0].count) || 0;
      } catch {
        return 0;
      }
    }

    // 광고 상태 조회
    socket.on('get_ad_status', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('ad_status', { remaining: 0, dailyLimit: 7, rewardCoins: 50, enabled: false });
        return;
      }

      try {
        const config = await getAdConfig();
        const todayCount = await getTodayAdCount(currentPlayer.userId);
        socket.emit('ad_status', {
          remaining: Math.max(0, config.dailyLimit - todayCount),
          dailyLimit: config.dailyLimit,
          rewardCoins: config.rewardCoins,
          enabled: config.enabled,
        });
      } catch {
        socket.emit('ad_status', { remaining: 0, dailyLimit: 7, rewardCoins: 50, enabled: false });
      }
    });

    // 광고 시청 마일리지 지급
    socket.on('claim_ad_reward', async () => {
      if (!currentPlayer?.userId) {
        socket.emit('ad_reward_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const config = await getAdConfig();

        if (!config.enabled) {
          socket.emit('ad_reward_result', { success: false, message: '광고 보상이 비활성화되어 있습니다.' });
          return;
        }

        const todayCount = await getTodayAdCount(currentPlayer.userId);
        if (todayCount >= config.dailyLimit) {
          socket.emit('ad_reward_result', {
            success: false,
            message: `오늘의 광고 시청 횟수를 모두 사용했습니다. (${config.dailyLimit}/${config.dailyLimit})`,
            remaining: 0,
          });
          return;
        }

        const mileage = await statsService.addMileage(currentPlayer.userId, config.rewardCoins, 'ad_reward');
        const remaining = config.dailyLimit - todayCount - 1;
        socket.emit('ad_reward_result', {
          success: true,
          mileage,
          message: `${config.rewardCoins} 코인이 지급되었습니다!`,
          remaining,
        });
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
      const participantIndex = room
        ? room.players.findIndex((player) =>
            player.id === socket.id ||
            (!!currentPlayer?.userId && player.userId === currentPlayer.userId))
        : -1;
      const participant = participantIndex !== -1 && room
        ? room.players[participantIndex]
        : null;

      // 게임 종료 화면에서 잠깐 재연결된 경우 userId 기준으로 현재 소켓을 다시 연결한다.
      if (room && participant) {
        participant.id = socket.id;
        participant.socket = socket;
        participant.nickname = currentPlayer?.nickname ?? participant.nickname;
        participant.avatarUrl = currentPlayer?.avatarUrl ?? participant.avatarUrl;
        socket.join(data.roomId);
        currentRoomId = data.roomId;
        currentPlayer = participant;
      }

      const isRoomParticipant = participant != null;
      const hasFullRoom = room?.players.length === 2;

      if (!room || !hasFullRoom || !isRoomParticipant) {
        socket.emit('rematch_waiting', {
          waiting: false,
        });
        socket.emit('opponent_left', {
          message: 'Opponent is no longer in the room',
        });
        return;
      }

      // 이미 재경기가 시작된 뒤 늦게 도착한 중복 요청은 무시한다.
      if (room.status !== 'finished') {
        socket.emit('rematch_waiting', {
          waiting: false,
        });
        return;
      }

      // 재경기 요청 목록 초기화
      if (!room.rematchRequests) {
        room.rematchRequests = new Set();
      }

      const rematchRequesterKey = participant.userId != null
        ? `user:${participant.userId}`
        : `socket:${participant.id}`;

      // 현재 플레이어 요청 추가
      room.rematchRequests.add(rematchRequesterKey);
      console.log(`🔄 Rematch requested by ${currentPlayer?.nickname} (${room.rematchRequests.size}/${room.players.length})`);

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
      if (room.rematchRequests.size >= room.players.length) {
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
        } else if (room.gameType === 'numberbattle') {
          room.game = new NumberBattleGame();
        } else if (room.gameType === 'set') {
          room.game = new SetGame(room.isInfinite === true);
        } else if (room.gameType === 'mathrace') {
          room.game = new MathRaceGame();
        } else if (room.gameType === 'arrowdash') {
          room.game = new ArrowDashGame();
        } else if (room.gameType === 'timing') {
          room.game = new TimingGame();
        } else if (room.gameType === 'cardflip') {
          room.game = new CardFlipGame();
        } else if (room.gameType === 'sequence') {
          room.game = new SequenceGame(room.isHardcore);
        } else if (room.gameType === 'stroop') {
          room.game = new StroopGame(room.isHardcore);
        } else if (room.gameType === 'hexagon') {
          room.game = new HexagonGame(false);
        } else if (room.gameType === 'pyramid') {
          // 수식피라미드 재대결 시 게임 인스턴스를 새로 만들지 않으면
          // 이전 게임의 점수/라운드 카운터가 그대로 이어진다.
          room.game = new PyramidGame();
        } else if (room.gameType === 'hunmin') {
          room.game = new HunminGame();
        }
        room.status = 'playing';
        room.rematchRequests.clear();

        // 플레이어 순서 교체 (선공/후공 바꾸기)
        room.players.reverse();
        const rematchPlayers = room.players.map(p => ({
          id: p.id,
          nickname: p.nickname,
          userId: p.userId,
          avatarUrl: p.avatarUrl,
        }));

        if (room.gameType === 'reaction') {
          // 반응속도 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'reaction',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startReactionRound(io, room));
        } else if (room.gameType === 'rps') {
          // 가위바위보 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'rps',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startRpsRound(io, room));
        } else if (room.gameType === 'speedtap') {
          // 스피드탭 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'speedtap',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startSpeedTapRound(io, room));
        } else if (room.gameType === 'numberbattle') {
          // 숫자배틀 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'numberbattle',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startNumberBattle(io, room));
        } else if (room.gameType === 'set') {
          // Set 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'set',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startSet(io, room));
        } else if (room.gameType === 'mathrace') {
          // 사칙연산 스피드 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'mathrace',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startMathrace(io, room));
        } else if (room.gameType === 'arrowdash') {
          // 방향 맞추기 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'arrowdash',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startArrowdash(io, room));
        } else if (room.gameType === 'timing') {
          // 타이밍 맞추기 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'timing',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startTimingRound(io, room));
        } else if (room.gameType === 'cardflip') {
          // 카드 뒤집기 게임 ��대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'cardflip',
            players: rematchPlayers,
          });
          scheduleRoundStart(room, 1000, () => startCardFlip(io, room));
        } else if (room.gameType === 'sequence') {
          // 순서 기억하기 게임 재대결
          const seqGame = room.game as SequenceGame;
          io.to(data.roomId).emit('game_start', {
            gameType: 'sequence',
            players: rematchPlayers,
            gridSize: seqGame.getGridSize(),
            sequence: seqGame.getSequence(),
            level: seqGame.getCurrentLevel(),
            showDelay: seqGame.getShowDelay(),
            isHardcore: seqGame.getIsHardcore(),
            timeLimit: seqGame.getTimeLimit(),
          });
          scheduleExistingSequencePhase(io, room);
        } else if (room.gameType === 'stroop') {
          // 스트룹 게임 재대결
          const stroopGame = room.game as StroopGame;
          io.to(data.roomId).emit('game_start', {
            gameType: 'stroop',
            players: rematchPlayers,
            isHardcore: stroopGame.getIsHardcore(),
            colors: stroopGame.getColors(),
          });
          scheduleRoundStart(room, 1000, () => startStroopRound(io, room));
        } else if (room.gameType === 'hexagon') {
          // 헥사곤 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'hexagon',
            isSolo: false,
            players: rematchPlayers,
          });
          setTimeout(() => startHexagonRound(io, room), 1000);
        } else if (room.gameType === 'pyramid') {
          // 수식피라미드 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'pyramid',
            players: rematchPlayers,
          });
          setTimeout(() => startPyramidRound(io, room), 1000);
        } else if (room.gameType === 'hunmin') {
          // 훈민정음 게임 재대결
          io.to(data.roomId).emit('game_start', {
            gameType: 'hunmin',
            players: rematchPlayers,
          });
          setTimeout(() => startHunminRound(io, room), 1000);
        } else {
          // 턴제 게임
          startTurnTimer(io, room);
          const turnGame = room.game as TicTacToeGame | InfiniteTicTacToeGame | GomokuGame;
          io.to(data.roomId).emit('game_start', {
            currentTurn: room.players[0].id,
            board: turnGame?.getBoard(),
            turnTimeLimit: getTurnTimeLimit(room),
            turnStartTime: room.turnStartTime,
            players: room.players.map(p => ({ id: p.id, nickname: p.nickname })),
          });
        }
        console.log(`🎮 Rematch started: ${room.players[0].nickname} vs ${room.players[1].nickname}`);
      }
    });

    // 재대결 취소
    socket.on('rematch_cancel', (data: { roomId: string }) => {
      const room = rooms.get(data.roomId);
      if (room && room.rematchRequests) {
        const participant = room.players.find((player) =>
          player.id === socket.id ||
          (!!currentPlayer?.userId && player.userId === currentPlayer.userId));
        const rematchRequesterKey = participant?.userId != null
          ? `user:${participant.userId}`
          : `socket:${socket.id}`;
        room.rematchRequests.delete(rematchRequesterKey);
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

    // 패배 삭제권 사용
    socket.on('delete_loss', async (data: { gameType: string; count?: number; price?: number }) => {
      if (!currentPlayer?.userId) {
        socket.emit('delete_loss_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      const count = data.count || 1;
      const price = data.price || 50;

      try {
        const result = await shopService.deleteLoss(currentPlayer.userId, data.gameType, count, price);
        socket.emit('delete_loss_result', result);

        // 성공 시 코인 업데이트 이벤트 발송
        if (result.success && result.coins !== undefined) {
          socket.emit('coins_updated', {
            coins: result.coins,
            earned: -price,
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

    // 닉네임 변경권 사용
    socket.on('change_nickname', async (data: { nickname: string }) => {
      if (!currentPlayer?.userId) {
        socket.emit('change_nickname_result', { success: false, message: '로그인이 필요합니다.' });
        return;
      }

      try {
        const result = await shopService.changeNickname(currentPlayer.userId, data.nickname);
        socket.emit('change_nickname_result', result);

        // 성공 시 코인 업데이트 및 닉네임 변경
        if (result.success && result.coins !== undefined) {
          socket.emit('coins_updated', {
            coins: result.coins,
            earned: -100, // 차감된 코인
            streak: 0,
            streakBonus: false,
          });

          // 현재 플레이어 닉네임도 업데이트
          if (currentPlayer && result.nickname) {
            currentPlayer.nickname = result.nickname;
          }
        }
      } catch (error) {
        console.error('Change nickname error:', error);
        socket.emit('change_nickname_result', { success: false, message: '닉네임 변경 중 오류가 발생했습니다.' });
      }
    });

    // 연결 해제
    socket.on('disconnect', () => {
      console.log(`👋 Player disconnected: ${socket.id}`);

      // userSockets에서 제거
      if (currentPlayer?.userId) {
        userSockets.delete(currentPlayer.userId);
      }

      // 이 유저가 보낸/받은 pending 초대 타임아웃 정리 (메모리 누수 방지)
      if (currentPlayer?.userId) {
        const userId = currentPlayer.userId;
        for (const [inviteId, entry] of invitationTimeouts.entries()) {
          if (entry.inviterId === userId || entry.inviteeId === userId) {
            clearTimeout(entry.timeout);
            invitationTimeouts.delete(inviteId);
          }
        }
      }

      // 대기열에서 제거
      matchQueues.forEach((queue, gameType) => {
        const index = queue.findIndex(p => p.id === socket.id);
        if (index !== -1) {
          queue.splice(index, 1);
        }
      });

      // 랭크 대기열에서 제거
      const rankedIndex = rankedQueue.findIndex(p => p.id === socket.id);
      if (rankedIndex !== -1) {
        rankedQueue.splice(rankedIndex, 1);
      }

      // 진행 중인 게임에서 제거
      const userId = currentPlayer?.userId;
      const roomId = currentRoomId ?? (userId ? userRooms.get(userId) : null);

      if (roomId) {
        const room = rooms.get(roomId);
        // [SET 무한] 종료 합의 진행 중 누가 끊기면 요청 취소.
        if (room && room.endRequest && room.gameType === 'set') {
          cancelSetEndRequest(io, room, currentPlayer?.nickname ?? '상대');
        }
        // [SET·훈민정음 3·4인] 게임 중 끊김 → 게임은 멈추지 않고 계속 진행(2인처럼 일시정지하지 않음).
        // 인증 유저는 유예시간 안에 돌아오면 진행 중인 게임에 합류(rejoin), 못 돌아오면 영구 이탈.
        // 게스트는 재접속 추적이 불가하므로 바로 이탈 처리.
        if (room && room.status === 'playing' &&
            (room.gameType === 'set' || room.gameType === 'hunmin') && room.players.length > 2) {
          const multiLeave = (r: GameRoom, sid: string) =>
            r.gameType === 'hunmin' ? handleHunminMultiLeave(io, r, sid) : handleSetMultiLeave(io, r, sid);
          if (userId) {
            const graceRoomId = roomId;
            const leftSocketId = socket.id;
            console.log(`⏳ ${room.gameType.toUpperCase()} ${room.players.length}인: user ${userId} 일시 끊김 — ${RECONNECT_GRACE_MS / 1000}s 유예(게임 계속)`);
            disconnectGraceTimers.set(userId, setTimeout(() => {
              try {
                disconnectGraceTimers.delete(userId);
                disconnectContexts.delete(userId);
                expiredReconnectUsers.add(userId);
                setTimeout(() => expiredReconnectUsers.delete(userId), 60000);
                const r = rooms.get(graceRoomId);
                if (r) {
                  void multiLeave(r, leftSocketId).catch(err =>
                    console.error('[multi leave]', err));
                }
              } catch (err) {
                console.error('[grace timer]', err);
              }
            }, RECONNECT_GRACE_MS));
            disconnectContexts.set(userId, { socket, roomId });
          } else {
            void multiLeave(room, socket.id).catch(err =>
              console.error('[multi leave]', err));
          }
          return;
        }
        // 게임 중 + userId 있음 + 솔로 아님 → 재연결 유예 (20초)
        if (userId && room && room.status === 'playing' && !room.isSolo) {
          pauseRoomForReconnect(room);
          socket.to(roomId).emit('opponent_disconnected', {
            graceMs: RECONNECT_GRACE_MS,
          });
          console.log(`⏳ Grace period started for user ${userId} in room ${roomId} (${RECONNECT_GRACE_MS / 1000}s)`);
          disconnectGraceTimers.set(userId, setTimeout(() => {
            try {
              console.log(`⏰ Grace period expired for user ${userId}, leaving room ${roomId}`);
              disconnectGraceTimers.delete(userId);
              disconnectContexts.delete(userId);
              expiredReconnectUsers.add(userId);
              setTimeout(() => expiredReconnectUsers.delete(userId), 60000);
              leaveRoom(socket, roomId);
            } catch (err) {
              console.error('[grace timer] cleanup error:', err);
            }
          }, RECONNECT_GRACE_MS));
          disconnectContexts.set(userId, { socket, roomId });
          return; // 즉시 leaveRoom 호출 안 함
        }

        leaveRoom(socket, roomId);
      }
    });

    async function leaveRoom(socket: Socket, roomId: string) {
      const room = rooms.get(roomId);
      if (room) {
        // [SET 무한] 종료 합의 진행 중 누가 나가면 요청 취소.
        if (room.endRequest && room.gameType === 'set') {
          const leaver = room.players.find(p => p.id === socket.id);
          cancelSetEndRequest(io, room, leaver?.nickname ?? '상대');
        }
        // [SET·훈민정음 3·4인] 게임 중 한 명 나감 → 게임은 계속. 이탈 처리만 하고 종료.
        if (room.status === 'playing' &&
            (room.gameType === 'set' || room.gameType === 'hunmin') && room.players.length > 2) {
          if (room.gameType === 'hunmin') await handleHunminMultiLeave(io, room, socket.id);
          else await handleSetMultiLeave(io, room, socket.id);
          try { socket.leave(roomId); } catch (_) {}
          return;
        }

        const hadPendingRematch = !!room.rematchRequests?.size;

        // 타이머 정리
        clearTurnTimer(room);
        clearHexagonTimers(room);
        clearPyramidTimers(room);
        clearHunminTimers(room);
        clearRoundTimer(room);
        clearPhaseTimer(room);
        room.reconnectPaused = false;
        room.pendingRoundStart = false;
        room.speedtapPhase = undefined;
        room.sequencePhase = undefined;
        room.pausedRoundRemainingMs = undefined;
        room.pausedPhaseRemainingMs = undefined;
        let handledRankedForfeit = false;

        // 랭크전 매칭 직후 (게임 시작 전) 퇴장 처리
        if (room.isRanked && room.status === 'waiting') {
          const leavingPlayer = room.players.find(p => p.id === socket.id);
          const remainingPlayer = room.players.find(p => p.id !== socket.id);

          if (leavingPlayer && remainingPlayer && leavingPlayer.userId && remainingPlayer.userId) {
            room.status = 'finished';
            try {
              console.log(`🚪 [Ranked] Player quit before game start: ${leavingPlayer.nickname} left, ${remainingPlayer.nickname} wins by forfeit`);

              const result = await rankedService.updateRankedResult(
                remainingPlayer.userId,
                leavingPlayer.userId,
                []
              );

              socket.to(room.id).emit('opponent_left', {
                message: 'Opponent has left before game start',
                isForfeit: true,
              });

              io.to(room.id).emit('ranked_match_end', {
                winnerId: remainingPlayer.userId,
                winnerNickname: remainingPlayer.nickname,
                loserId: leavingPlayer.userId,
                loserNickname: leavingPlayer.nickname,
                results: [],
                winnerStats: result.winnerStats,
                loserStats: result.loserStats,
                winnerEloChange: result.winnerEloChange,
                loserEloChange: result.loserEloChange,
                isForfeit: true,
              });

              console.log(`🏆 [Ranked] ${remainingPlayer.nickname} wins by forfeit before game start! (+${result.winnerEloChange} ELO)`);
              handledRankedForfeit = true;
            } catch (err) {
              console.error('Failed to record ranked forfeit before game start:', err);
            }
          }
        }

        // 게임 중이었다면 탈주 처리 (전적 기록, 경험치 없음)
        if (room.status === 'playing') {
          const leavingPlayer = room.players.find(p => p.id === socket.id);
          const remainingPlayer = room.players.find(p => p.id !== socket.id);

          if (leavingPlayer && remainingPlayer) {
            // 먼저 상태를 finished로 변경 (두 번째 나가는 사람이 중복 기록 안 되게)
            room.status = 'finished';
            clearRoundTimer(room);

            try {
              // 랭크전인 경우 특별 처리
              if (room.isRanked && leavingPlayer.userId && remainingPlayer.userId) {
                console.log(`🚪 [Ranked] Player quit: ${leavingPlayer.nickname} left, ${remainingPlayer.nickname} wins by forfeit`);

                // 탈주자는 패배, 남은 플레이어는 승리로 ELO 업데이트
                const result = await rankedService.updateRankedResult(
                  remainingPlayer.userId,
                  leavingPlayer.userId,
                  room.rankedResults?.map(r => ({
                    gameType: r.gameType,
                    winnerId: r.winnerId!,
                  })) || []
                );

                // 게임 화면에 상대 퇴장 알림 (게임 화면 즉시 종료용)
                socket.to(room.id).emit('opponent_left', {
                  message: 'Opponent has left the ranked game',
                  isForfeit: true,
                });

                // 랭크 매치 종료 이벤트 전송 (남은 플레이어에게)
                io.to(room.id).emit('ranked_match_end', {
                  winnerId: remainingPlayer.userId,
                  winnerNickname: remainingPlayer.nickname,
                  loserId: leavingPlayer.userId,
                  loserNickname: leavingPlayer.nickname,
                  results: room.rankedResults || [],
                  winnerStats: result.winnerStats,
                  loserStats: result.loserStats,
                  winnerEloChange: result.winnerEloChange,
                  loserEloChange: result.loserEloChange,
                  isForfeit: true,
                });

                console.log(`🏆 [Ranked] ${remainingPlayer.nickname} wins by forfeit! (+${result.winnerEloChange} ELO)`);
                handledRankedForfeit = true;
              } else {
                // 일반 게임: 기존 로직
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
              }
            } catch (err) {
              console.error('Failed to record quit game:', err);
            }
          }
        }

        // 랭크전 다음 게임 대기 중 탈주 처리 (이미 forfeit 처리되지 않은 경우만)
        if (!handledRankedForfeit &&
            room.isRanked &&
            room.status === 'finished' &&
            room.rankedResults &&
            room.rankedResults.length < 3) {
          const leavingPlayer = room.players.find(p => p.id === socket.id);
          const remainingPlayer = room.players.find(p => p.id !== socket.id);

          if (leavingPlayer && remainingPlayer && leavingPlayer.userId && remainingPlayer.userId) {
            try {
              console.log(`🚪 [Ranked] Player quit during waiting: ${leavingPlayer.nickname} left, ${remainingPlayer.nickname} wins by forfeit`);

              const result = await rankedService.updateRankedResult(
                remainingPlayer.userId,
                leavingPlayer.userId,
                room.rankedResults?.map(r => ({
                  gameType: r.gameType,
                  winnerId: r.winnerId!,
                })) || []
              );

              // 게임 화면에 상대 퇴장 알림
              socket.to(room.id).emit('opponent_left', {
                message: 'Opponent has left during waiting',
                isForfeit: true,
              });

              io.to(room.id).emit('ranked_match_end', {
                winnerId: remainingPlayer.userId,
                winnerNickname: remainingPlayer.nickname,
                loserId: leavingPlayer.userId,
                loserNickname: leavingPlayer.nickname,
                results: room.rankedResults || [],
                winnerStats: result.winnerStats,
                loserStats: result.loserStats,
                winnerEloChange: result.winnerEloChange,
                loserEloChange: result.loserEloChange,
                isForfeit: true,
              });

              console.log(`🏆 [Ranked] ${remainingPlayer.nickname} wins by forfeit during waiting! (+${result.winnerEloChange} ELO)`);
              handledRankedForfeit = true;
            } catch (err) {
              console.error('Failed to record ranked forfeit during waiting:', err);
            }
          }
        }

        socket.leave(roomId);

        // 랭크전에서 다음 게임 대기 중이면 플레이어 제거 안 함
        // (다음 게임 시작 시 다시 join 할 것)
        const isRankedWaitingNextGame = !handledRankedForfeit &&
          room.isRanked &&
          room.status === 'finished' &&
          room.rankedResults &&
          room.rankedResults.length < 3 &&
          !room.rankedResults.some(() => {
            const p1Wins = room.rankedResults!.filter(r => r.winnerId === room.players[0]?.userId).length;
            const p2Wins = room.rankedResults!.filter(r => r.winnerId === room.players[1]?.userId).length;
            return p1Wins >= 2 || p2Wins >= 2;
          });

        if (handledRankedForfeit) {
          // 남은 플레이어도 방에서 제거하고 방 정리
          for (const player of room.players) {
            try {
              player.socket.leave(roomId);
            } catch (_) {}
          }
          room.players = [];
        }

        if (isRankedWaitingNextGame) {
          console.log(`🎮 [leaveRoom] Ranked game waiting for next game, keeping player in room`);
          // 소켓은 나가지만 플레이어 목록은 유지
        } else {
          if (hadPendingRematch) {
            room.rematchRequests?.clear();
            socket.to(roomId).emit('rematch_waiting', {
              waiting: false,
            });
            socket.to(roomId).emit('rematch_cancelled', {
              from: currentPlayer?.nickname,
            });
          }

          if (!handledRankedForfeit) {
            // 상대방에게 알림
            socket.to(roomId).emit('opponent_left', {
              message: 'Opponent has left the game',
            });
          }

          // 방 정리
          room.players = room.players.filter(p => p.id !== socket.id);
          if (room.players.length === 0) {
            rooms.delete(roomId);
          }
        }
      }

      // 유저 룸 매핑 정리
      if (currentPlayer?.userId) {
        userRooms.delete(currentPlayer.userId);
      }

      currentRoomId = null;
    }
  });
}
