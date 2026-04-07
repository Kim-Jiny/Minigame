/**
 * 방향 맞추기 (ArrowDash) 게임
 *
 * 규칙:
 * - 30개의 화살표 방향을 동시에 맞춤
 * - 먼저 30개를 맞추면 승리
 * - 60초 제한시간, 타임아웃 시 더 많이 맞춘 쪽 승리
 */

interface Arrow {
  direction: string;
}

export class ArrowDashGame {
  private arrows: Arrow[] = [];
  private progress: [number, number] = [0, 0];
  private gameOver: boolean = false;
  private winner: number | null = null;

  static readonly ARROW_COUNT = 30;
  static readonly GAME_TIME = 60000; // 60초
  static readonly DIRECTIONS = ['up', 'down', 'left', 'right'];

  constructor() {
    this.arrows = this.generateArrows();
  }

  private generateArrows(): Arrow[] {
    const arrows: Arrow[] = [];

    for (let i = 0; i < ArrowDashGame.ARROW_COUNT; i++) {
      let direction: string;
      do {
        direction = ArrowDashGame.DIRECTIONS[Math.floor(Math.random() * ArrowDashGame.DIRECTIONS.length)];
      } while (
        i >= 2 &&
        arrows[i - 1].direction === direction &&
        arrows[i - 2].direction === direction
      );
      arrows.push({ direction });
    }

    return arrows;
  }

  getArrows(): Arrow[] {
    return this.arrows.map(a => ({ ...a }));
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

  checkDirection(playerIndex: number, arrowIndex: number, direction: string): { correct: boolean; progress: [number, number]; gameOver: boolean } {
    if (this.gameOver) {
      return { correct: false, progress: this.getProgress(), gameOver: true };
    }

    if (arrowIndex !== this.progress[playerIndex]) {
      return { correct: false, progress: this.getProgress(), gameOver: false };
    }

    if (direction !== this.arrows[arrowIndex].direction) {
      return { correct: false, progress: this.getProgress(), gameOver: false };
    }

    this.progress[playerIndex]++;

    if (this.progress[playerIndex] >= ArrowDashGame.ARROW_COUNT) {
      this.gameOver = true;
      this.winner = playerIndex;
    }

    return { correct: true, progress: this.getProgress(), gameOver: this.gameOver };
  }

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

  getState(): { arrows: Arrow[]; progress: [number, number]; gameOver: boolean; winner: number | null } {
    return {
      arrows: this.getArrows(),
      progress: this.getProgress(),
      gameOver: this.gameOver,
      winner: this.winner,
    };
  }

  reset(): void {
    this.arrows = this.generateArrows();
    this.progress = [0, 0];
    this.gameOver = false;
    this.winner = null;
  }
}
