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
 *   2인 게임 전부(틱택토·오목·가위바위보·반응속도·스피드탭·넘버배틀·사칙연산·화살표·스트룹·시퀀스·
 *   타이밍·카드뒤집기·무한 틱택토·SET·훈민정음·헥사곤·피라미드)를 지원한다.
 *   - SET: 보드에서 세트를 직접 찾아 사람 속도로 claim(가끔 오답). 무한모드(isInfinite)는 미지원.
 *   - 훈민정음: dm_korean_words(초성 인덱스)에서 후보를 조회·캐시, 실력만큼만 아는 단어로 답한다.
 *   - 헥사곤/피라미드: 보드를 풀어 버저 → 답 제출. 실력이 낮을수록 늦고 가끔 틀린다.
 *   - set/hunmin 은 실제 클라이언트처럼 find_match 에 maxPlayers: 2 를 함께 보낸다(2인 큐 경로).
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
  'set', 'hunmin', 'hexagon', 'pyramid',
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
    // SET·훈민정음은 실제 클라이언트가 maxPlayers 를 항상 보낸다. 2 = 기존 2인 큐 경로.
    const twoPlayerFlag = gameType === 'set' || gameType === 'hunmin' ? { maxPlayers: 2 } : {};
    socket.emit('find_match', { gameType, isHardcore, isInfinite, ...twoPlayerFlag });
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

  set(ctx) { setStrategy(ctx); },
  hunmin(ctx) { hunminStrategy(ctx); },
  hexagon(ctx) { hexagonStrategy(ctx); },
  pyramid(ctx) { pyramidStrategy(ctx); },

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


// ---------------------------------------------------------------- SET / 훈민정음 / 헥사곤 / 피라미드

/** 임의 값이 정수 배열이면 그대로, 아니면 빈 배열. 서버 페이로드가 예상과 달라도 던지지 않기 위함. */
const intArray = (v: unknown): number[] =>
  Array.isArray(v) ? v.filter((x): x is number => typeof x === 'number' && Number.isFinite(x)) : [];

function setAttrs(id: number): number[] {
  return [Math.floor(id / 27) % 3, Math.floor(id / 9) % 3, Math.floor(id / 3) % 3, id % 3];
}
function isSetTriple(a: number, b: number, c: number): boolean {
  const A = setAttrs(a); const B = setAttrs(b); const C = setAttrs(c);
  return [0, 1, 2, 3].every(k => (A[k] + B[k] + C[k]) % 3 === 0);
}
/** 보드의 모든 유효 세트(카드 id 3개). */
function findSets(board: number[]): number[][] {
  const out: number[][] = [];
  for (let i = 0; i < board.length - 2; i++) {
    for (let j = i + 1; j < board.length - 1; j++) {
      for (let k = j + 1; k < board.length; k++) {
        if (isSetTriple(board[i], board[j], board[k])) out.push([board[i], board[j], board[k]]);
      }
    }
  }
  return out;
}

/** SET: 보드가 바뀔 때마다 "찾는 시간"을 새로 잡고, 지나면 세트 하나를 claim 한다. 무한모드는 지원하지 않는다. */
function setStrategy(ctx: BotContext) {
  let board: number[] = [];
  let gen = 0; // 보드가 바뀌면 예약된 claim 을 무효화
  let over = false;
  const schedule = () => {
    const my = ++gen;
    if (over || !board.length) return;
    ctx.later(() => {
      if (my !== gen || over) return;
      const sets = findSets(board);
      // 사람도 가끔 헛짚는다: 실수 확률은 실력이 낮을수록 커진다(서버는 오답 -1점).
      if (board.length >= 3 && Math.random() < 0.05 * (1.2 - ctx.skill)) {
        const cards = [...board].sort(() => Math.random() - 0.5).slice(0, 3);
        if (!isSetTriple(cards[0], cards[1], cards[2])) {
          ctx.emitAction({ type: 'claim', cards });
          return;
        }
      }
      if (!sets.length) return; // 덱 소진 등 — 다음 보드 갱신을 기다린다
      const cards = [...pick(sets)].sort(() => Math.random() - 0.5);
      ctx.emitAction({ type: 'claim', cards });
    }, human(ctx, 3000, 10000));
  };
  const onBoard = (d: { board?: unknown }) => {
    const b = intArray(d?.board);
    if (!b.length) return;
    board = b;
    schedule();
  };
  ctx.socket.on('set_start', onBoard);
  ctx.socket.on('set_resumed', onBoard);
  ctx.socket.on('set_claimed', onBoard);
  // 내 오답은 보드가 안 바뀌므로 다시 찾는다. 상대가 먼저 가져가 실패한 경우는 set_claimed 가 따로 온다.
  ctx.socket.on('set_claim_rejected', (d: { playerIndex?: number; reason?: string }) => {
    if (d?.playerIndex === ctx.myIndex && (d.reason === 'not_a_set' || d.reason === 'bad_input')) schedule();
  });
  ctx.socket.on('set_timeout', () => { over = true; gen++; });
  ctx.socket.on('game_end', () => { over = true; gen++; });
}

// ---- 훈민정음 ----

const hunminWordCache = new Map<string, string[]>();

/** 초성(2글자)에 맞는 2글자 단어 후보를 사전 DB 에서 조회한다(초성별 캐시). DB 가 없거나 실패하면 빈 배열. */
async function hunminCandidates(chosung: string): Promise<string[]> {
  const cached = hunminWordCache.get(chosung);
  if (cached) return cached;
  const pool = getPool();
  if (!pool) return [];
  try {
    const r = await pool.query(
      'SELECT word FROM dm_korean_words WHERE chosung = $1 AND char_length(word) = 2 LIMIT 500',
      [chosung]
    );
    const words = (r.rows as { word: string }[]).map(x => x.word).filter(w => typeof w === 'string');
    if (words.length) hunminWordCache.set(chosung, words); // 빈 결과는 캐시하지 않는다(사전 증가 대비)
    return words;
  } catch (e) {
    console.error('[bot] hunmin dictionary query failed:', e);
    return [];
  }
}

function hunminStrategy(ctx: BotContext) {
  let chosung = '';
  let used: string[] = [];
  let myTurnToken = 0;
  ctx.socket.on('hunmin_round_start', (d: { chosung?: string }) => {
    chosung = typeof d?.chosung === 'string' ? d.chosung : '';
    used = [];
    myTurnToken++;
  });
  ctx.socket.on('hunmin_word_accepted', (d: { word?: string; usedWords?: string[] }) => {
    if (Array.isArray(d?.usedWords)) used = d.usedWords.filter(w => typeof w === 'string');
    else if (typeof d?.word === 'string') used.push(d.word);
  });
  ctx.socket.on('hunmin_turn_start', (d: { playerIndex?: number; timeLimit?: number }) => {
    const token = ++myTurnToken;
    if (d?.playerIndex !== ctx.myIndex || !chosung) return;
    const limit = typeof d.timeLimit === 'number' ? d.timeLimit : 15000;
    const startedAt = Date.now();
    const cs = chosung;
    void (async () => {
      const all = await hunminCandidates(cs);
      if (token !== myTurnToken) return;
      // 사람은 사전의 일부만 떠올린다: 실력이 높을수록 더 많이 안다. 가끔은 아예 못 떠올려 시간을 넘긴다.
      const knowRate = 0.12 + ctx.skill * 0.4;
      const blank = Math.random() < 0.06 * (1.2 - ctx.skill);
      const known = blank ? [] : all.filter(w => !used.includes(w) && Math.random() < knowRate);
      if (!known.length) return; // 못 찾음 → 서버 타임아웃으로 탈락(사람과 동일)
      const word = pick(known);
      // 생각하는 시간. 타임리밋을 넘기지 않게 1.5초 여유를 둔다.
      const wait = Math.max(300, Math.min(human(ctx, 2000, 8000), limit - 1500 - (Date.now() - startedAt)));
      ctx.later(() => {
        if (token !== myTurnToken) return;
        ctx.emitAction({ type: 'submit_word', word });
      }, wait);
    })();
  });
}

// ---- 헥사곤 ----

// 서버 games/hexagon.ts 의 ALL_LINES 와 동일(일직선 3칸 27개).
const HEX_LINES: number[][] = [
  [0, 1, 2], [3, 4, 5], [4, 5, 6], [7, 8, 9], [8, 9, 10], [9, 10, 11], [12, 13, 14], [13, 14, 15], [16, 17, 18],
  [0, 3, 7], [1, 4, 8], [2, 5, 9], [4, 8, 12], [5, 9, 13], [6, 10, 14], [9, 13, 16], [10, 14, 17], [11, 15, 18],
  [0, 4, 9], [1, 5, 10], [2, 6, 11], [3, 8, 13], [4, 9, 14], [5, 10, 15], [7, 12, 16], [8, 13, 17], [9, 14, 18],
];
const lineKey = (cells: number[]) => [...cells].sort((a, b) => a - b).join(',');

function hexagonStrategy(ctx: BotContext) {
  let numbers: number[] = [];
  let target = 0;
  let known: number[][] = []; // 이번 라운드에 "기억해 둔" 정답 줄(전부는 아니다)
  const found = new Set<string>();
  let state: 'idle' | 'memorizing' | 'playing' | 'buzzing' = 'idle';
  let gen = 0;

  const remaining = () => known.filter(l => !found.has(lineKey(l)));
  const scheduleBuzz = () => {
    const my = ++gen;
    if (state !== 'playing') return;
    if (!remaining().length) return; // 더 떠오르는 게 없으면 가만히 있는다
    ctx.later(() => {
      if (my !== gen || state !== 'playing') return;
      ctx.emitAction({ type: 'buzz' });
    }, human(ctx, 5000, 16000));
  };

  ctx.socket.on('hexagon_round_start', (d: { board?: { number?: number }[]; targetNumber?: number }) => {
    gen++;
    state = 'memorizing';
    found.clear();
    numbers = Array.isArray(d?.board) ? d.board.map(c => Number(c?.number)) : [];
    target = Number(d?.targetNumber);
    const all = numbers.length === 19
      ? HEX_LINES.filter(l => l.reduce((a, i) => a + numbers[i], 0) === target) : [];
    // 30초 암기 동안 기억하는 줄의 비율은 실력에 비례한다. 최소 하나는 기억한다.
    const recall = 0.35 + ctx.skill * 0.5;
    known = all.filter(() => Math.random() < recall);
    if (!known.length && all.length) known = [pick(all)];
  });
  ctx.socket.on('hexagon_play_start', () => { state = 'playing'; scheduleBuzz(); });
  ctx.socket.on('hexagon_buzz', (d: { playerIndex?: number }) => {
    gen++;
    state = 'buzzing';
    if (d?.playerIndex !== ctx.myIndex) return;
    const my = gen;
    ctx.later(() => {
      if (my !== gen || state !== 'buzzing') return;
      const rem = remaining();
      let cells: number[];
      // 가끔 틀린 줄을 고른다(이미 찾은 줄이나 합이 맞지 않는 줄) → 서버가 -1.
      if (!rem.length || Math.random() < 0.1 * (1.2 - ctx.skill)) {
        const wrong = HEX_LINES.filter(l => !known.some(k => lineKey(k) === lineKey(l)));
        cells = pick(wrong);
      } else {
        cells = pick(rem);
      }
      ctx.emitAction({ type: 'answer', cellIndices: Math.random() < 0.5 ? cells : [...cells].reverse() });
    }, human(ctx, 1200, 3500));
  });
  ctx.socket.on('hexagon_answer_result', (d: { foundCombinations?: { cells?: number[] }[] }) => {
    state = 'playing';
    if (Array.isArray(d?.foundCombinations)) {
      for (const fc of d.foundCombinations) if (Array.isArray(fc?.cells)) found.add(lineKey(fc.cells));
    }
    scheduleBuzz();
  });
  ctx.socket.on('hexagon_buzz_timeout', () => { state = 'playing'; scheduleBuzz(); });
  // 더 떠오르는 줄이 없을 때만 넘기기에 동의한다(양쪽 동의 필요).
  ctx.socket.on('hexagon_skip_available', () => {
    if (remaining().length) return;
    ctx.later(() => { if (state === 'playing') ctx.socket.emit('hexagon_skip_round', { roomId: ctx.roomId }); }, rand(1500, 5000));
  });
  ctx.socket.on('hexagon_round_end', () => { gen++; state = 'idle'; });
}

// ---- 피라미드 ----

/** 서버 PyramidGame.evaluateWithPrecedence 와 같은 계산(첫 카드는 값만, 이후 ×는 먼저, +/- 는 왼→오). */
function pyramidEval(cards: { operator: string; value: number }[]): number {
  const reduced: number[] = [cards[0].value];
  const ops: string[] = [];
  for (let i = 1; i < cards.length; i++) {
    if (cards[i].operator === '*') reduced[reduced.length - 1] *= cards[i].value;
    else { reduced.push(cards[i].value); ops.push(cards[i].operator); }
  }
  let r = reduced[0];
  for (let i = 0; i < ops.length; i++) r = ops[i] === '+' ? r + reduced[i + 1] : r - reduced[i + 1];
  return r;
}

function pyramidStrategy(ctx: BotContext) {
  type Card = { operator: string; value: number };
  let cards: Card[] = [];
  let answers: number[][] = [];
  let wrongs: number[][] = [];
  let state: 'idle' | 'playing' | 'buzzing' = 'idle';
  let gen = 0;

  const scheduleBuzz = () => {
    const my = ++gen;
    if (state !== 'playing' || !answers.length) return;
    ctx.later(() => {
      if (my !== gen || state !== 'playing') return;
      ctx.emitAction({ type: 'buzz' });
    }, human(ctx, 6000, 22000));
  };

  ctx.socket.on('pyramid_round_start', (d: { cards?: { operator?: string; value?: number }[]; targetNumber?: number }) => {
    gen++;
    state = 'playing';
    cards = Array.isArray(d?.cards)
      ? d.cards.map(c => ({ operator: String(c?.operator), value: Number(c?.value) })) : [];
    const target = Number(d?.targetNumber);
    answers = [];
    wrongs = [];
    if (cards.length === 10 && cards.every(c => Number.isFinite(c.value))) {
      // 10장 중 3장을 순서 있게 고르는 720가지를 전부 계산한다(서버와 같은 규칙).
      for (let a = 0; a < 10; a++) for (let b = 0; b < 10; b++) for (let c = 0; c < 10; c++) {
        if (a === b || b === c || a === c) continue;
        const seq = [a, b, c];
        (pyramidEval(seq.map(i => cards[i])) === target ? answers : wrongs).push(seq);
      }
    }
    scheduleBuzz();
  });
  ctx.socket.on('pyramid_buzz', (d: { playerIndex?: number }) => {
    gen++;
    state = 'buzzing';
    if (d?.playerIndex !== ctx.myIndex) return;
    const my = gen;
    ctx.later(() => {
      if (my !== gen || state !== 'buzzing') return;
      const miss = !answers.length || Math.random() < 0.12 * (1.2 - ctx.skill);
      const seq = miss && wrongs.length ? pick(wrongs) : pick(answers);
      if (!seq) return;
      ctx.emitAction({ type: 'answer', sequence: seq });
    }, human(ctx, 1500, 5000)); // 서버 제한 15초
  });
  // 정답이면 곧 pyramid_round_end 가 오고, 오답이면 다시 playing 으로 돌아온다.
  ctx.socket.on('pyramid_answer_result', (d: { correct?: boolean }) => {
    state = 'playing';
    if (d?.correct) { gen++; return; }
    scheduleBuzz();
  });
  ctx.socket.on('pyramid_buzz_timeout', () => { state = 'playing'; scheduleBuzz(); });
  ctx.socket.on('pyramid_round_end', () => { gen++; state = 'idle'; });
}

/** 테스트 전용 노출. */
export const _internal = { STRATEGIES, tttMove, gomokuMove, infiniteTttMove, findSets, hunminWordCache };
