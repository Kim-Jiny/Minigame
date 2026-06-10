/**
 * Set (셋) 게임 — 실시간 1:1 단판
 *
 * 규칙:
 * - 카드 81장(= 3^4). 4속성(개수/모양/채움/색) 각 3값.
 *   카드 id(0~80) = number*27 + shape*9 + fill*3 + color  (각 0~2)
 * - 공용 보드 12장. 둘이 동시에 "세트"(카드 3장)를 찾아 외친다.
 * - 세트: 4속성 각각이 "셋 다 같음" 또는 "셋 다 다름". (속성합 % 3 === 0)
 * - 유효한 세트를 먼저 집으면 +1점, 보드에서 제거 후 덱에서 보충.
 * - 보드에 세트가 하나도 없으면 3장 추가(최대 21장).
 *   수학적으로 21장이면 반드시 세트가 존재한다(세트 없는 최대 조합 = 20장).
 * - 먼저 SCORE_TO_WIN 점에 도달하거나, 덱 소진 + 보드에 세트 없음이면 종료.
 *   종료 시 점수 높은 쪽 승리(동점 무승부). 제한시간 종료 시에도 점수로 판정.
 */

export interface SetClaimResult {
  valid: boolean;
  reason?: 'not_on_board' | 'not_a_set' | 'game_over' | 'bad_input';
  board?: number[];
  scores?: [number, number];
  deckRemaining?: number;
  claimedCards?: number[]; // 방금 집은 카드 id (애니메이션용)
}

export class SetGame {
  static readonly TOTAL_CARDS = 81;
  static readonly BOARD_SIZE = 12;
  static readonly MAX_BOARD = 21; // 21장이면 세트 존재가 수학적으로 보장됨
  static readonly SCORE_TO_WIN = 6;
  static readonly GAME_TIME = 120000; // 120초 단판

  private deck: number[] = [];
  private board: number[] = [];
  private scores: [number, number] = [0, 0];
  private gameOver = false;
  private winner: number | null = null;

  constructor() {
    this.reset();
  }

  reset(): void {
    this.deck = Array.from({ length: SetGame.TOTAL_CARDS }, (_, i) => i);
    for (let i = this.deck.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [this.deck[i], this.deck[j]] = [this.deck[j], this.deck[i]];
    }
    this.board = [];
    for (let i = 0; i < SetGame.BOARD_SIZE && this.deck.length > 0; i++) {
      this.board.push(this.deck.pop()!);
    }
    this.scores = [0, 0];
    this.gameOver = false;
    this.winner = null;
    this.ensureSetExists();
  }

  // ---- 속성/세트 판정 ----
  private static attrs(id: number): [number, number, number, number] {
    return [
      Math.floor(id / 27) % 3, // number
      Math.floor(id / 9) % 3, // shape
      Math.floor(id / 3) % 3, // fill
      id % 3, // color
    ];
  }

  static isSet(a: number, b: number, c: number): boolean {
    const A = SetGame.attrs(a);
    const B = SetGame.attrs(b);
    const C = SetGame.attrs(c);
    for (let k = 0; k < 4; k++) {
      if ((A[k] + B[k] + C[k]) % 3 !== 0) return false;
    }
    return true;
  }

  private boardHasSet(): boolean {
    const n = this.board.length;
    for (let i = 0; i < n - 2; i++) {
      for (let j = i + 1; j < n - 1; j++) {
        for (let k = j + 1; k < n; k++) {
          if (SetGame.isSet(this.board[i], this.board[j], this.board[k])) return true;
        }
      }
    }
    return false;
  }

  private ensureSetExists(): void {
    // 보드에 세트가 없으면 덱에서 3장씩 추가(최대 18장)
    while (
      !this.boardHasSet() &&
      this.deck.length >= 3 &&
      this.board.length < SetGame.MAX_BOARD
    ) {
      for (let i = 0; i < 3; i++) this.board.push(this.deck.pop()!);
    }
  }

  // ---- getter ----
  getBoard(): number[] {
    return [...this.board];
  }
  getScores(): [number, number] {
    return [...this.scores] as [number, number];
  }
  getDeckRemaining(): number {
    return this.deck.length;
  }
  getWinner(): number | null {
    return this.winner;
  }
  isGameOver(): boolean {
    return this.gameOver;
  }

  /**
   * 카드 id 3장으로 세트 클레임. 인덱스가 아니라 id로 받아 경합(인덱스 밀림)을 피한다.
   */
  claim(playerIndex: number, cardIds: number[]): SetClaimResult {
    if (this.gameOver) return { valid: false, reason: 'game_over' };
    if (
      !Array.isArray(cardIds) ||
      cardIds.length !== 3 ||
      new Set(cardIds).size !== 3
    ) {
      return { valid: false, reason: 'bad_input' };
    }
    // 3장 모두 현재 보드에 있어야 함
    const positions = cardIds.map((id) => this.board.indexOf(id));
    if (positions.some((p) => p < 0)) {
      return { valid: false, reason: 'not_on_board' };
    }
    if (!SetGame.isSet(cardIds[0], cardIds[1], cardIds[2])) {
      return { valid: false, reason: 'not_a_set' };
    }

    // 유효 — 점수 + 카드 제거/보충
    this.scores[playerIndex]++;

    // 보드가 12장 초과(추가된 상태)면 제거만, 12장이면 덱에서 보충
    const overflow = this.board.length > SetGame.BOARD_SIZE;
    const removeSet = new Set(cardIds);
    this.board = this.board.filter((id) => !removeSet.has(id));
    if (!overflow) {
      while (this.board.length < SetGame.BOARD_SIZE && this.deck.length > 0) {
        this.board.push(this.deck.pop()!);
      }
    }
    this.ensureSetExists();

    // 종료 판정
    if (this.scores[playerIndex] >= SetGame.SCORE_TO_WIN) {
      this.gameOver = true;
      this.winner = playerIndex;
    } else if (this.deck.length === 0 && !this.boardHasSet()) {
      this.finalizeByScore();
    }

    return {
      valid: true,
      board: this.getBoard(),
      scores: this.getScores(),
      deckRemaining: this.getDeckRemaining(),
      claimedCards: [...cardIds],
    };
  }

  private finalizeByScore(): void {
    this.gameOver = true;
    if (this.scores[0] > this.scores[1]) this.winner = 0;
    else if (this.scores[1] > this.scores[0]) this.winner = 1;
    else this.winner = null;
  }

  // 제한시간 종료 시 서버에서 호출 — 점수로 판정
  setGameOver(): void {
    if (this.gameOver) return;
    this.finalizeByScore();
  }
}
