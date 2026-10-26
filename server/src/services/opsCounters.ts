/**
 * [OPS] 운영 지표용 인메모리 카운터 (프로세스 재시작 시 초기화).
 * - 의존성 없음(순환 import 방지). DB 를 건드리지 않는다.
 * - 분 단위 링버퍼(최근 RING_MINUTES 분)로 소켓 'error' 이벤트와 DB 풀 에러를 센다.
 */
const RING_MINUTES = 60;

interface Ring {
  /** 분 인덱스(epoch minute) → 개수. 길이 RING_MINUTES 의 순환 버퍼. */
  minutes: number[];
  counts: number[];
  total: number;
}

function makeRing(): Ring {
  return { minutes: new Array(RING_MINUTES).fill(-1), counts: new Array(RING_MINUTES).fill(0), total: 0 };
}

function bump(ring: Ring, now = Date.now()): void {
  const m = Math.floor(now / 60000);
  const slot = m % RING_MINUTES;
  if (ring.minutes[slot] !== m) {
    ring.minutes[slot] = m;
    ring.counts[slot] = 0;
  }
  ring.counts[slot]++;
  ring.total++;
}

/** 최근 RING_MINUTES 분의 분당 개수(오래된 → 최신). 마지막 원소가 "현재 진행 중인 분". */
function series(ring: Ring, now = Date.now()): number[] {
  const cur = Math.floor(now / 60000);
  const out: number[] = [];
  for (let i = RING_MINUTES - 1; i >= 0; i--) {
    const m = cur - i;
    const slot = ((m % RING_MINUTES) + RING_MINUTES) % RING_MINUTES;
    out.push(ring.minutes[slot] === m ? ring.counts[slot] : 0);
  }
  return out;
}

const socketErrors = makeRing();
const poolErrors = makeRing();
const startedAt = Date.now();

export const opsCounters = {
  /** socket.emit('error', …) 1회. */
  socketError(): void { try { bump(socketErrors); } catch { /* noop */ } },
  /** pg Pool 'error' 이벤트 1회. */
  poolError(): void { try { bump(poolErrors); } catch { /* noop */ } },
  snapshot() {
    const s = series(socketErrors);
    const p = series(poolErrors);
    const sum = (a: number[], n: number) => a.slice(-n).reduce((x, y) => x + y, 0);
    return {
      startedAt,
      uptimeSec: Math.round((Date.now() - startedAt) / 1000),
      socketErrors: {
        perMinute: s, // 최근 60분, 마지막 = 현재 분
        last5m: sum(s, 5),
        last60m: sum(s, 60),
        total: socketErrors.total,
      },
      poolErrors: {
        last15m: sum(p, 15),
        last60m: sum(p, 60),
        total: poolErrors.total,
      },
    };
  },
};
