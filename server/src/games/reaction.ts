/**
 * 반응속도 게임 (신호등 게임)
 *
 * 규칙:
 * - 5라운드 진행, 먼저 3점 획득 시 승리
 * - 랜덤 시간(1.5~4초) 후 빨간불 → 초록불
 * - 초록불에 먼저 누르면 1점
 * - 빨간불에 누르면 부정출발 → 상대방 1점
 */

export type RoundState = 'waiting' | 'ready' | 'go' | 'finished';

export interface RoundResult {
  round: number;
  winnerId: string | null;
  falseStart: boolean;
  reactionTime?: number;
}

export class ReactionGame {
  private scores: [number, number] = [0, 0]; // [player0, player1]
  private currentRound: number = 0;
  private roundState: RoundState = 'waiting';
  private goTime: number | null = null; // 초록불이 켜진 시간
  private roundResults: RoundResult[] = [];
  private pressedPlayers: Set<number> = new Set(); // 이번 라운드에 누른 플레이어

  static readonly MAX_ROUNDS = 5;
  static readonly WIN_SCORE = 3;
  static readonly MIN_DELAY = 1500; // 최소 대기 시간 (ms)
  static readonly MAX_DELAY = 4000; // 최대 대기 시간 (ms)

  constructor() {
    this.reset();
  }

  getScores(): [number, number] {
    return [...this.scores] as [number, number];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getRoundState(): RoundState {
    return this.roundState;
  }

  getRoundResults(): RoundResult[] {
    return [...this.roundResults];
  }

  // 새 라운드 시작 준비 (ready 상태로)
  startRound(): { delay: number } {
    this.currentRound++;
    this.roundState = 'ready';
    this.goTime = null;
    this.pressedPlayers.clear();

    // 랜덤 대기 시간
    const delay = Math.floor(
      Math.random() * (ReactionGame.MAX_DELAY - ReactionGame.MIN_DELAY) + ReactionGame.MIN_DELAY
    );

    return { delay };
  }

  // 초록불 켜기 (go 상태로)
  setGo(): void {
    this.roundState = 'go';
    this.goTime = Date.now();
  }

  // 플레이어가 버튼을 눌렀을 때
  playerPressed(playerIndex: number): {
    valid: boolean;
    falseStart: boolean;
    reactionTime?: number;
    roundWinner?: number;
    roundOver: boolean;
    gameOver: boolean;
    winner?: number;
  } {
    // 이미 이번 라운드에 눌렀으면 무시
    if (this.pressedPlayers.has(playerIndex)) {
      return { valid: false, falseStart: false, roundOver: false, gameOver: false };
    }

    // 라운드가 진행 중이 아니면 무시
    if (this.roundState !== 'ready' && this.roundState !== 'go') {
      return { valid: false, falseStart: false, roundOver: false, gameOver: false };
    }

    this.pressedPlayers.add(playerIndex);

    // 부정출발 (빨간불일 때 누름)
    if (this.roundState === 'ready') {
      const opponentIndex = playerIndex === 0 ? 1 : 0;
      this.scores[opponentIndex]++;

      this.roundResults.push({
        round: this.currentRound,
        winnerId: null, // 부정출발은 winnerId를 나중에 설정
        falseStart: true,
      });

      this.roundState = 'finished';

      const gameOver = this.checkGameOver();
      return {
        valid: true,
        falseStart: true,
        roundWinner: opponentIndex,
        roundOver: true,
        gameOver,
        winner: gameOver ? (this.getWinner() ?? undefined) : undefined,
      };
    }

    // 정상 터치 (초록불일 때 누름)
    const reactionTime = Date.now() - this.goTime!;
    this.scores[playerIndex]++;

    this.roundResults.push({
      round: this.currentRound,
      winnerId: null, // 나중에 소켓 ID로 설정
      falseStart: false,
      reactionTime,
    });

    this.roundState = 'finished';

    const gameOver2 = this.checkGameOver();
    return {
      valid: true,
      falseStart: false,
      reactionTime,
      roundWinner: playerIndex,
      roundOver: true,
      gameOver: gameOver2,
      winner: gameOver2 ? (this.getWinner() ?? undefined) : undefined,
    };
  }

  // 게임 종료 여부 확인
  private checkGameOver(): boolean {
    // 3점 먼저 달성하면 승리
    if (this.scores[0] >= ReactionGame.WIN_SCORE || this.scores[1] >= ReactionGame.WIN_SCORE) {
      return true;
    }
    // 5라운드 모두 진행했으면 종료
    if (this.currentRound >= ReactionGame.MAX_ROUNDS) {
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
    this.roundState = 'waiting';
    this.goTime = null;
    this.roundResults = [];
    this.pressedPlayers.clear();
  }
}
