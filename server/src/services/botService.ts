/**
 * 매칭 봇 서비스.
 *
 * 일반 매칭 대기열에서 N초 이상 상대가 없을 때, 봇 계정이 서버 자신의 소켓(loopback)으로
 * 접속해 실제 유저와 동일한 프로토콜(join_lobby → find_match → game_action)로 대전한다.
 * 게임 로직을 건드리지 않고 클라이언트 입장에서만 동작하는 것이 핵심이다.
 *
 * - 설정(on/off, 대기 시간, 실력, 동시 봇 수)은 dm_bot_settings 에 저장되고 관리자 대시보드에서 바꾼다.
 * - 봇 계정은 dm_users.is_bot = TRUE. 랭킹·통계 집계에서는 제외한다.
 * - 지원 게임은 SUPPORTED_GAMES 뿐이다. 그 외 게임은 봇이 투입되지 않는다.
 */
import { io as ioClient, Socket as ClientSocket } from 'socket.io-client';
import { getPool } from '../config/database';
import { generateToken } from '../utils/jwt';

export interface BotSettings {
  enabled: boolean;
  waitSeconds: number; // 대기열에서 이만큼 기다리면 봇 투입
  skill: number; // 0(허술) ~ 1(강함)
  maxConcurrent: number;
}

const DEFAULT_SETTINGS: BotSettings = { enabled: false, waitSeconds: 5, skill: 0.5, maxConcurrent: 10 };

/** 봇이 둘 수 있는 게임. 하드코어는 턴제 게임만 허용(규칙이 같고 제한시간만 짧다). */
const SUPPORTED_GAMES = [
  'tictactoe', 'gomoku', 'rps', 'reaction', 'speedtap', 'numberbattle', 'mathrace', 'arrowdash',
  'stroop', 'sequence', 'timing', 'cardflip', 'infinite_tictactoe',
];
const HARDCORE_OK = ['tictactoe', 'gomoku'];

const POOL_SIZE = 30;
const BOT_MAX_LIFETIME_MS = 15 * 60 * 1000;
const MATCH_WAIT_LIMIT_MS = 15 * 1000;

const NICK_A = ['하늘', '별빛', '구름', '초코', '딸기', '바람', '햇살', '달콤', '새벽', '노을', '민트', '봄날', '코코', '몽실', '푸른', '은하', '번개', '꼬마', '미소', '솜사탕'];
const NICK_B = ['토끼', '여우', '고양이', '펭귄', '곰돌', '다람쥐', '러버', '게이머', '마스터', '왕자', '공주', '탐험가', '요정', '드래곤', '호랑이', '판다', '수달', '고래', '비둘기', '햄찌'];

let settings: BotSettings = { ...DEFAULT_SETTINGS };
let settingsLoadedAt = 0;
const activeAccountIds = new Set<number>();
let activeBots = 0;
const stats = { spawned: 0, matched: 0, finished: 0, failed: 0 };

const rand = (a: number, b: number) => a + Math.random() * (b - a);
const randInt = (a: number, b: number) => Math.floor(rand(a, b + 1));
const pick = <T>(arr: T[]): T => arr[Math.floor(Math.random() * arr.length)];

export function isGameSupported(gameType: string, isHardcore: boolean, isInfinite: boolean): boolean {
  // 무한모드는 틱택토(무한 틱택토)만 지원한다. SET 등 다른 게임의 무한모드는 제외.
  if (isInfinite && gameType !== 'tictactoe' && gameType !== 'infinite_tictactoe') return false;
  if (!SUPPORTED_GAMES.includes(gameType)) return false;
  if (isHardcore && !HARDCORE_OK.includes(gameType)) return false;
  return true;
}

export async function getSettings(force = false): Promise<BotSettings> {
  if (!force && Date.now() - settingsLoadedAt < 10_000) return settings;
  const pool = getPool();
  if (!pool) return settings;
  try {
    const r = await pool.query('SELECT enabled, wait_seconds, skill, max_concurrent FROM dm_bot_settings WHERE id = 1');
    if (r.rows[0]) {
      settings = {
        enabled: !!r.rows[0].enabled,
        waitSeconds: Number(r.rows[0].wait_seconds),
        skill: Number(r.rows[0].skill),
        maxConcurrent: Number(r.rows[0].max_concurrent),
      };
    }
    settingsLoadedAt = Date.now();
  } catch (e) {
    console.error('[bot] settings load failed:', e);
  }
  return settings;
}

export async function updateSettings(patch: Partial<BotSettings>): Promise<BotSettings> {
  const pool = getPool();
  if (!pool) throw new Error('Database not connected');
  const cur = await getSettings(true);
  const next: BotSettings = {
    enabled: patch.enabled ?? cur.enabled,
    waitSeconds: Math.min(60, Math.max(3, Math.round(patch.waitSeconds ?? cur.waitSeconds))),
    skill: Math.min(1, Math.max(0, patch.skill ?? cur.skill)),
    maxConcurrent: Math.min(50, Math.max(1, Math.round(patch.maxConcurrent ?? cur.maxConcurrent))),
  };
  await pool.query(
    `INSERT INTO dm_bot_settings (id, enabled, wait_seconds, skill, max_concurrent, updated_at)
     VALUES (1, $1, $2, $3, $4, NOW())
     ON CONFLICT (id) DO UPDATE SET enabled = $1, wait_seconds = $2, skill = $3, max_concurrent = $4, updated_at = NOW()`,
    [next.enabled, next.waitSeconds, next.skill, next.maxConcurrent]
  );
  settings = next;
  settingsLoadedAt = Date.now();
  return next;
}

/** 현재 투입 중인 봇 계정인지(봇이 만든 대기열 항목에 또 봇을 붙이지 않기 위함). */
export function isActiveBotAccount(userId?: number): boolean {
  return userId !== undefined && activeAccountIds.has(userId);
}

export function getRuntimeStatus() {
  return { activeBots, supportedGames: SUPPORTED_GAMES, hardcoreGames: HARDCORE_OK, ...stats };
}

// ---------------------------------------------------------------- 계정 풀

async function acquireAccount(): Promise<{ id: number; nickname: string } | null> {
  const pool = getPool();
  if (!pool) return null;
  const rows = (await pool.query('SELECT id, nickname FROM dm_users WHERE is_bot = TRUE')).rows as { id: number; nickname: string }[];
  // 풀이 모자라면 새 봇 계정을 하나 만든다.
  if (rows.length < POOL_SIZE) {
    const used = new Set(rows.map(r => r.nickname));
    let nick = '';
    for (let i = 0; i < 30; i++) {
      nick = `${pick(NICK_A)}${pick(NICK_B)}${Math.random() < 0.5 ? randInt(1, 99) : ''}`;
      if (!used.has(nick)) break;
    }
    const ins = await pool.query(
      `INSERT INTO dm_users (provider, provider_id, nickname, is_bot)
       VALUES ('bot', $1, $2, TRUE) RETURNING id, nickname`,
      [`bot_${Date.now()}_${randInt(1000, 9999)}`, nick]
    );
    rows.push(ins.rows[0]);
  }
  const free = rows.filter(r => !activeAccountIds.has(r.id));
  return free.length ? pick(free) : null;
}

// ---------------------------------------------------------------- 투입

export interface FillRequest {
  gameType: string;
  isHardcore: boolean;
  isInfinite: boolean;
  /** 타이머 만료 시점에도 실제 유저가 아직 대기열에 있는지. */
  isStillWaiting: () => boolean;
}

/** find_match 에서 유저가 대기열에 들어갈 때 호출. 조건이 맞으면 N초 뒤 봇을 투입한다. */
export async function scheduleFill(req: FillRequest): Promise<void> {
  if (!isGameSupported(req.gameType, req.isHardcore, req.isInfinite)) return;
  const s = await getSettings();
  if (!s.enabled) return;
  // 대기 시간에 약간의 지터를 줘서 "정확히 N초에 상대가 나타나는" 부자연스러움을 줄인다.
  const delay = s.waitSeconds * 1000 + rand(0, 1500);
  setTimeout(async () => {
    try {
      if (!req.isStillWaiting()) return;
      const now = await getSettings(true); // 대기 중 관리자가 껐을 수 있다
      if (!now.enabled || activeBots >= now.maxConcurrent) return;
      await spawnBot(req.gameType, req.isHardcore, req.isInfinite, now.skill);
    } catch (e) {
      stats.failed++;
      console.error('[bot] fill failed:', e);
    }
  }, delay);
}

async function spawnBot(gameType: string, isHardcore: boolean, isInfinite: boolean, skill: number): Promise<void> {
  const account = await acquireAccount();
  if (!account) return;
  activeAccountIds.add(account.id);
  activeBots++;
  stats.spawned++;

  const port = process.env.PORT || 3000;
  const socket = ioClient(`http://127.0.0.1:${port}`, { transports: ['websocket'], reconnection: false });
  let done = false;
  const timers = new Set<NodeJS.Timeout>();
  const later = (fn: () => void, ms: number) => {
    const t = setTimeout(() => { timers.delete(t); if (!done) fn(); }, ms);
    timers.add(t);
  };
  const cleanup = () => {
    if (done) return;
    done = true;
    timers.forEach(clearTimeout);
    timers.clear();
    try { socket.disconnect(); } catch { /* noop */ }
    activeAccountIds.delete(account.id);
    activeBots = Math.max(0, activeBots - 1);
    stats.finished++;
  };

  later(cleanup, BOT_MAX_LIFETIME_MS);
  const matchTimer = setTimeout(cleanup, MATCH_WAIT_LIMIT_MS); // 매칭이 안 잡히면(유저가 취소) 철수
  timers.add(matchTimer);

  const ctx: BotContext = {
    socket, skill, gameType, roomId: '', myId: '', myIndex: 0,
    later, emitAction: (action) => socket.emit('game_action', { roomId: ctx.roomId, action }),
  };

  socket.on('connect', () => {
    ctx.myId = socket.id ?? '';
    socket.emit('join_lobby', { nickname: account.nickname, token: generateToken(account.id) });
  });
  socket.on('lobby_joined', () => {
    socket.emit('find_match', { gameType, isHardcore, isInfinite });
  });
  socket.on('auth_error', cleanup);
  socket.on('connect_error', () => { stats.failed++; cleanup(); });
  socket.on('disconnect', cleanup);

  socket.on('match_found', (d: { roomId: string; players: { id: string }[] }) => {
    clearTimeout(matchTimer);
    timers.delete(matchTimer);
    stats.matched++;
    ctx.roomId = d.roomId;
    ctx.myId = socket.id ?? ctx.myId;
    ctx.myIndex = d.players.findIndex(p => p.id === ctx.myId);
  });
  // 게임이 끝나면 결과 화면을 잠깐 보는 척하다 떠난다(재대결은 받지 않음).
  socket.on('game_end', () => later(cleanup, rand(3000, 7000)));
  // 상대(실제 유저)가 나가면 봇도 곧 떠난다. 연결 끊김은 재접속 유예(20초)를 기다렸다가 판단한다.
  let opponentGone = false;
  socket.on('opponent_left', () => later(cleanup, rand(1500, 3500)));
  socket.on('opponent_disconnected', () => {
    opponentGone = true;
    later(() => { if (opponentGone) cleanup(); }, 30_000);
  });
  socket.on('opponent_reconnected', () => { opponentGone = false; });

  const isInfiniteTtt = gameType === 'infinite_tictactoe' || (gameType === 'tictactoe' && isInfinite);
  const strategy = isInfiniteTtt ? STRATEGIES.infinite_tictactoe : STRATEGIES[gameType];
  if (strategy) strategy(ctx);
}

// ---------------------------------------------------------------- 게임별 전략

interface BotContext {
  socket: ClientSocket;
  skill: number;
  gameType: string;
  roomId: string;
  myId: string;
  myIndex: number;
  later: (fn: () => void, ms: number) => void;
  emitAction: (action: Record<string, unknown>) => void;
}

/** 실력이 낮을수록 길어지는 사람다운 반응 지연(ms). */
const human = (ctx: BotContext, min: number, max: number) => rand(min, max) * (1.4 - ctx.skill * 0.7);

const STRATEGIES: Record<string, (ctx: BotContext) => void> = {
  rps(ctx) {
    ctx.socket.on('rps_round_start', () => {
      ctx.later(() => ctx.emitAction({ choice: pick(['rock', 'paper', 'scissors']) }), human(ctx, 900, 3200));
    });
  },

  reaction(ctx) {
    let pressed = false;
    ctx.socket.on('reaction_round_ready', () => {
      pressed = false;
      // 가끔 성급하게 눌러 부정출발을 한다(실력이 낮을수록 자주).
      if (Math.random() < 0.06 * (1.2 - ctx.skill)) {
        ctx.later(() => { if (!pressed) { pressed = true; ctx.emitAction({}); } }, rand(500, 1500));
      }
    });
    ctx.socket.on('reaction_round_go', () => {
      ctx.later(() => { if (!pressed) { pressed = true; ctx.emitAction({}); } },
        rand(230, 420) + (1 - ctx.skill) * rand(60, 260));
    });
  },

  speedtap(ctx) {
    let running = false;
    ctx.socket.on('speedtap_round_start', (d: { duration?: number }) => {
      running = true;
      const end = Date.now() + (d.duration ?? 10000);
      // 초당 탭 수(사람 4~9회)
      const cps = 4 + ctx.skill * 5 + rand(-0.6, 0.6);
      const tick = () => {
        if (!running || Date.now() >= end) return;
        ctx.emitAction({});
        ctx.later(tick, (1000 / cps) * rand(0.7, 1.3));
      };
      ctx.later(tick, rand(100, 400));
    });
    ctx.socket.on('speedtap_round_result', () => { running = false; });
  },

  numberbattle(ctx) {
    ctx.socket.on('numberbattle_start', (d: { grid: number[][]; totalNumbers: number }) => {
      const pos = new Map<number, [number, number]>();
      d.grid.forEach((row, r) => row.forEach((n, c) => pos.set(n, [r, c])));
      let next = 1;
      const msPerTap = 950 - ctx.skill * 480;
      const tick = () => {
        if (next > d.totalNumbers) return;
        const p = pos.get(next);
        if (!p) return;
        // 사람처럼 가끔 헤매며 멈칫한다.
        const hesitate = Math.random() < 0.08 ? rand(500, 1400) : 0;
        ctx.emitAction({ row: p[0], col: p[1] });
        next++;
        ctx.later(tick, msPerTap * rand(0.7, 1.35) + hesitate);
      };
      ctx.later(tick, rand(900, 1800));
    });
  },

  mathrace(ctx) {
    ctx.socket.on('mathrace_start', (d: { problems: { num1: number; num2: number; operator: string }[] }) => {
      let i = 0;
      const solve = (p: { num1: number; num2: number; operator: string }) =>
        p.operator === '+' ? p.num1 + p.num2
          : p.operator === '-' ? p.num1 - p.num2
            : p.operator === '×' ? p.num1 * p.num2
              : p.num1 / p.num2;
      const tick = () => {
        if (i >= d.problems.length) return;
        const answer = solve(d.problems[i]);
        const miss = Math.random() < 0.12 * (1.2 - ctx.skill);
        ctx.emitAction({ problemIndex: i, answer: miss ? answer + pick([-10, -1, 1, 10]) : answer });
        if (!miss) i++;
        ctx.later(tick, miss ? rand(500, 1200) : human(ctx, 2200, 5200));
      };
      ctx.later(tick, human(ctx, 1500, 3000));
    });
  },

  arrowdash(ctx) {
    ctx.socket.on('arrowdash_start', (d: { arrows: { direction: string }[] }) => {
      let i = 0;
      const dirs = ['up', 'down', 'left', 'right'];
      const tick = () => {
        if (i >= d.arrows.length) return;
        const miss = Math.random() < 0.08 * (1.2 - ctx.skill);
        ctx.emitAction({ arrowIndex: i, direction: miss ? pick(dirs) : d.arrows[i].direction });
        // 오답이어도 index 가 맞고 방향만 틀리면 진행되지 않으므로 같은 화살표를 재시도한다.
        if (!miss) i++;
        ctx.later(tick, human(ctx, 380, 800));
      };
      ctx.later(tick, rand(900, 1600));
    });
  },

  stroop(ctx) {
    ctx.socket.on('stroop_show', (d: { color: string; colors?: string[] }) => {
      // 먼저 맞히면 점수, 틀리면 상대 점수 — 글자색을 읽는 사람다운 반응 속도.
      const miss = Math.random() < 0.12 * (1.2 - ctx.skill);
      const colors = d.colors ?? ['red', 'blue', 'green', 'yellow'];
      const wrong = pick(colors.filter(c => c !== d.color));
      ctx.later(() => ctx.emitAction({ selectedColor: miss ? wrong : d.color }), human(ctx, 900, 2300));
    });
  },

  sequence(ctx) {
    let level = -1;
    let sequence: number[] = [];
    let timeLimit = 10000;
    ctx.socket.on('sequence_show', (d: { sequence: number[]; level: number; timeLimit?: number }) => {
      sequence = d.sequence;
      level = d.level;
      timeLimit = d.timeLimit ?? 10000;
    });
    let startedLevel = -1;
    // 입력 단계가 시작되면(재접속 재전송 포함 레벨당 1회) 한 칸씩 누른다.
    ctx.socket.on('sequence_round_resumed', (d: { sequence?: number[]; level?: number; phase?: string }) => {
      const lv = d.level ?? level;
      const seq = d.sequence ?? sequence;
      if (d.phase && d.phase !== 'playing') return;
      if (startedLevel === lv || !seq.length) return;
      startedLevel = lv;
      // 레벨이 높을수록 실수 확률이 커진다. 실수하면 그 판은 탈락(상대와 비교).
      const failAt = Math.random() < Math.min(0.7, (0.03 + lv * 0.035) * (1.35 - ctx.skill))
        ? randInt(0, seq.length - 1) : -1;
      const gap = Math.min(human(ctx, 380, 800), (timeLimit * 0.6) / seq.length);
      let i = 0;
      const tick = () => {
        if (i >= seq.length) return;
        const expected = seq[i];
        const position = i === failAt
          ? pick([0, 1, 2, 3, 4, 5, 6, 7, 8].filter(x => x !== expected)) : expected;
        ctx.emitAction({ position });
        if (i === failAt) return;
        i++;
        ctx.later(tick, gap * rand(0.8, 1.25));
      };
      ctx.later(tick, rand(500, 1000));
    });
  },

  timing(ctx) {
    ctx.socket.on('timing_round_start', () => {
      // 막대는 클라이언트가 그리므로 서버는 멈춘 위치(0~1)만 받는다. 중앙(0.5)에서 실력만큼 벗어난다.
      const spread = 0.05 + (1 - ctx.skill) * 0.3;
      const position = Math.max(0, Math.min(1, 0.5 + (Math.random() + Math.random() - 1) * spread));
      ctx.later(() => ctx.emitAction({ type: 'stop', position }), rand(900, 3000));
    });
  },

  cardflip(ctx) {
    const known = new Map<number, string>(); // 위치 → 기억하는 심볼
    const matched = new Set<number>();
    let flips = 0;
    const memory = 0.55 + ctx.skill * 0.4; // 본 카드를 기억할 확률
    const free = () => Array.from({ length: 20 }, (_, i) => i).filter(i => !matched.has(i));

    const firstFlip = () => {
      const pos = free();
      // 짝을 아는 쌍이 있으면 먼저 그 쌍을 맞춘다.
      const bySymbol = new Map<string, number[]>();
      for (const i of pos) {
        const sym = known.get(i);
        if (sym) bySymbol.set(sym, [...(bySymbol.get(sym) ?? []), i]);
      }
      for (const arr of bySymbol.values()) if (arr.length >= 2) return arr[0];
      const unknown = pos.filter(i => !known.has(i));
      return pick(unknown.length ? unknown : pos);
    };
    const secondFlip = (firstPos: number) => {
      const sym = known.get(firstPos);
      const mate = sym ? free().find(i => i !== firstPos && known.get(i) === sym) : undefined;
      if (mate !== undefined) return mate;
      const rest = free().filter(i => i !== firstPos);
      const unknown = rest.filter(i => !known.has(i));
      return pick(unknown.length ? unknown : rest);
    };

    let firstPos = -1;
    ctx.socket.on('cardflip_turn', (d: { currentTurn: number }) => {
      flips = 0;
      firstPos = -1;
      if (d.currentTurn !== ctx.myIndex) return;
      ctx.later(() => ctx.emitAction({ position: (firstPos = firstFlip()) }), human(ctx, 1200, 3000));
    });
    ctx.socket.on('cardflip_flip', (d: { playerIndex: number; position: number; symbol: string }) => {
      if (Math.random() < memory) known.set(d.position, d.symbol);
      if (d.playerIndex !== ctx.myIndex) return;
      flips++;
      if (flips === 1) {
        const first = d.position;
        ctx.later(() => ctx.emitAction({ position: secondFlip(first) }), human(ctx, 900, 2200));
      }
    });
    ctx.socket.on('cardflip_result', (d: { matchedPositions?: number[] }) => {
      matched.clear();
      (d.matchedPositions ?? []).forEach(i => { matched.add(i); known.delete(i); });
    });
  },

  infinite_tictactoe(ctx) {
    turnBased(ctx, (board, me) => infiniteTttMove(board as (number | null)[], me, ctx.skill));
  },

  tictactoe(ctx) {
    turnBased(ctx, (board, me) => tttMove(board as (number | null)[], me, ctx.skill));
  },

  gomoku(ctx) {
    turnBased(ctx, (board, me) => gomokuMove(board as (number | null)[], me, ctx.skill));
  },
};

/** game_start / game_update 로 차례가 오면 move() 로 수를 골라 둔다. */
function turnBased(ctx: BotContext, move: (board: (number | null)[], me: number) => number) {
  let thinking = false;
  const onState = (d: { board: (number | null)[]; currentTurn: string }) => {
    if (d.currentTurn !== ctx.myId || thinking) return;
    thinking = true;
    ctx.later(() => {
      thinking = false;
      const position = move(d.board, ctx.myIndex);
      if (position >= 0) ctx.emitAction({ position });
    }, human(ctx, 1000, 3500));
  };
  ctx.socket.on('game_start', onState);
  ctx.socket.on('game_update', onState);
}

const TTT_LINES = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]];

function tttWinner(b: (number | null)[]): number | null {
  for (const [x, y, z] of TTT_LINES) if (b[x] !== null && b[x] === b[y] && b[y] === b[z]) return b[x];
  return null;
}

function tttMinimax(b: (number | null)[], turn: number, me: number): number {
  const w = tttWinner(b);
  if (w === me) return 1;
  if (w !== null) return -1;
  if (b.every(c => c !== null)) return 0;
  let best = turn === me ? -2 : 2;
  for (let i = 0; i < 9; i++) {
    if (b[i] !== null) continue;
    b[i] = turn;
    const v = tttMinimax(b, 1 - turn, me);
    b[i] = null;
    best = turn === me ? Math.max(best, v) : Math.min(best, v);
  }
  return best;
}

function tttMove(board: (number | null)[], me: number, skill: number): number {
  const empty = board.map((c, i) => (c === null ? i : -1)).filter(i => i >= 0);
  if (!empty.length) return -1;
  // 실력이 낮으면 가끔 아무 데나 둔다.
  if (Math.random() < 0.4 * (1 - skill)) return pick(empty);
  let bestV = -2;
  let bestMoves: number[] = [];
  for (const i of empty) {
    const b = [...board];
    b[i] = me;
    const v = tttMinimax(b, 1 - me, me);
    if (v > bestV) { bestV = v; bestMoves = [i]; } else if (v === bestV) bestMoves.push(i);
  }
  return pick(bestMoves);
}

/** 무한 틱택토: 한 수 앞만 본다(이기는 수 → 막는 수 → 중앙/모서리). 말이 사라지는 규칙은 판이 반영해 준다. */
function infiniteTttMove(board: (number | null)[], me: number, skill: number): number {
  const empty = board.map((c, i) => (c === null ? i : -1)).filter(i => i >= 0);
  if (!empty.length) return -1;
  if (Math.random() < 0.35 * (1 - skill)) return pick(empty);
  const wins = (who: number) => empty.filter(i => {
    const b = [...board];
    b[i] = who;
    return tttWinner(b) === who;
  });
  const mine = wins(me);
  if (mine.length) return pick(mine);
  const theirs = wins(1 - me);
  if (theirs.length && Math.random() < 0.55 + skill * 0.4) return pick(theirs);
  if (empty.includes(4) && Math.random() < 0.6) return 4;
  const corners = empty.filter(i => [0, 2, 6, 8].includes(i));
  return pick(corners.length && Math.random() < 0.6 ? corners : empty);
}

const GN = 15;
const DIRS: [number, number][] = [[0, 1], [1, 0], [1, 1], [1, -1]];

function gomokuLineScore(b: (number | null)[], r: number, c: number, player: number): number {
  let total = 0;
  for (const [dr, dc] of DIRS) {
    let count = 1;
    let open = 0;
    for (const sign of [1, -1]) {
      let rr = r + dr * sign;
      let cc = c + dc * sign;
      while (rr >= 0 && rr < GN && cc >= 0 && cc < GN && b[rr * GN + cc] === player) {
        count++;
        rr += dr * sign;
        cc += dc * sign;
      }
      if (rr >= 0 && rr < GN && cc >= 0 && cc < GN && b[rr * GN + cc] === null) open++;
    }
    if (count >= 5) total += 100000;
    else if (count === 4) total += open === 2 ? 10000 : open === 1 ? 1000 : 0;
    else if (count === 3) total += open === 2 ? 1000 : open === 1 ? 100 : 0;
    else if (count === 2) total += open === 2 ? 100 : open === 1 ? 10 : 0;
    else total += open;
  }
  return total;
}

function gomokuMove(board: (number | null)[], me: number, skill: number): number {
  const stones = board.filter(c => c !== null).length;
  const center = Math.floor(GN / 2) * GN + Math.floor(GN / 2);
  if (stones === 0) return center;
  const cands: { pos: number; score: number }[] = [];
  for (let r = 0; r < GN; r++) {
    for (let c = 0; c < GN; c++) {
      if (board[r * GN + c] !== null) continue;
      // 기존 돌 주변 2칸 안만 후보
      let near = false;
      for (let dr = -2; dr <= 2 && !near; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const rr = r + dr; const cc = c + dc;
          if (rr >= 0 && rr < GN && cc >= 0 && cc < GN && board[rr * GN + cc] !== null) { near = true; break; }
        }
      }
      if (!near) continue;
      const score = gomokuLineScore(board, r, c, me) + gomokuLineScore(board, r, c, 1 - me) * (0.7 + skill * 0.3);
      cands.push({ pos: r * GN + c, score });
    }
  }
  if (!cands.length) return board.findIndex(c => c === null);
  cands.sort((a, b) => b.score - a.score);
  // 실력이 낮을수록 상위 후보 중에서 흔들린다.
  const spread = Math.max(1, Math.round((1 - skill) * 6));
  return cands[Math.min(cands.length - 1, randInt(0, Math.random() < 0.3 * (1 - skill) ? spread : 0))].pos;
}

/** 테스트 전용 노출. */
export const _internal = { STRATEGIES, tttMove, gomokuMove, infiniteTttMove };
