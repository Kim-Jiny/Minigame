/**
 * 스피드 탭 게임
 *
 * 규칙:
 * - 3라운드 진행
 * - 각 라운드 10초 동안 빠르게 터치
 * - 더 많이 누른 사람이 라운드 승리
 * - 2라운드 먼저 이기면 최종 승리
 */

export class SpeedTapGame {
  private taps: [number, number] = [0, 0]; // 현재 라운드 탭 수
  private roundScores: [number, number] = [0, 0]; // 라운드 승리 수
  private currentRound: number = 0;
  private roundInProgress: boolean = false;
  private gameOver: boolean = false;
  private roundResults: Array<{
    round: number;
    player0Taps: number;
    player1Taps: number;
    winnerIndex: number | null;
  }> = [];

  static readonly ROUND_TIME = 10000; // 10초
  static readonly WIN_ROUNDS = 2; // 2라운드 승리 시 게임 승리
  static readonly MAX_ROUNDS = 3;

  constructor() {
    this.reset();
  }

  getTaps(): [number, number] {
    return [...this.taps] as [number, number];
  }

  getRoundScores(): [number, number] {
    return [...this.roundScores] as [number, number];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  isRoundInProgress(): boolean {
    return this.roundInProgress;
  }

  getRoundResults() {
    return [...this.roundResults];
  }

  // 새 라운드 시작
  startRound(): void {
    this.currentRound++;
    this.taps = [0, 0];
    this.roundInProgress = true;
  }

  // 탭 등록
  tap(playerIndex: number): { valid: boolean; tapCount: number } {
    if (!this.roundInProgress || this.gameOver) {
      return { valid: false, tapCount: this.taps[playerIndex] };
    }

    this.taps[playerIndex]++;
    return { valid: true, tapCount: this.taps[playerIndex] };
  }

  // 라운드 종료 및 결과 계산
  endRound(): {
    player0Taps: number;
    player1Taps: number;
    roundWinner: number | null;
    isDraw: boolean;
    gameOver: boolean;
    gameWinner: number | null;
  } {
    this.roundInProgress = false;

    const player0Taps = this.taps[0];
    const player1Taps = this.taps[1];

    let roundWinner: number | null = null;
    let isDraw = false;

    if (player0Taps > player1Taps) {
      roundWinner = 0;
      this.roundScores[0]++;
    } else if (player1Taps > player0Taps) {
      roundWinner = 1;
      this.roundScores[1]++;
    } else {
      isDraw = true;
    }

    this.roundResults.push({
      round: this.currentRound,
      player0Taps,
      player1Taps,
      winnerIndex: roundWinner,
    });

    // 게임 종료 확인
    const gameOver = this.checkGameOver();
    this.gameOver = gameOver;

    return {
      player0Taps,
      player1Taps,
      roundWinner,
      isDraw,
      gameOver,
      gameWinner: gameOver ? this.getWinner() : null,
    };
  }

  private checkGameOver(): boolean {
    // 2라운드 승리 시 게임 종료
    if (this.roundScores[0] >= SpeedTapGame.WIN_ROUNDS ||
        this.roundScores[1] >= SpeedTapGame.WIN_ROUNDS) {
      return true;
    }
    // 최대 라운드 도달
    if (this.currentRound >= SpeedTapGame.MAX_ROUNDS) {
      return true;
    }
    return false;
  }

  getWinner(): number | null {
    if (this.roundScores[0] > this.roundScores[1]) return 0;
    if (this.roundScores[1] > this.roundScores[0]) return 1;
    return null; // 무승부
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  reset(): void {
    this.taps = [0, 0];
    this.roundScores = [0, 0];
    this.currentRound = 0;
    this.roundInProgress = false;
    this.gameOver = false;
    this.roundResults = [];
  }
}
