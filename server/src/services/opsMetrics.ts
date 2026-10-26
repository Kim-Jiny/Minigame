/**
 * [OPS] 듀오 운영 지표 — 계측(기록) + 관리자 집계 쿼리 + 알림 평가.
 *
 * 설계 원칙
 *  - 기록 함수(opsRecord*)는 fire-and-forget: await 하지 않고, 예외는 삼키고 console.error 로만 남긴다.
 *    소켓/매칭 경로의 동작·지연을 바꾸지 않는다.
 *  - 집계는 전부 사람 계정만(dm_users.is_bot = FALSE). 봇 관련 지표는 이름에 bot 이 들어간 것만 봇을 센다.
 *  - 날짜 버킷은 KST(Asia/Seoul). dm_* 의 created_at 은 TIMESTAMP(타임존 없음)이고 DB 세션 타임존으로 저장되므로
 *    `col::timestamptz AT TIME ZONE 'Asia/Seoul'` 로 KST 로 변환한다(세션 타임존과 무관하게 올바름).
 *  - 무거운 집계는 60초 메모리 캐시(키 = 종류+파라미터). 동시 요청은 하나로 합친다.
 *  - 이 파일은 socket/index.ts 를 import 하지 않는다(순환 방지). 실시간 접속 수 등은 호출자가 넘긴다.
 */
import { getPool } from '../config/database';
import { getSettings as getBotSettings, isGameSupported } from './botService';
import { opsCounters } from './opsCounters';

// ============================================================
// 알림 임계값 (여기만 고치면 된다)
// ============================================================
export const OPS_THRESHOLDS = {
  /** 매칭 대기 p90 이 이 값(ms)을 넘으면 경고. 최근 24h, 게임별 매칭 MIN 건 이상일 때만. */
  WAIT_P90_MS: 20_000,
  WAIT_MIN_MATCHES: 5,
  /** 봇 승률(최근 7일)이 [LOW, HIGH]% 밖이면 경고. 봇 대전 MIN 건 이상일 때만. */
  BOT_WIN_LOW_PCT: 30,
  BOT_WIN_HIGH_PCT: 70,
  BOT_MIN_GAMES: 20,
  /** (상대 이탈 + 연결 끊김 종료) 비율이 이 값(%)을 넘으면 경고. 최근 24h, 게임별 MIN 판 이상. */
  ABANDON_RATE_PCT: 15,
  ABANDON_MIN_GAMES: 20,
  /** 소켓 'error' 분당 개수(최근 5분 평균)가 WARN/CRIT 이상이고 직전 55분 평균의 3배 이상이면 급증으로 본다. */
  ERR_PER_MIN_WARN: 10,
  ERR_PER_MIN_CRIT: 30,
  ERR_SPIKE_FACTOR: 3,
  /** DB 풀 에러(최근 15분). WARN 이상 경고, CRIT 이상 심각. */
  POOL_ERR_WARN: 1,
  POOL_ERR_CRIT: 5,
  /** "죽은 탭": 이 시간(h) 동안 매칭이 0건인데 접속자가 MIN 명 이상. 계측 시작 후 이만큼 지난 뒤에만 평가. */
  DEAD_TAB_HOURS: 6,
  DEAD_TAB_MIN_ONLINE: 1,
  /** 코인 인플레 지표: 7일 소비/발행 비율 구간. */
  SINK_RATIO_INFLATING: 0.5,
  SINK_RATIO_WATCH: 0.8,
  SINK_RATIO_DEFLATING: 1.2,
} as const;

const RETENTION_DAYS = 90; // 계측 테이블 보관 기간
const CACHE_TTL_MS = 60_000;
const ABANDON_OUTCOMES = ['opponent_left', 'disconnect_timeout', 'forfeit'];

// ============================================================
// 계측 기록 (fire-and-forget)
// ============================================================

function logErr(what: string, e: unknown): void {
  console.error(`[ops] ${what} failed:`, e instanceof Error ? e.message : String(e));
}

/** 성사된 비랭크 매칭 1건. waitMs = 대기열에 먼저 들어간 사람이 기다린 시간. */
export function opsRecordMatch(m: { gameType: string; isHardcore: boolean; isInfinite: boolean; waitMs: number; opponentIsBot: boolean }): void {
  try {
    const pool = getPool();
    if (!pool) return;
    pool.query(
      `INSERT INTO dm_match_events (game_type, is_hardcore, is_infinite, wait_ms, opponent_is_bot) VALUES ($1, $2, $3, $4, $5)`,
      [m.gameType, m.isHardcore, m.isInfinite, Math.max(0, Math.min(3_600_000, Math.round(m.waitMs))), m.opponentIsBot],
    ).catch((e) => logErr('match insert', e));
  } catch (e) { logErr('match insert', e); }
}

/** 대기열에서 매칭 없이 나간 1건(취소/연결 끊김). */
export function opsRecordAbandon(a: { gameType: string; isHardcore: boolean; isInfinite: boolean; waitedMs: number }): void {
  try {
    const pool = getPool();
    if (!pool) return;
    pool.query(
      `INSERT INTO dm_match_abandons (game_type, is_hardcore, is_infinite, waited_ms) VALUES ($1, $2, $3, $4)`,
      [a.gameType, a.isHardcore, a.isInfinite, Math.max(0, Math.min(3_600_000, Math.round(a.waitedMs)))],
    ).catch((e) => logErr('abandon insert', e));
  } catch (e) { logErr('abandon insert', e); }
}

/** 끝난 게임 1판. outcome: completed | opponent_left | disconnect_timeout | forfeit. */
export function opsRecordGame(g: { gameType: string; durationSec: number; outcome: string; vsBot: boolean }): void {
  try {
    const pool = getPool();
    if (!pool) return;
    pool.query(
      `INSERT INTO dm_game_health (game_type, duration_sec, outcome, vs_bot) VALUES ($1, $2, $3, $4)`,
      [g.gameType, Math.max(0, Math.min(86_400, Math.round(g.durationSec))), g.outcome, g.vsBot],
    ).catch((e) => logErr('game insert', e));
  } catch (e) { logErr('game insert', e); }
}

let lastCleanupAt = 0;
/** 90일 지난 계측 행 삭제. 집계 엔드포인트에서 느긋하게(최대 6시간에 한 번) 호출한다. */
export function opsCleanupIfDue(): void {
  const now = Date.now();
  if (now - lastCleanupAt < 6 * 3600_000) return;
  lastCleanupAt = now;
  const pool = getPool();
  if (!pool) return;
  for (const t of ['dm_match_events', 'dm_match_abandons', 'dm_game_health']) {
    pool.query(`DELETE FROM ${t} WHERE created_at < NOW() - INTERVAL '${RETENTION_DAYS} days'`)
      .catch((e) => logErr(`cleanup ${t}`, e));
  }
}

// ============================================================
// 캐시 / SQL 조각
// ============================================================

const cache = new Map<string, { at: number; value?: unknown; pending?: Promise<unknown> }>();

function cached<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const now = Date.now();
  const hit = cache.get(key);
  if (hit && hit.value !== undefined && now - hit.at < CACHE_TTL_MS) return Promise.resolve(hit.value as T);
  if (hit?.pending) return hit.pending as Promise<T>;
  const pending = fn().then(
    (v) => { cache.set(key, { at: Date.now(), value: v }); return v; },
    (e) => { cache.delete(key); throw e; },
  );
  cache.set(key, { at: hit?.at ?? 0, value: hit?.value, pending });
  if (cache.size > 200) { // 키는 종류×days 정도라 사실상 닿지 않는 안전장치
    for (const [k, v] of cache) if (now - v.at > CACHE_TTL_MS && !v.pending) cache.delete(k);
  }
  return pending;
}

const KST = (c: string) => `(${c}::timestamptz AT TIME ZONE 'Asia/Seoul')`;
const TODAY = `(NOW() AT TIME ZONE 'Asia/Seoul')::date`;
/** KST 기준 최근 n일(오늘 포함)의 시작 시각(timestamptz). p = 파라미터 자리표시자. 인덱스(created_at) 범위 스캔 가능. */
const START = (p: string) => `((${TODAY} - (${p}::int - 1))::timestamp AT TIME ZONE 'Asia/Seoul')`;
const DAYS = (p: string) => `SELECT d::date AS day FROM generate_series(${TODAY} - (${p}::int - 1), ${TODAY}, INTERVAL '1 day') d`;

const num = (v: unknown): number => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const pct = (a: number, b: number): number | null => (b > 0 ? Math.round((a / b) * 1000) / 10 : null);

function pool() {
  const p = getPool();
  if (!p) throw new Error('Database not available');
  return p;
}

export function clampDays(v: unknown, def = 30): number {
  return Math.min(90, Math.max(1, parseInt(String(v ?? def), 10) || def));
}

/** 사람 계정의 활동(세션 또는 대전 기록이 있는 KST 날짜). 파라미터 $1 = 조회 일수(오늘 포함). */
const HUMAN_PLAYS_CTE = (p: string) => `
  plays AS MATERIALIZED (
    SELECT x.uid, x.day FROM (
      SELECT g.player1_id AS uid, ${KST('g.created_at')}::date AS day FROM dm_game_records g WHERE g.created_at >= ${START(p)}
      UNION ALL
      SELECT g.player2_id AS uid, ${KST('g.created_at')}::date AS day FROM dm_game_records g WHERE g.created_at >= ${START(p)}
    ) x JOIN dm_users u ON u.id = x.uid AND u.is_bot = FALSE
  )`;
const HUMAN_ACT_CTE = (p: string) => `
  ${HUMAN_PLAYS_CTE(p)},
  act AS MATERIALIZED (
    SELECT DISTINCT s.user_id AS uid, ${KST('s.created_at')}::date AS day
      FROM dm_user_sessions s JOIN dm_users u ON u.id = s.user_id AND u.is_bot = FALSE
      WHERE s.created_at >= ${START(p)}
    UNION
    SELECT uid, day FROM plays
  )`;

// ============================================================
// 1) 유저 지표
// ============================================================

export function getUsersMetrics(days: number) {
  return cached(`users:${days}`, async () => {
    const p = pool();
    const lookback = days + 29; // MAU(30일 창) 계산용
    const [daily, newUsers, ret, funnel, totals] = await Promise.all([
      p.query(`
        WITH ${HUMAN_ACT_CTE('$1')}, d AS (${DAYS('$2')})
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day,
          COUNT(DISTINCT a.uid) FILTER (WHERE a.day = d.day) AS dau,
          COUNT(DISTINCT a.uid) FILTER (WHERE a.day >= d.day - 6) AS wau,
          COUNT(DISTINCT a.uid) AS mau
        FROM d LEFT JOIN act a ON a.day BETWEEN d.day - 29 AND d.day
        GROUP BY d.day ORDER BY d.day`, [lookback, days]),
      p.query(`
        SELECT to_char(${KST('created_at')}::date, 'YYYY-MM-DD') AS day, COUNT(*) AS n
        FROM dm_users WHERE is_bot = FALSE AND created_at >= ${START('$1')} GROUP BY 1`, [days]),
      p.query(`
        WITH ${HUMAN_ACT_CTE('$1')},
        cohort AS (SELECT u.id, ${KST('u.created_at')}::date AS signup FROM dm_users u WHERE u.is_bot = FALSE AND u.created_at >= ${START('$1')})
        SELECT to_char(c.signup, 'YYYY-MM-DD') AS day, (${TODAY} - c.signup)::int AS age,
          COUNT(DISTINCT c.id) AS size,
          COUNT(DISTINCT c.id) FILTER (WHERE a.day = c.signup + 1) AS d1,
          COUNT(DISTINCT c.id) FILTER (WHERE a.day = c.signup + 7) AS d7
        FROM cohort c LEFT JOIN act a ON a.uid = c.id AND a.day IN (c.signup + 1, c.signup + 7)
        GROUP BY c.signup ORDER BY c.signup`, [days]),
      p.query(`
        WITH ${HUMAN_PLAYS_CTE('$1')},
        cohort AS (SELECT u.id, ${KST('u.created_at')}::date AS signup FROM dm_users u WHERE u.is_bot = FALSE AND u.created_at >= ${START('$1')}),
        per AS (SELECT c.id, c.signup, COUNT(pl.uid) AS n, MAX(pl.day) AS last_day
                FROM cohort c LEFT JOIN plays pl ON pl.uid = c.id GROUP BY c.id, c.signup)
        SELECT COUNT(*) AS signed, COUNT(*) FILTER (WHERE n >= 1) AS p1, COUNT(*) FILTER (WHERE n >= 3) AS p3,
               COUNT(*) FILTER (WHERE last_day > signup) AS later
        FROM per`, [days]),
      p.query(`SELECT COUNT(*) AS n FROM dm_users WHERE is_bot = FALSE`),
    ]);

    const newBy = new Map<string, number>(newUsers.rows.map((r: any) => [r.day, num(r.n)]));
    const series = daily.rows.map((r: any) => ({
      date: r.day as string, dau: num(r.dau), wau: num(r.wau), mau: num(r.mau), newUsers: newBy.get(r.day) ?? 0,
    }));
    const last = series[series.length - 1] ?? { dau: 0, wau: 0, mau: 0 };
    const last7 = series.slice(-7);
    const avgDau7 = last7.length ? last7.reduce((a, x) => a + x.dau, 0) / last7.length : 0;

    // 코호트별 D1/D7. 아직 성숙하지 않은 코호트(가입 후 k일이 안 지남)는 rate=null.
    const retention = ret.rows.map((r: any) => {
      const age = num(r.age); const size = num(r.size);
      return {
        date: r.day as string, size,
        d1: { returned: num(r.d1), ratePct: age >= 1 ? pct(num(r.d1), size) : null },
        d7: { returned: num(r.d7), ratePct: age >= 7 ? pct(num(r.d7), size) : null },
      };
    });
    const matured = (k: 'd1' | 'd7', minAge: number) => {
      let size = 0, returned = 0;
      ret.rows.forEach((r: any) => { if (num(r.age) >= minAge) { size += num(r.size); returned += num(r[k]); } });
      return { cohort: size, returned, ratePct: pct(returned, size) };
    };

    const f = funnel.rows[0] ?? {};
    const steps = [
      { key: 'signup', label: '가입', count: num(f.signed) },
      { key: 'played1', label: '1판 이상 플레이', count: num(f.p1) },
      { key: 'played3', label: '3판 이상 플레이', count: num(f.p3) },
      { key: 'returned', label: '다른 날 다시 플레이', count: num(f.later) },
    ].map((s, i, arr) => ({
      ...s,
      pctOfSignup: pct(s.count, arr[0].count),
      dropFromPrevPct: i === 0 ? null : (arr[i - 1].count > 0 ? Math.round((1 - s.count / arr[i - 1].count) * 1000) / 10 : null),
    }));

    return {
      days, timezone: 'Asia/Seoul', generatedAt: new Date().toISOString(),
      kpi: {
        dau: last.dau, wau: last.wau, mau: last.mau,
        stickinessPct: pct(last.dau, last.mau),
        stickiness7Pct: last.mau > 0 ? Math.round((avgDau7 / last.mau) * 1000) / 10 : null,
        newUsersRange: series.reduce((a, x) => a + x.newUsers, 0),
        totalUsers: num(totals.rows[0]?.n),
      },
      daily: series,
      retention,
      retentionSummary: { d1: matured('d1', 1), d7: matured('d7', 7) },
      funnel: steps,
    };
  });
}

// ============================================================
// 2) 매칭 품질
// ============================================================

export function getMatchingMetrics(days: number) {
  return cached(`matching:${days}`, async () => {
    const p = pool();
    const [m, a, dm, da, bot] = await Promise.all([
      p.query(`
        SELECT game_type, COUNT(*) AS matches,
          COUNT(*) FILTER (WHERE opponent_is_bot) AS bot_matches,
          COUNT(*) FILTER (WHERE NOT opponent_is_bot) AS human_matches,
          AVG(wait_ms)::float8 AS avg_wait,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY wait_ms) AS p50,
          percentile_cont(0.9) WITHIN GROUP (ORDER BY wait_ms) AS p90,
          percentile_cont(0.9) WITHIN GROUP (ORDER BY wait_ms) FILTER (WHERE NOT opponent_is_bot) AS human_p90
        FROM dm_match_events WHERE created_at >= ${START('$1')} GROUP BY game_type`, [days]),
      p.query(`
        SELECT game_type, COUNT(*) AS abandons, AVG(waited_ms)::float8 AS avg_waited
        FROM dm_match_abandons WHERE created_at >= ${START('$1')} GROUP BY game_type`, [days]),
      p.query(`
        WITH d AS (${DAYS('$1')}),
        e AS (SELECT ${KST('created_at')}::date AS day, COUNT(*) AS matches, COUNT(*) FILTER (WHERE opponent_is_bot) AS bot_matches
              FROM dm_match_events WHERE created_at >= ${START('$1')} GROUP BY 1)
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day, COALESCE(e.matches, 0) AS matches, COALESCE(e.bot_matches, 0) AS bot_matches
        FROM d LEFT JOIN e ON e.day = d.day ORDER BY d.day`, [days]),
      p.query(`
        SELECT to_char(${KST('created_at')}::date, 'YYYY-MM-DD') AS day, COUNT(*) AS n
        FROM dm_match_abandons WHERE created_at >= ${START('$1')} GROUP BY 1`, [days]),
      getBotSettings().catch(() => null),
    ]);

    const abBy = new Map<string, { abandons: number; avgWaited: number }>(a.rows.map((r: any) => [r.game_type, { abandons: num(r.abandons), avgWaited: num(r.avg_waited) }]));
    const keys = new Set<string>([...m.rows.map((r: any) => r.game_type as string), ...abBy.keys()]);
    const mBy = new Map<string, any>(m.rows.map((r: any) => [r.game_type, r]));
    const botCfg = bot ? { enabled: bot.enabled, waitSeconds: bot.waitSeconds } : null;

    const games = [...keys].map((gt) => {
      const r = mBy.get(gt);
      const matches = num(r?.matches); const botMatches = num(r?.bot_matches); const humanMatches = num(r?.human_matches);
      const ab = abBy.get(gt) ?? { abandons: 0, avgWaited: 0 };
      const p90 = r ? num(r.p90) : null;
      const humanP90 = r && r.human_p90 !== null && r.human_p90 !== undefined ? num(r.human_p90) : null;
      return {
        gameType: gt, matches, botMatches, humanMatches,
        botSharePct: pct(botMatches, matches),
        avgWaitMs: r ? Math.round(num(r.avg_wait)) : null,
        p50WaitMs: r ? Math.round(num(r.p50)) : null,
        p90WaitMs: p90 === null ? null : Math.round(p90),
        humanP90WaitMs: humanP90 === null ? null : Math.round(humanP90),
        abandons: ab.abandons,
        // 대기자 1명당 성사 1건 또는 이탈 1건으로 본 근사치(성사된 대기자 수 ≈ 매칭 수)
        abandonRatePct: pct(ab.abandons, ab.abandons + matches),
        avgAbandonWaitMs: ab.abandons ? Math.round(ab.avgWaited) : null,
        hint: botHint(gt, botCfg, matches, humanMatches, botMatches, p90, humanP90),
      };
    }).sort((x, y) => (y.matches + y.abandons) - (x.matches + x.abandons));

    const abDay = new Map<string, number>(da.rows.map((r: any) => [r.day, num(r.n)]));
    const daily = dm.rows.map((r: any) => ({
      date: r.day as string, matches: num(r.matches), botMatches: num(r.bot_matches), abandons: abDay.get(r.day) ?? 0,
    }));

    // 전체 합계(가중 평균/백분위는 게임별 값으로 근사하지 않고 별도 쿼리로 정확히 계산)
    const tot = await p.query(`
      SELECT COUNT(*) AS matches, COUNT(*) FILTER (WHERE opponent_is_bot) AS bot_matches,
        AVG(wait_ms)::float8 AS avg_wait,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY wait_ms) AS p50,
        percentile_cont(0.9) WITHIN GROUP (ORDER BY wait_ms) AS p90
      FROM dm_match_events WHERE created_at >= ${START('$1')}`, [days]);
    const t = tot.rows[0] ?? {};
    const totMatches = num(t.matches); const totAb = games.reduce((s, g) => s + g.abandons, 0);

    return {
      days, timezone: 'Asia/Seoul', generatedAt: new Date().toISOString(),
      bot: botCfg,
      totals: {
        matches: totMatches, botMatches: num(t.bot_matches), botSharePct: pct(num(t.bot_matches), totMatches),
        abandons: totAb, abandonRatePct: pct(totAb, totAb + totMatches),
        avgWaitMs: totMatches ? Math.round(num(t.avg_wait)) : null,
        p50WaitMs: totMatches ? Math.round(num(t.p50)) : null,
        p90WaitMs: totMatches ? Math.round(num(t.p90)) : null,
      },
      games, daily,
    };
  });
}

/** "봇 켜도 되는 시점" 힌트. 표본이 적으면(매칭 5건 미만) null. */
function botHint(
  gameType: string, bot: { enabled: boolean; waitSeconds: number } | null,
  matches: number, humanMatches: number, botMatches: number, p90: number | null, humanP90: number | null,
): { code: string; message: string } | null {
  if (!bot || matches < OPS_THRESHOLDS.WAIT_MIN_MATCHES || p90 === null) return null;
  const waitMs = bot.waitSeconds * 1000;
  const slow = (humanMatches >= OPS_THRESHOLDS.WAIT_MIN_MATCHES && humanP90 !== null) ? humanP90 : p90;
  const sec = (ms: number) => `${(ms / 1000).toFixed(1)}초`;
  const supported = isGameSupported(gameType, false, false);
  const share = (botMatches / matches) * 100;
  if (!supported) {
    return slow > OPS_THRESHOLDS.WAIT_P90_MS ? { code: 'bot_unsupported', message: `봇 미지원 게임인데 대기가 길어요 (p90 ${sec(slow)}). 봇이 붙지 않아요.` } : null;
  }
  if (!bot.enabled && slow > waitMs) {
    return { code: 'turn_on', message: `봇을 켜면 대기가 줄어요 (유저끼리 p90 ${sec(slow)} > 봇 대기 설정 ${bot.waitSeconds}초).` };
  }
  if (bot.enabled && slow > waitMs + 8000 && share < 10) {
    return { code: 'bot_not_attaching', message: `봇이 거의 안 붙어요 (봇 비중 ${share.toFixed(0)}%, p90 ${sec(slow)}). 동시 투입 한도를 확인하세요.` };
  }
  if (bot.enabled && share >= 60) {
    return { code: 'bot_heavy', message: `봇 매칭 비중이 높아요 (${share.toFixed(0)}%). 유저 풀이 얇은 시간대예요.` };
  }
  return null;
}

// ============================================================
// 3) 게임 건강도
// ============================================================

export function getHealthMetrics(days: number) {
  return cached(`health:${days}`, async () => {
    const p = pool();
    const [g, d] = await Promise.all([
      p.query(`
        SELECT game_type, COUNT(*) AS plays,
          COUNT(*) FILTER (WHERE outcome = 'completed') AS completed,
          COUNT(*) FILTER (WHERE outcome = 'opponent_left') AS opponent_left,
          COUNT(*) FILTER (WHERE outcome = 'disconnect_timeout') AS disconnect_timeout,
          COUNT(*) FILTER (WHERE outcome = 'forfeit') AS forfeit,
          COUNT(*) FILTER (WHERE vs_bot) AS vs_bot,
          AVG(duration_sec)::float8 AS avg_dur,
          AVG(duration_sec) FILTER (WHERE outcome = 'completed')::float8 AS avg_dur_completed
        FROM dm_game_health WHERE created_at >= ${START('$1')} GROUP BY game_type`, [days]),
      p.query(`
        WITH d AS (${DAYS('$1')}),
        e AS (SELECT ${KST('created_at')}::date AS day, COUNT(*) AS plays,
                COUNT(*) FILTER (WHERE outcome <> 'completed') AS abandoned
              FROM dm_game_health WHERE created_at >= ${START('$1')} GROUP BY 1)
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day, COALESCE(e.plays, 0) AS plays, COALESCE(e.abandoned, 0) AS abandoned
        FROM d LEFT JOIN e ON e.day = d.day ORDER BY d.day`, [days]),
    ]);

    const games = g.rows.map((r: any) => {
      const plays = num(r.plays); const completed = num(r.completed);
      const ol = num(r.opponent_left); const dt = num(r.disconnect_timeout); const ff = num(r.forfeit);
      const abandoned = ol + dt + ff;
      const abandonRatePct = pct(abandoned, plays);
      return {
        gameType: r.game_type as string, plays, completed,
        opponentLeft: ol, disconnectTimeout: dt, forfeit: ff,
        completionRatePct: pct(completed, plays), abandonRatePct,
        avgDurationSec: plays ? Math.round(num(r.avg_dur)) : null,
        avgCompletedDurationSec: completed ? Math.round(num(r.avg_dur_completed)) : null,
        vsBotPlays: num(r.vs_bot), vsBotSharePct: pct(num(r.vs_bot), plays),
        // 문제 점수 = 이탈률(%) × 표본 가중(20판에서 1.0). 표본이 적은 게임이 상단을 차지하지 않게.
        problemScore: Math.round((abandonRatePct ?? 0) * Math.min(1, plays / 20) * 10) / 10,
      };
    }).sort((x, y) => y.plays - x.plays);

    const problematic = games
      .filter((x) => x.plays >= 5 && x.problemScore > 0)
      .sort((x, y) => y.problemScore - x.problemScore)
      .slice(0, 5)
      .map((x) => ({
        gameType: x.gameType, plays: x.plays, abandonRatePct: x.abandonRatePct, problemScore: x.problemScore,
        reason: x.disconnectTimeout >= x.opponentLeft ? '연결 끊김 종료가 많아요' : '중간에 나가는 경우가 많아요',
      }));

    const sum = (f: (x: typeof games[number]) => number) => games.reduce((a, x) => a + f(x), 0);
    const plays = sum((x) => x.plays); const completed = sum((x) => x.completed);
    const durW = games.reduce((a, x) => a + (x.avgDurationSec ?? 0) * x.plays, 0);

    return {
      days, timezone: 'Asia/Seoul', generatedAt: new Date().toISOString(),
      totals: {
        plays, completed, abandoned: plays - completed,
        completionRatePct: pct(completed, plays), abandonRatePct: pct(plays - completed, plays),
        avgDurationSec: plays ? Math.round(durW / plays) : null,
        vsBotSharePct: pct(sum((x) => x.vsBotPlays), plays),
      },
      games, problematic,
      daily: d.rows.map((r: any) => ({ date: r.day as string, plays: num(r.plays), abandoned: num(r.abandoned) })),
      errors: opsCounters.snapshot(), // 서버 시작 이후 인메모리 카운터(재시작 시 초기화)
    };
  });
}

// ============================================================
// 4) 코인 경제
// ============================================================

const SOURCE_BUCKET_SQL = `CASE
  WHEN h.reason IN ('game_win', 'game_multi_win') THEN 'game_win'
  WHEN left(h.reason, 5) = 'game_' THEN 'game_other'
  WHEN h.reason = 'ad_reward' THEN 'ad'
  WHEN left(h.reason, 9) = 'purchase_' THEN 'shop'
  WHEN left(h.reason, 11) = 'reset_stats' THEN 'reset'
  WHEN left(h.reason, 6) = 'admin_' THEN 'admin'
  ELSE 'other' END`;
const SOURCE_LABELS: Record<string, string> = {
  game_win: '게임 승리 보상', game_other: '게임 패배·무승부 보상', ad: '광고 보상', shop: '상점 구매',
  reset: '전적 초기화(비용·환불)', admin: '운영자 지급·회수', other: '기타',
};
const SHOP_EFFECTIVE_PRICE = `CASE WHEN si.price > 0 AND si.sale_percent > 0 AND (si.sale_ends_at IS NULL OR si.sale_ends_at > CURRENT_TIMESTAMP)
  THEN GREATEST(1, ROUND(si.price * (100 - si.sale_percent) / 100.0)::int) ELSE si.price END`;

export function getEconomyMetrics(days: number) {
  return cached(`economy:${days}`, async () => {
    const p = pool();
    const lookback = days + 14; // 7일 이동평균 + 직전 7일 비교용
    const [daily, src, price, topHolders, purchases] = await Promise.all([
      p.query(`
        WITH d AS (${DAYS('$1')}),
        h AS (SELECT ${KST('h.created_at')}::date AS day,
                COALESCE(SUM(h.amount) FILTER (WHERE h.amount > 0), 0) AS earned,
                COALESCE(-SUM(h.amount) FILTER (WHERE h.amount < 0), 0) AS spent
              FROM dm_mileage_history h JOIN dm_users u ON u.id = h.user_id AND u.is_bot = FALSE
              WHERE h.created_at >= ${START('$1')} GROUP BY 1)
        SELECT to_char(d.day, 'YYYY-MM-DD') AS day, COALESCE(h.earned, 0) AS earned, COALESCE(h.spent, 0) AS spent
        FROM d LEFT JOIN h ON h.day = d.day ORDER BY d.day`, [lookback]),
      p.query(`
        SELECT ${SOURCE_BUCKET_SQL} AS bucket,
          COALESCE(SUM(h.amount) FILTER (WHERE h.amount > 0), 0) AS earned,
          COALESCE(-SUM(h.amount) FILTER (WHERE h.amount < 0), 0) AS spent
        FROM dm_mileage_history h JOIN dm_users u ON u.id = h.user_id AND u.is_bot = FALSE
        WHERE h.created_at >= ${START('$1')} GROUP BY 1`, [days]),
      p.query(`
        SELECT MIN(${SHOP_EFFECTIVE_PRICE})::int AS min_price
        FROM dm_shop_items si
        WHERE si.is_active = TRUE AND si.is_default = FALSE AND si.price > 0
          AND (si.available_until IS NULL OR si.available_until > CURRENT_TIMESTAMP)`),
      p.query(`
        SELECT u.id, u.nickname, m.mileage
        FROM dm_user_mileage m JOIN dm_users u ON u.id = m.user_id AND u.is_bot = FALSE
        ORDER BY m.mileage DESC, u.id LIMIT 10`),
      p.query(`
        SELECT COUNT(*) AS n, COALESCE(SUM(sp.price_paid), 0) AS revenue, COUNT(DISTINCT sp.user_id) AS buyers
        FROM dm_shop_purchases sp JOIN dm_users u ON u.id = sp.user_id AND u.is_bot = FALSE
        WHERE sp.created_at >= ${START('$1')}`, [days]),
    ]);

    const minPrice: number | null = price.rows[0]?.min_price === null || price.rows[0]?.min_price === undefined ? null : num(price.rows[0].min_price);
    const bal = await p.query(`
      SELECT COUNT(*) AS users, COALESCE(AVG(bal), 0)::float8 AS avg, COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY bal), 0) AS median,
        COALESCE(SUM(bal), 0) AS total,
        COUNT(*) FILTER (WHERE $1::int IS NOT NULL AND bal < $1::int) AS poor,
        COUNT(*) FILTER (WHERE active) AS active_users,
        COUNT(*) FILTER (WHERE active AND $1::int IS NOT NULL AND bal < $1::int) AS poor_active
      FROM (
        SELECT COALESCE(m.mileage, 0) AS bal,
          EXISTS (SELECT 1 FROM dm_user_sessions s WHERE s.user_id = u.id AND s.created_at >= NOW() - INTERVAL '30 days') AS active
        FROM dm_users u LEFT JOIN dm_user_mileage m ON m.user_id = u.id WHERE u.is_bot = FALSE
      ) t`, [minPrice]);
    const b = bal.rows[0] ?? {};

    const all = daily.rows.map((r: any) => {
      const earned = num(r.earned); const spent = num(r.spent);
      return { date: r.day as string, earned, spent, net: earned - spent };
    });
    const avgOf = (arr: { net: number }[]) => (arr.length ? arr.reduce((s, x) => s + x.net, 0) / arr.length : 0);
    const withMa = all.map((x, i) => ({ ...x, net7d: Math.round(avgOf(all.slice(Math.max(0, i - 6), i + 1))) }));
    const series = withMa.slice(-days);
    const last7 = all.slice(-7); const prev7 = all.slice(-14, -7);
    const earned7 = last7.reduce((s, x) => s + x.earned, 0); const spent7 = last7.reduce((s, x) => s + x.spent, 0);
    const sinkRatio = earned7 > 0 ? Math.round((spent7 / earned7) * 100) / 100 : null;
    const avgNet7 = Math.round(avgOf(last7)); const avgNetPrev = Math.round(avgOf(prev7));
    let status = 'insufficient'; let message = '데이터가 부족해요.';
    if (sinkRatio !== null) {
      if (sinkRatio < OPS_THRESHOLDS.SINK_RATIO_INFLATING) { status = 'inflating'; message = `최근 7일 소비가 발행의 ${Math.round(sinkRatio * 100)}% — 코인이 쌓이고 있어요(인플레 위험).`; }
      else if (sinkRatio < OPS_THRESHOLDS.SINK_RATIO_WATCH) { status = 'watch'; message = `최근 7일 소비가 발행의 ${Math.round(sinkRatio * 100)}% — 지켜보세요.`; }
      else if (sinkRatio > OPS_THRESHOLDS.SINK_RATIO_DEFLATING) { status = 'deflating'; message = `최근 7일 소비가 발행의 ${Math.round(sinkRatio * 100)}% — 코인이 줄고 있어요.`; }
      else { status = 'healthy'; message = `최근 7일 소비가 발행의 ${Math.round(sinkRatio * 100)}% — 균형 상태예요.`; }
    }

    const users = num(b.users);
    const pu = purchases.rows[0] ?? {};
    return {
      days, timezone: 'Asia/Seoul', generatedAt: new Date().toISOString(),
      daily: series,
      sources: src.rows.map((r: any) => ({ bucket: r.bucket as string, label: SOURCE_LABELS[r.bucket] ?? r.bucket, earned: num(r.earned), spent: num(r.spent) }))
        .sort((x: any, y: any) => (y.earned + y.spent) - (x.earned + x.spent)),
      totals: {
        earned: series.reduce((s, x) => s + x.earned, 0), spent: series.reduce((s, x) => s + x.spent, 0),
        net: series.reduce((s, x) => s + x.net, 0),
      },
      balances: {
        users, total: num(b.total), avg: Math.round(num(b.avg)), median: Math.round(num(b.median)),
        cheapestItemPrice: minPrice,
        cannotAfford: { count: num(b.poor), pct: minPrice === null ? null : pct(num(b.poor), users) },
        cannotAffordActive: { count: num(b.poor_active), activeUsers: num(b.active_users), pct: minPrice === null ? null : pct(num(b.poor_active), num(b.active_users)) },
      },
      topHolders: topHolders.rows.map((r: any) => ({ id: num(r.id), nickname: String(r.nickname ?? ''), balance: num(r.mileage) })),
      purchases: { count: num(pu.n), revenue: num(pu.revenue), buyers: num(pu.buyers) },
      inflation: { avgNet7d: avgNet7, avgNetPrev7d: avgNetPrev, changePct: avgNetPrev !== 0 ? Math.round(((avgNet7 - avgNetPrev) / Math.abs(avgNetPrev)) * 1000) / 10 : null, sinkRatio7d: sinkRatio, status, message },
    };
  });
}

// ============================================================
// 5) 알림
// ============================================================

export interface OpsAlert {
  severity: 'warn' | 'crit';
  code: string;
  message: string;
  value: number | null;
  threshold: number | null;
  game?: string;
}

const GAME_LABELS: Record<string, string> = {
  tictactoe: '틱택토', infinite_tictactoe: '무한 틱택토', gomoku: '오목', reaction: '반응속도', rps: '가위바위보',
  speedtap: '스피드탭', sequence: '시퀀스', stroop: '스트룹', hexagon: '헥사곤', pyramid: '수식피라미드',
  hunmin: '훈민정음', numberbattle: '숫자배틀', cardflip: '카드뒤집기', mathrace: '사칙연산', arrowdash: '방향맞추기',
  timing: '타이밍', set: '세트',
};
const gl = (g: string) => GAME_LABELS[g] || g;

/** 알림 평가(60초 캐시). onlineUsers = 현재 접속 중인 사람 수(호출자가 getLiveStats() 에서 넘김). */
export function getAlerts(onlineUsers: number): Promise<{ alerts: OpsAlert[]; evaluatedAt: string }> {
  return cached('alerts', async () => {
    const T = OPS_THRESHOLDS;
    const alerts: OpsAlert[] = [];
    const p = getPool();
    if (p) {
      const safe = async <R>(label: string, fn: () => Promise<R>): Promise<R | null> => {
        try { return await fn(); } catch (e) { logErr(`alert query ${label}`, e); return null; }
      };
      const [wait, bot, health, dead] = await Promise.all([
        safe('wait', () => p.query(`
          SELECT game_type, COUNT(*) AS n, percentile_cont(0.9) WITHIN GROUP (ORDER BY wait_ms) AS p90
          FROM dm_match_events WHERE created_at >= NOW() - INTERVAL '24 hours'
          GROUP BY game_type HAVING COUNT(*) >= $1`, [T.WAIT_MIN_MATCHES])),
        safe('bot', () => p.query(`
          SELECT COUNT(*) AS games, COUNT(*) FILTER (WHERE gr.winner_id IN (SELECT id FROM dm_users WHERE is_bot)) AS bot_wins
          FROM dm_game_records gr
          WHERE gr.created_at >= NOW() - INTERVAL '7 days'
            AND (gr.player1_id IN (SELECT id FROM dm_users WHERE is_bot) OR gr.player2_id IN (SELECT id FROM dm_users WHERE is_bot))`)),
        safe('health', () => p.query(`
          SELECT game_type, COUNT(*) AS n,
            COUNT(*) FILTER (WHERE outcome IN ('opponent_left', 'disconnect_timeout')) AS bad
          FROM dm_game_health WHERE created_at >= NOW() - INTERVAL '24 hours'
          GROUP BY game_type HAVING COUNT(*) >= $1`, [T.ABANDON_MIN_GAMES])),
        safe('dead', () => p.query(`
          SELECT MIN(created_at) < NOW() - make_interval(hours => $1::int) AS baseline_ok,
                 MAX(created_at) >= NOW() - make_interval(hours => $1::int) AS recent
          FROM dm_match_events`, [T.DEAD_TAB_HOURS])),
      ]);

      wait?.rows.forEach((r: any) => {
        const v = Math.round(num(r.p90));
        if (v > T.WAIT_P90_MS) {
          alerts.push({ severity: v > T.WAIT_P90_MS * 2 ? 'crit' : 'warn', code: 'match_wait_p90', game: r.game_type,
            message: `${gl(r.game_type)} 매칭 대기 p90 ${(v / 1000).toFixed(1)}초 (최근 24시간, ${num(r.n)}건)`, value: v, threshold: T.WAIT_P90_MS });
        }
      });

      const b = bot?.rows[0];
      if (b && num(b.games) >= T.BOT_MIN_GAMES) {
        const rate = Math.round((num(b.bot_wins) / num(b.games)) * 1000) / 10;
        if (rate < T.BOT_WIN_LOW_PCT || rate > T.BOT_WIN_HIGH_PCT) {
          alerts.push({ severity: 'warn', code: 'bot_win_rate', value: rate, threshold: rate < T.BOT_WIN_LOW_PCT ? T.BOT_WIN_LOW_PCT : T.BOT_WIN_HIGH_PCT,
            message: `봇 승률 ${rate}% (최근 7일 ${num(b.games)}판) — 정상 범위 ${T.BOT_WIN_LOW_PCT}~${T.BOT_WIN_HIGH_PCT}% 밖이에요. 봇 실력을 조정하세요.` });
        }
      }

      health?.rows.forEach((r: any) => {
        const rate = Math.round((num(r.bad) / num(r.n)) * 1000) / 10;
        if (rate > T.ABANDON_RATE_PCT) {
          alerts.push({ severity: rate > T.ABANDON_RATE_PCT * 2 ? 'crit' : 'warn', code: 'game_abandon_rate', game: r.game_type, value: rate, threshold: T.ABANDON_RATE_PCT,
            message: `${gl(r.game_type)} 이탈·끊김 종료 ${rate}% (최근 24시간, ${num(r.n)}판)` });
        }
      });

      const d = dead?.rows[0];
      if (d && d.baseline_ok === true && d.recent === false && onlineUsers >= T.DEAD_TAB_MIN_ONLINE) {
        alerts.push({ severity: 'warn', code: 'no_matches', value: 0, threshold: T.DEAD_TAB_HOURS,
          message: `최근 ${T.DEAD_TAB_HOURS}시간 동안 매칭이 0건인데 ${onlineUsers}명이 접속 중이에요. 매칭이 막혔는지 확인하세요.` });
      }
    }

    const snap = opsCounters.snapshot();
    const rate5 = snap.socketErrors.last5m / 5;
    const base = (snap.socketErrors.last60m - snap.socketErrors.last5m) / 55;
    if (rate5 >= T.ERR_PER_MIN_WARN && rate5 >= base * T.ERR_SPIKE_FACTOR) {
      alerts.push({ severity: rate5 >= T.ERR_PER_MIN_CRIT ? 'crit' : 'warn', code: 'socket_error_spike', value: Math.round(rate5 * 10) / 10, threshold: T.ERR_PER_MIN_WARN,
        message: `소켓 error 이벤트 분당 ${rate5.toFixed(1)}건 (최근 5분 평균, 평소 ${base.toFixed(1)}건)` });
    }
    if (snap.poolErrors.last15m >= T.POOL_ERR_WARN) {
      alerts.push({ severity: snap.poolErrors.last15m >= T.POOL_ERR_CRIT ? 'crit' : 'warn', code: 'db_pool_error', value: snap.poolErrors.last15m, threshold: T.POOL_ERR_WARN,
        message: `DB 커넥션 풀 에러 ${snap.poolErrors.last15m}건 (최근 15분)` });
    }

    alerts.sort((a, b2) => (a.severity === b2.severity ? 0 : a.severity === 'crit' ? -1 : 1));
    return { alerts, evaluatedAt: new Date().toISOString() };
  });
}

// ============================================================
// 요약(탭 헤더) — 가벼운 쿼리만
// ============================================================

export function getOpsSummary(live: { onlineUsers: number; playingRooms: number }) {
  return cached('summary', async () => {
    const p = pool();
    const [act, newToday, match, health, eco, alerts] = await Promise.all([
      p.query(`
        WITH ${HUMAN_ACT_CTE('$1')}
        SELECT COUNT(DISTINCT uid) FILTER (WHERE day = ${TODAY}) AS dau,
               COUNT(DISTINCT uid) FILTER (WHERE day >= ${TODAY} - 6) AS wau,
               COUNT(DISTINCT uid) AS mau
        FROM act`, [30]),
      p.query(`SELECT COUNT(*) AS n FROM dm_users WHERE is_bot = FALSE AND created_at >= ${START('$1')}`, [1]),
      p.query(`
        SELECT COUNT(*) AS matches, COUNT(*) FILTER (WHERE opponent_is_bot) AS bot,
          (SELECT COUNT(*) FROM dm_match_abandons WHERE created_at >= NOW() - INTERVAL '24 hours') AS abandons
        FROM dm_match_events WHERE created_at >= NOW() - INTERVAL '24 hours'`),
      p.query(`
        SELECT COUNT(*) AS plays, COUNT(*) FILTER (WHERE outcome = 'completed') AS completed
        FROM dm_game_health WHERE created_at >= NOW() - INTERVAL '24 hours'`),
      p.query(`
        SELECT COALESCE(SUM(h.amount) FILTER (WHERE h.amount > 0), 0) AS earned,
               COALESCE(-SUM(h.amount) FILTER (WHERE h.amount < 0), 0) AS spent
        FROM dm_mileage_history h JOIN dm_users u ON u.id = h.user_id AND u.is_bot = FALSE
        WHERE h.created_at >= ${START('$1')}`, [1]),
      getAlerts(live.onlineUsers),
    ]);
    const a = act.rows[0] ?? {}; const m = match.rows[0] ?? {}; const h = health.rows[0] ?? {}; const e = eco.rows[0] ?? {};
    const dau = num(a.dau); const mau = num(a.mau);
    const matches = num(m.matches); const abandons = num(m.abandons);
    return {
      generatedAt: new Date().toISOString(), timezone: 'Asia/Seoul',
      live,
      kpi: {
        dau, wau: num(a.wau), mau, stickinessPct: pct(dau, mau),
        newUsersToday: num(newToday.rows[0]?.n),
        matches24h: matches, botSharePct24h: pct(num(m.bot), matches),
        abandonRatePct24h: pct(abandons, abandons + matches),
        games24h: num(h.plays), completionRatePct24h: pct(num(h.completed), num(h.plays)),
        coinsEarnedToday: num(e.earned), coinsSpentToday: num(e.spent), coinsNetToday: num(e.earned) - num(e.spent),
      },
      alerts: alerts.alerts,
    };
  });
}
