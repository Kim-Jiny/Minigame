/**
 * 타이밍 맞추기 게임
 *
 * 규칙:
 * - 5라운드, 바가 좌↔우 왕복
 * - 양 플레이어 동시에 탭 → 둘 다 멈추면 결과 공개
 * - 중심(0.5)에 가까울수록 높은 점수 (0~100)
 * - 라운드별 속도 증가: 2000→1600→1200→900→700ms
 * - 라운드 제한 5초 (미입력 시 0점)
 * - 5라운드 합산 총점으로 승패 결정
 */

export interface TimingRoundResult {
  round: number;
  positions: [number, number];
  scores: [number, number];
}

export class TimingGame {
  static readonly MAX_ROUNDS = 5;
  static readonly ROUND_TIMEOUT = 5000;
  static readonly SPEEDS = [2000, 1600, 1200, 900, 700];

  private totalScores: [number, number] = [0, 0];
  private currentRound: number = 0;
  private positions: [number | null, number | null] = [null, null];
  private roundResults: TimingRoundResult[] = [];
  private gameOver: boolean = false;

  constructor() {
    this.reset();
  }

  startRound(): { round: number; speed: number } {
    this.currentRound++;
    this.positions = [null, null];
    const speed = TimingGame.SPEEDS[this.currentRound - 1] ?? TimingGame.SPEEDS[TimingGame.SPEEDS.length - 1];
    return { round: this.currentRound, speed };
  }

  playerStop(playerIndex: number, position: number): { valid: boolean; bothDone: boolean } {
    if (this.gameOver) {
      return { valid: false, bothDone: false };
    }

    if (this.positions[playerIndex] !== null) {
      return { valid: false, bothDone: false };
    }

    this.positions[playerIndex] = Math.max(0, Math.min(1, position));

    const bothDone = this.positions[0] !== null && this.positions[1] !== null;
    return { valid: true, bothDone };
  }

  calculateRoundResult(): {
    roundScores: [number, number];
    totalScores: [number, number];
    positions: [number, number];
    gameOver: boolean;
  } {
    const pos0 = this.positions[0] ?? 0;
    const pos1 = this.positions[1] ?? 0;
    const score0 = this.calculateScore(pos0);
    const score1 = this.calculateScore(pos1);

    this.totalScores[0] += score0;
    this.totalScores[1] += score1;

    this.roundResults.push({
      round: this.currentRound,
      positions: [pos0, pos1],
      scores: [score0, score1],
    });

    if (this.currentRound >= TimingGame.MAX_ROUNDS) {
      this.gameOver = true;
    }

    return {
      roundScores: [score0, score1],
      totalScores: [...this.totalScores] as [number, number],
      positions: [pos0, pos1],
      gameOver: this.gameOver,
    };
  }

  calculateScore(position: number): number {
    const distance = Math.abs(position - 0.5);
    if (distance < 0.05) return 100;
    if (distance < 0.12) return 75;
    if (distance < 0.20) return 50;
    if (distance < 0.30) return 25;
    return 0;
  }

  hasPlayerStopped(playerIndex: number): boolean {
    return this.positions[playerIndex] !== null;
  }

  getWinner(): number | null {
    if (this.totalScores[0] > this.totalScores[1]) return 0;
    if (this.totalScores[1] > this.totalScores[0]) return 1;
    return null;
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  getTotalScores(): [number, number] {
    return [...this.totalScores] as [number, number];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getRoundResults(): TimingRoundResult[] {
    return [...this.roundResults];
  }

  getState(): {
    round: number;
    totalScores: [number, number];
    speed: number;
    hasPlayerStopped: [boolean, boolean];
  } {
    const speedIndex = Math.max(0, this.currentRound - 1);
    const speed = TimingGame.SPEEDS[speedIndex] ?? TimingGame.SPEEDS[TimingGame.SPEEDS.length - 1];
    return {
      round: this.currentRound,
      totalScores: [...this.totalScores] as [number, number],
      speed,
      hasPlayerStopped: [this.positions[0] !== null, this.positions[1] !== null],
    };
  }

  reset(): void {
    this.totalScores = [0, 0];
    this.currentRound = 0;
    this.positions = [null, null];
    this.roundResults = [];
    this.gameOver = false;
  }
}
