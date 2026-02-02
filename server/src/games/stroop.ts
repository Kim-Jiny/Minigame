/**
 * 스트룹(Stroop) 게임
 *
 * 규칙:
 * - 색상 단어가 다른 색으로 표시됨 (예: "빨강" 글자가 파란색으로)
 * - 플레이어는 글자색(단어 내용이 아닌)을 빠르게 선택
 * - 먼저 맞힌 플레이어가 점수 획득
 * - 틀리면 상대방에게 점수
 * - 3점 선취 시 승리 (최대 5라운드)
 *
 * 하드코어 모드:
 * - 6가지 색상: + 주황, 보라
 * - 표시 시간 제한 (2초 후 자동 틀림)
 */

export type StroopRoundState = 'waiting' | 'showing' | 'finished';

export interface StroopRoundResult {
  round: number;
  winnerId: string | null;
  word: string;
  color: string;
  correctAnswer: string;
  player0Correct: boolean | null;
  player1Correct: boolean | null;
}

export class StroopGame {
  // 색상 목록
  static readonly COLORS_NORMAL = ['red', 'blue', 'green', 'yellow'];
  static readonly COLORS_HARDCORE = ['red', 'blue', 'green', 'yellow', 'orange', 'purple'];
  static readonly WIN_SCORE = 3;
  static readonly MAX_ROUNDS = 5;
  static readonly TIME_LIMIT_HARDCORE = 2000; // ms

  private scores: [number, number] = [0, 0];
  private currentRound: number = 0;
  private currentWord: string = '';   // 표시되는 단어 (예: 'red')
  private currentColor: string = '';  // 실제 글자색 (예: 'blue')
  private roundState: StroopRoundState = 'waiting';
  private playerAnswered: [boolean, boolean] = [false, false];
  private playerCorrect: [boolean | null, boolean | null] = [null, null];
  private roundResults: StroopRoundResult[] = [];
  private isHardcore: boolean;

  constructor(isHardcore: boolean = false) {
    this.isHardcore = isHardcore;
    this.reset();
  }

  getScores(): [number, number] {
    return [...this.scores] as [number, number];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getRoundState(): StroopRoundState {
    return this.roundState;
  }

  getCurrentWord(): string {
    return this.currentWord;
  }

  getCurrentColor(): string {
    return this.currentColor;
  }

  getRoundResults(): StroopRoundResult[] {
    return [...this.roundResults];
  }

  getIsHardcore(): boolean {
    return this.isHardcore;
  }

  getColors(): string[] {
    return this.isHardcore ? StroopGame.COLORS_HARDCORE : StroopGame.COLORS_NORMAL;
  }

  // 새 라운드 시작 - 자극 생성
  startRound(): { word: string; color: string; round: number } {
    this.currentRound++;
    this.roundState = 'showing';
    this.playerAnswered = [false, false];
    this.playerCorrect = [null, null];

    const colors = this.getColors();

    // 랜덤 단어 선택
    const wordIndex = Math.floor(Math.random() * colors.length);
    this.currentWord = colors[wordIndex];

    // 다른 색상 선택 (글자색 ≠ 단어)
    let colorIndex = Math.floor(Math.random() * colors.length);
    while (colorIndex === wordIndex) {
      colorIndex = Math.floor(Math.random() * colors.length);
    }
    this.currentColor = colors[colorIndex];

    return {
      word: this.currentWord,
      color: this.currentColor,
      round: this.currentRound,
    };
  }

  // 플레이어 응답 처리
  playerAnswer(playerIndex: number, selectedColor: string): {
    valid: boolean;
    correct: boolean;
    first: boolean;
    roundWinner: number | null;
    roundOver: boolean;
    gameOver: boolean;
    winner?: number;
  } {
    // 이미 답변했거나 라운드가 진행 중이 아님
    if (this.playerAnswered[playerIndex] || this.roundState !== 'showing') {
      return { valid: false, correct: false, first: false, roundWinner: null, roundOver: false, gameOver: false };
    }

    const isFirst = !this.playerAnswered[0] && !this.playerAnswered[1];
    this.playerAnswered[playerIndex] = true;

    // 정답 확인 (글자색이 정답)
    const isCorrect = selectedColor === this.currentColor;
    this.playerCorrect[playerIndex] = isCorrect;

    let roundWinner: number | null = null;
    let roundOver = false;

    if (isCorrect && isFirst) {
      // 먼저 맞힘 → 점수 획득
      this.scores[playerIndex]++;
      roundWinner = playerIndex;
      roundOver = true;
    } else if (!isCorrect) {
      // 틀림 → 상대방 점수
      const opponentIndex = playerIndex === 0 ? 1 : 0;
      this.scores[opponentIndex]++;
      roundWinner = opponentIndex;
      roundOver = true;
    }

    // 두 번째 답변인 경우 (먼저 맞힌 사람 없이)
    if (!roundOver && this.playerAnswered[0] && this.playerAnswered[1]) {
      // 둘 다 틀렸거나, 두 번째 사람이 맞힘 (하지만 먼저가 아님 - 이 케이스는 위에서 처리됨)
      roundOver = true;
    }

    if (roundOver) {
      this.roundState = 'finished';
      this.roundResults.push({
        round: this.currentRound,
        winnerId: null, // 나중에 소켓 ID로 설정
        word: this.currentWord,
        color: this.currentColor,
        correctAnswer: this.currentColor,
        player0Correct: this.playerCorrect[0],
        player1Correct: this.playerCorrect[1],
      });
    }

    const gameOver = this.checkGameOver();
    return {
      valid: true,
      correct: isCorrect,
      first: isFirst && isCorrect,
      roundWinner,
      roundOver,
      gameOver,
      winner: gameOver ? (this.getWinner() ?? undefined) : undefined,
    };
  }

  // 타임아웃 처리 (하드코어 모드)
  handleTimeout(): {
    roundOver: boolean;
    gameOver: boolean;
    roundWinner: number | null;
  } {
    if (this.roundState !== 'showing') {
      return { roundOver: false, gameOver: false, roundWinner: null };
    }

    // 답변 안 한 플레이어는 틀린 것으로 처리
    let roundWinner: number | null = null;

    if (!this.playerAnswered[0] && !this.playerAnswered[1]) {
      // 둘 다 답변 안 함 - 무득점
    } else if (!this.playerAnswered[0]) {
      // 플레이어 0만 답변 안 함 - 플레이어 1 점수 (단, 1이 맞힌 경우)
      if (this.playerCorrect[1] === true) {
        this.scores[1]++;
        roundWinner = 1;
      }
    } else if (!this.playerAnswered[1]) {
      // 플레이어 1만 답변 안 함 - 플레이어 0 점수 (단, 0이 맞힌 경우)
      if (this.playerCorrect[0] === true) {
        this.scores[0]++;
        roundWinner = 0;
      }
    }

    this.roundState = 'finished';
    this.roundResults.push({
      round: this.currentRound,
      winnerId: null,
      word: this.currentWord,
      color: this.currentColor,
      correctAnswer: this.currentColor,
      player0Correct: this.playerCorrect[0],
      player1Correct: this.playerCorrect[1],
    });

    const gameOver = this.checkGameOver();
    return { roundOver: true, gameOver, roundWinner };
  }

  // 게임 종료 여부 확인
  private checkGameOver(): boolean {
    // 3점 먼저 달성하면 승리
    if (this.scores[0] >= StroopGame.WIN_SCORE || this.scores[1] >= StroopGame.WIN_SCORE) {
      return true;
    }
    // 5라운드 모두 진행했으면 종료
    if (this.currentRound >= StroopGame.MAX_ROUNDS) {
      return true;
    }
    return false;
  }

  // 승자 확인
  getWinner(): number | null {
    if (this.scores[0] > this.scores[1]) return 0;
    if (this.scores[1] > this.scores[0]) return 1;
    return null; // 무승부
  }

  isGameOver(): boolean {
    return this.checkGameOver();
  }

  reset(): void {
    this.scores = [0, 0];
    this.currentRound = 0;
    this.currentWord = '';
    this.currentColor = '';
    this.roundState = 'waiting';
    this.playerAnswered = [false, false];
    this.playerCorrect = [null, null];
    this.roundResults = [];
  }
}
