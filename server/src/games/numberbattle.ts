/**
 * 숫자배틀 게임
 *
 * 일반 모드:
 * - 5x5 그리드에 1~25 랜덤 배치
 * - 두 플레이어가 동시에 1부터 순서대로 터치
 * - 먼저 25까지 완성하면 승리
 * - 60초 제한시간, 타임아웃 시 진행도 높은 쪽 승리
 *
 * 하드 모드(hardMode):
 * - 보드는 5x5(25칸) 그대로지만 1~100까지 눌러야 한다.
 * - 처음엔 1~25 랜덤 배치. 숫자를 누르면 그 칸이 "다음 구간의 숫자"로 교체된다.
 *   교체 숫자는 N+25 식 순차가 아니라 구간별 랜덤이다:
 *     · 1~25 누르는 동안  → 26~50 을 랜덤 순서로 채움
 *     · 26~50 누르는 동안 → 51~75 를 랜덤 순서로 채움
 *     · 51~75 누르는 동안 → 76~100 을 랜덤 순서로 채움
 *     · 76~100 누르는 동안 → 더 채울 게 없어 빈 칸(0)
 *   이렇게 구간 단위로 미리 셔플해 채우면, 어떤 타겟이 필요해지는 시점엔
 *   그 숫자가 항상 보드에 올라와 있다(다음 구간은 25칸 앞서 도입되므로).
 * - 보드는 항상 25개를 보여주고, 100까지 누르면 승리.
 * - 두 플레이어는 동일한 초기 배치 + 동일한 리필 순서에서 출발하므로
 *   진행이 같으면 보드도 동일 → 순수 속도 경쟁(공정).
 * - 제한시간 120초.
 */

export class NumberBattleGame {
  // 플레이어별 그리드. 일반 모드에서는 두 그리드가 동일하고 변하지 않는다(0 = 빈 칸).
  private grids: number[][][] = [];
  // 플레이어별 리필 대기열(하드모드). 누를 때마다 앞에서 하나씩 꺼내 그 칸에 채운다.
  private refillQueues: number[][] = [[], []];
  private progress: [number, number] = [0, 0]; // 각 플레이어의 현재 타겟 (다음에 눌러야 할 숫자 - 1)
  private gameOver: boolean = false;
  private winner: number | null = null;

  private readonly hardMode: boolean;
  private readonly totalNumbers: number;
  private readonly gameTime: number;

  static readonly GRID_SIZE = 5;
  static readonly TOTAL_NUMBERS = 25; // 일반 — 보드 칸 수이자 목표
  static readonly HARD_TOTAL_NUMBERS = 100; // 하드 — 목표
  static readonly GAME_TIME = 60000; // 일반 60초
  static readonly HARD_GAME_TIME = 120000; // 하드 120초

  constructor(hardMode: boolean = false) {
    this.hardMode = hardMode;
    this.totalNumbers = hardMode
      ? NumberBattleGame.HARD_TOTAL_NUMBERS
      : NumberBattleGame.TOTAL_NUMBERS;
    this.gameTime = hardMode
      ? NumberBattleGame.HARD_GAME_TIME
      : NumberBattleGame.GAME_TIME;
    const base = this.generateGrid();
    // 두 플레이어 모두 동일한 초기 배치에서 시작(공정). 하드모드에서만 이후 갈라진다.
    this.grids = [base.map(r => [...r]), base.map(r => [...r])];
    if (hardMode) {
      const queue = this.buildRefillQueue();
      this.refillQueues = [[...queue], [...queue]];
    }
  }

  // 하드모드 리필 순서: 26~50, 51~75, 76~100 을 각각 구간 내에서 셔플해 이어붙인다.
  // 구간을 통째로 섞지 않고 25개씩 끊어 섞어야 "다음 타겟이 항상 보드에 있는" 불변식이 유지된다.
  private buildRefillQueue(): number[] {
    const queue: number[] = [];
    for (let start = 26; start <= 76; start += 25) {
      const batch = Array.from({ length: 25 }, (_, i) => start + i);
      for (let i = batch.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [batch[i], batch[j]] = [batch[j], batch[i]];
      }
      queue.push(...batch);
    }
    return queue; // 길이 75 (26~100)
  }

  getIsHardMode(): boolean {
    return this.hardMode;
  }

  getTotalNumbers(): number {
    return this.totalNumbers;
  }

  getGameTime(): number {
    return this.gameTime;
  }

  private generateGrid(): number[][] {
    // Fisher-Yates 셔플로 1~25 배열 생성
    const numbers = Array.from({ length: NumberBattleGame.TOTAL_NUMBERS }, (_, i) => i + 1);
    for (let i = numbers.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [numbers[i], numbers[j]] = [numbers[j], numbers[i]];
    }

    // 5x5 그리드로 변환
    const grid: number[][] = [];
    for (let r = 0; r < NumberBattleGame.GRID_SIZE; r++) {
      grid.push(numbers.slice(r * NumberBattleGame.GRID_SIZE, (r + 1) * NumberBattleGame.GRID_SIZE));
    }
    return grid;
  }

  // 플레이어별 그리드(생략 시 0번). 일반 모드에서는 둘이 동일.
  getGrid(playerIndex: number = 0): number[][] {
    const g = this.grids[playerIndex] ?? this.grids[0];
    return g.map(row => [...row]);
  }

  getProgress(): [number, number] {
    return [...this.progress] as [number, number];
  }

  getWinner(): number | null {
    return this.winner;
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  /**
   * @returns valid 성공 여부, progress 갱신된 진행도,
   *          newNumber 하드모드에서 그 칸에 새로 채워진 숫자(0 = 빈 칸).
   */
  tap(
    playerIndex: number,
    row: number,
    col: number
  ): { valid: boolean; progress: number; newNumber: number } {
    if (this.gameOver) {
      return { valid: false, progress: this.progress[playerIndex], newNumber: 0 };
    }

    const targetNumber = this.progress[playerIndex] + 1;
    const grid = this.grids[playerIndex];
    if (grid?.[row]?.[col] !== targetNumber) {
      return { valid: false, progress: this.progress[playerIndex], newNumber: 0 };
    }

    this.progress[playerIndex]++;

    // 하드모드: 누른 칸을 리필 대기열의 다음 숫자(구간별 랜덤)로 교체. 비었으면 빈 칸(0).
    // 일반 모드는 칸을 그대로 둔다.
    let newNumber = targetNumber;
    if (this.hardMode) {
      const queue = this.refillQueues[playerIndex];
      newNumber = queue.length > 0 ? queue.shift()! : 0;
      grid[row][col] = newNumber;
    }

    // 목표(25 또는 100)까지 완성 시 승리
    if (this.progress[playerIndex] >= this.totalNumbers) {
      this.gameOver = true;
      this.winner = playerIndex;
    }

    return { valid: true, progress: this.progress[playerIndex], newNumber };
  }

  // 타임아웃 시 서버에서 호출 - 진행도 높은 쪽 승리
  setGameOver(): void {
    if (this.gameOver) return;
    this.gameOver = true;
    if (this.progress[0] > this.progress[1]) {
      this.winner = 0;
    } else if (this.progress[1] > this.progress[0]) {
      this.winner = 1;
    } else {
      this.winner = null; // 무승부
    }
  }

  reset(): void {
    const base = this.generateGrid();
    this.grids = [base.map(r => [...r]), base.map(r => [...r])];
    if (this.hardMode) {
      const queue = this.buildRefillQueue();
      this.refillQueues = [[...queue], [...queue]];
    } else {
      this.refillQueues = [[], []];
    }
    this.progress = [0, 0];
    this.gameOver = false;
    this.winner = null;
  }
}
