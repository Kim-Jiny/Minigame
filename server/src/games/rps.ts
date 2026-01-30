/**
 * 가위바위보 게임
 *
 * 규칙:
 * - 3판 2선승
 * - 동시에 선택 후 결과 공개
 * - 가위 > 보, 보 > 바위, 바위 > 가위
 * - 비기면 재시도 (라운드 카운트 안함)
 */

export type RpsChoice = 'rock' | 'paper' | 'scissors' | null;

export interface RpsRoundResult {
  round: number;
  player0Choice: RpsChoice;
  player1Choice: RpsChoice;
  winnerId: string | null;
  isDraw: boolean;
}

export class RpsGame {
  private scores: [number, number] = [0, 0]; // [player0, player1]
  private currentRound: number = 0;
  private choices: [RpsChoice, RpsChoice] = [null, null];
  private roundResults: RpsRoundResult[] = [];
  private gameOver: boolean = false;

  static readonly WIN_SCORE = 2; // 2승 먼저 하면 승리
  static readonly MAX_ROUNDS = 3; // 최대 3라운드

  constructor() {
    this.reset();
  }

  getScores(): [number, number] {
    return [...this.scores] as [number, number];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getChoices(): [RpsChoice, RpsChoice] {
    return [...this.choices] as [RpsChoice, RpsChoice];
  }

  getRoundResults(): RpsRoundResult[] {
    return [...this.roundResults];
  }

  // 새 라운드 시작
  startRound(): void {
    this.currentRound++;
    this.choices = [null, null];
  }

  // 플레이어가 선택했을 때
  makeChoice(playerIndex: number, choice: RpsChoice): {
    valid: boolean;
    bothChosen: boolean;
  } {
    if (this.gameOver) {
      return { valid: false, bothChosen: false };
    }

    if (choice !== 'rock' && choice !== 'paper' && choice !== 'scissors') {
      return { valid: false, bothChosen: false };
    }

    // 이미 선택했으면 무시
    if (this.choices[playerIndex] !== null) {
      return { valid: false, bothChosen: false };
    }

    this.choices[playerIndex] = choice;

    // 둘 다 선택했는지 확인
    const bothChosen = this.choices[0] !== null && this.choices[1] !== null;

    return { valid: true, bothChosen };
  }

  // 라운드 결과 계산
  calculateRoundResult(): {
    player0Choice: RpsChoice;
    player1Choice: RpsChoice;
    roundWinner: number | null; // 0, 1, or null (draw)
    isDraw: boolean;
    gameOver: boolean;
    gameWinner: number | null;
  } {
    const p0 = this.choices[0]!;
    const p1 = this.choices[1]!;

    let roundWinner: number | null = null;
    let isDraw = false;

    if (p0 === p1) {
      // 비김
      isDraw = true;
    } else if (
      (p0 === 'rock' && p1 === 'scissors') ||
      (p0 === 'scissors' && p1 === 'paper') ||
      (p0 === 'paper' && p1 === 'rock')
    ) {
      // player0 승리
      roundWinner = 0;
      this.scores[0]++;
    } else {
      // player1 승리
      roundWinner = 1;
      this.scores[1]++;
    }

    this.roundResults.push({
      round: this.currentRound,
      player0Choice: p0,
      player1Choice: p1,
      winnerId: null, // 나중에 소켓 ID로 설정
      isDraw,
    });

    // 게임 종료 확인
    const gameOver = this.checkGameOver();
    this.gameOver = gameOver;

    return {
      player0Choice: p0,
      player1Choice: p1,
      roundWinner,
      isDraw,
      gameOver,
      gameWinner: gameOver ? this.getWinner() : null,
    };
  }

  // 게임 종료 여부 확인
  private checkGameOver(): boolean {
    // 2승 먼저 달성하면 승리
    if (this.scores[0] >= RpsGame.WIN_SCORE || this.scores[1] >= RpsGame.WIN_SCORE) {
      return true;
    }
    return false;
  }

  // 승자 확인
  getWinner(): number | null {
    if (this.scores[0] >= RpsGame.WIN_SCORE) return 0;
    if (this.scores[1] >= RpsGame.WIN_SCORE) return 1;
    return null;
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  // 플레이어가 선택했는지 확인
  hasChosen(playerIndex: number): boolean {
    return this.choices[playerIndex] !== null;
  }

  // 타임아웃 시 강제 승리 처리
  forceWin(winnerIndex: number): void {
    this.scores[winnerIndex]++;
    if (this.scores[winnerIndex] >= RpsGame.WIN_SCORE) {
      this.gameOver = true;
    }
  }

  reset(): void {
    this.scores = [0, 0];
    this.currentRound = 0;
    this.choices = [null, null];
    this.roundResults = [];
    this.gameOver = false;
  }
}
