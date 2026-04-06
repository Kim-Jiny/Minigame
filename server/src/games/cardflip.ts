/**
 * 카드 뒤집기 게임
 *
 * 규칙:
 * - 4x5 = 20장, 10쌍 (동물 이모지 10종)
 * - 턴제: 현재 턴 플레이어가 2장을 뒤집음
 *   - 짝 맞음 → +1점, 같은 플레이어가 연속 턴
 *   - 짝 안 맞음 → 카드 다시 뒤집힘, 상대 턴
 * - 턴 타임아웃(10초): 뒤집은 카드 원복, 상대 턴
 * - 10쌍 모두 찾으면 종료 → 점수 높은 쪽 승리 (5:5 무승부)
 */

export class CardFlipGame {
  static readonly GRID_ROWS = 4;
  static readonly GRID_COLS = 5;
  static readonly TOTAL_CARDS = 20;
  static readonly TOTAL_PAIRS = 10;
  static readonly TURN_TIME = 10000; // 10초
  static readonly FLIP_DELAY = 1500; // 불일치 시 카드 보여주는 시간

  static readonly SYMBOLS = [
    '🐱', '🐶', '🐰', '🐻', '🐼',
    '🐨', '🦊', '🐯', '🦁', '🐸',
  ];

  private cards: string[] = [];
  private matched: boolean[] = [];
  private scores: [number, number] = [0, 0];
  private currentTurn: number = 0;
  private flippedCards: number[] = [];
  private gameOver: boolean = false;
  private winner: number | null = null;

  constructor() {
    this.cards = this.generateCards();
    this.matched = new Array(CardFlipGame.TOTAL_CARDS).fill(false);
  }

  private generateCards(): string[] {
    // 10쌍 = 20장
    const cards = [...CardFlipGame.SYMBOLS, ...CardFlipGame.SYMBOLS];
    // Fisher-Yates 셔플
    for (let i = cards.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [cards[i], cards[j]] = [cards[j], cards[i]];
    }
    return cards;
  }

  getCards(): string[] {
    return [...this.cards];
  }

  getMatched(): boolean[] {
    return [...this.matched];
  }

  getScores(): [number, number] {
    return [...this.scores] as [number, number];
  }

  getCurrentTurn(): number {
    return this.currentTurn;
  }

  getFlippedCards(): number[] {
    return [...this.flippedCards];
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  getWinner(): number | null {
    return this.winner;
  }

  flipCard(playerIndex: number, position: number): {
    valid: boolean;
    symbol?: string;
    isSecondFlip?: boolean;
  } {
    if (this.gameOver) return { valid: false };
    if (playerIndex !== this.currentTurn) return { valid: false };
    if (position < 0 || position >= CardFlipGame.TOTAL_CARDS) return { valid: false };
    if (this.matched[position]) return { valid: false };
    if (this.flippedCards.includes(position)) return { valid: false };
    if (this.flippedCards.length >= 2) return { valid: false };

    this.flippedCards.push(position);
    const symbol = this.cards[position];
    const isSecondFlip = this.flippedCards.length === 2;

    return { valid: true, symbol, isSecondFlip };
  }

  checkMatch(): { matched: boolean; nextTurn: number; gameOver: boolean } {
    if (this.flippedCards.length !== 2) {
      return { matched: false, nextTurn: this.currentTurn, gameOver: false };
    }

    const [pos1, pos2] = this.flippedCards;
    const isMatch = this.cards[pos1] === this.cards[pos2];

    if (isMatch) {
      this.matched[pos1] = true;
      this.matched[pos2] = true;
      this.scores[this.currentTurn]++;
      this.flippedCards = [];

      // 10쌍 모두 찾으면 게임 종료
      if (this.scores[0] + this.scores[1] >= CardFlipGame.TOTAL_PAIRS) {
        this.gameOver = true;
        if (this.scores[0] > this.scores[1]) {
          this.winner = 0;
        } else if (this.scores[1] > this.scores[0]) {
          this.winner = 1;
        } else {
          this.winner = null; // 무승부
        }
      }

      return { matched: true, nextTurn: this.currentTurn, gameOver: this.gameOver };
    }

    // 불일치 - 턴 전환 (clearFlipped에서 실제로 처리)
    return { matched: false, nextTurn: 1 - this.currentTurn, gameOver: false };
  }

  clearFlipped(): void {
    this.flippedCards = [];
    this.currentTurn = 1 - this.currentTurn;
  }

  handleTimeout(): { positions: number[]; nextTurn: number } {
    const positions = [...this.flippedCards];
    this.flippedCards = [];
    this.currentTurn = 1 - this.currentTurn;
    return { positions, nextTurn: this.currentTurn };
  }

  getState(): {
    matched: boolean[];
    scores: [number, number];
    currentTurn: number;
    flippedCards: number[];
    flippedSymbols: string[];
    gameOver: boolean;
  } {
    return {
      matched: this.getMatched(),
      scores: this.getScores(),
      currentTurn: this.currentTurn,
      flippedCards: [...this.flippedCards],
      flippedSymbols: this.flippedCards.map(pos => this.cards[pos]),
      gameOver: this.gameOver,
    };
  }

  reset(): void {
    this.cards = this.generateCards();
    this.matched = new Array(CardFlipGame.TOTAL_CARDS).fill(false);
    this.scores = [0, 0];
    this.currentTurn = 0;
    this.flippedCards = [];
    this.gameOver = false;
    this.winner = null;
  }
}
