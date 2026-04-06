/**
 * 숫자배틀 게임
 *
 * 규칙:
 * - 5x5 그리드에 1~25 랜덤 배치
 * - 두 플레이어가 동시에 1부터 순서대로 터치
 * - 먼저 25까지 완성하면 승리
 * - 60초 제한시간, 타임아웃 시 진행도 높은 쪽 승리
 */

export class NumberBattleGame {
  private grid: number[][] = [];
  private progress: [number, number] = [0, 0]; // 각 플레이어의 현재 타겟 (다음에 눌러야 할 숫자 - 1)
  private gameOver: boolean = false;
  private winner: number | null = null;

  static readonly GRID_SIZE = 5;
  static readonly TOTAL_NUMBERS = 25;
  static readonly GAME_TIME = 60000; // 60초

  constructor() {
    this.grid = this.generateGrid();
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

  getGrid(): number[][] {
    return this.grid.map(row => [...row]);
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

  tap(playerIndex: number, row: number, col: number): { valid: boolean; progress: number } {
    if (this.gameOver) {
      return { valid: false, progress: this.progress[playerIndex] };
    }

    const targetNumber = this.progress[playerIndex] + 1;
    if (this.grid[row]?.[col] !== targetNumber) {
      return { valid: false, progress: this.progress[playerIndex] };
    }

    this.progress[playerIndex]++;

    // 25까지 완성 시 승리
    if (this.progress[playerIndex] >= NumberBattleGame.TOTAL_NUMBERS) {
      this.gameOver = true;
      this.winner = playerIndex;
    }

    return { valid: true, progress: this.progress[playerIndex] };
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
    this.grid = this.generateGrid();
    this.progress = [0, 0];
    this.gameOver = false;
    this.winner = null;
  }
}
