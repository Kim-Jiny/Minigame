/**
 * 사칙연산 스피드 게임
 *
 * 규칙:
 * - 10개의 사칙연산 문제를 동시에 품
 * - 먼저 10문제를 맞추면 승리
 * - 60초 제한시간, 타임아웃 시 더 많이 푼 쪽 승리
 */

interface Problem {
  num1: number;
  num2: number;
  operator: string;
  answer: number;
}

export class MathRaceGame {
  private problems: Problem[] = [];
  private progress: [number, number] = [0, 0];
  private gameOver: boolean = false;
  private winner: number | null = null;

  static readonly PROBLEM_COUNT = 10;
  static readonly GAME_TIME = 60000; // 60초

  constructor() {
    this.problems = this.generateProblems();
  }

  private generateProblems(): Problem[] {
    const operators = ['+', '-', '×', '÷'];
    const problems: Problem[] = [];

    for (let i = 0; i < MathRaceGame.PROBLEM_COUNT; i++) {
      const op = operators[Math.floor(Math.random() * operators.length)];
      problems.push(this.generateProblem(op));
    }

    return problems;
  }

  private generateProblem(operator: string): Problem {
    switch (operator) {
      case '+': {
        const num1 = this.randInt(10, 99);
        const num2 = this.randInt(10, 99);
        return { num1, num2, operator, answer: num1 + num2 };
      }
      case '-': {
        let a = this.randInt(10, 99);
        let b = this.randInt(10, 99);
        if (a < b) [a, b] = [b, a];
        return { num1: a, num2: b, operator, answer: a - b };
      }
      case '×': {
        const num1 = this.randInt(2, 9);
        const num2 = this.randInt(2, 9);
        return { num1, num2, operator, answer: num1 * num2 };
      }
      case '÷': {
        const answer = this.randInt(2, 9);
        const divisor = this.randInt(2, 9);
        const num1 = answer * divisor;
        return { num1, num2: divisor, operator, answer };
      }
      default:
        return { num1: 1, num2: 1, operator: '+', answer: 2 };
    }
  }

  private randInt(min: number, max: number): number {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  getProblems(): Problem[] {
    return this.problems.map(p => ({ ...p }));
  }

  getProblemsForClient(): { num1: number; num2: number; operator: string }[] {
    return this.problems.map(({ num1, num2, operator }) => ({ num1, num2, operator }));
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

  checkAnswer(playerIndex: number, problemIndex: number, answer: number): { correct: boolean; progress: [number, number]; gameOver: boolean } {
    if (this.gameOver) {
      return { correct: false, progress: this.getProgress(), gameOver: true };
    }

    if (problemIndex !== this.progress[playerIndex]) {
      return { correct: false, progress: this.getProgress(), gameOver: false };
    }

    if (answer !== this.problems[problemIndex].answer) {
      return { correct: false, progress: this.getProgress(), gameOver: false };
    }

    this.progress[playerIndex]++;

    if (this.progress[playerIndex] >= MathRaceGame.PROBLEM_COUNT) {
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

  reset(): void {
    this.problems = this.generateProblems();
    this.progress = [0, 0];
    this.gameOver = false;
    this.winner = null;
  }
}
