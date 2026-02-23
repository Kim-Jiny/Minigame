/**
 * 헥사곤(Hexagon) 게임 - 데블스 플랜 스타일
 *
 * 규칙:
 * - 19칸 육각형 보드에 숫자(앞면) + 알파벳(뒷면)
 * - 30초간 숫자를 암기한 뒤 뒷면(알파벳)으로 뒤집힘
 * - 타겟 넘버가 주어지고, 일직선 3칸의 숫자 합이 타겟이 되는 조합을 찾음
 * - 누구든 먼저 버저 → 10초 이내에 알파벳으로 선언
 * - 정답 +1, 오답 -1
 * - 60초간 무도전 시 라운드 종료
 *
 * 모드:
 * - 솔로 (랭킹 도전): 최대 10라운드
 * - 대전 (2인): 기본 3라운드, 동점 시 추가 라운드
 */

export type HexagonRoundState = 'waiting' | 'memorizing' | 'playing' | 'buzzing' | 'finished';

export interface HexagonCell {
  number: number;
  letter: string;
}

export interface FoundCombination {
  cells: number[];       // 셀 인덱스 3개
  letters: string;       // 알파벳 조합 (예: "ABC")
  playerIndex: number;   // 찾은 플레이어
}

export interface HexagonRoundResult {
  round: number;
  targetNumber: number;
  board: HexagonCell[];
  foundCombinations: FoundCombination[];
  totalCombinations: number;
}

/**
 * 19칸 헥사곤 보드 레이아웃:
 *      [0] [1] [2]         row 0: 3칸
 *    [3] [4] [5] [6]       row 1: 4칸
 *  [7] [8] [9] [10] [11]   row 2: 5칸
 *    [12] [13] [14] [15]   row 3: 4칸
 *      [16] [17] [18]      row 4: 3칸
 *
 * 인접 규칙 (상반부 넓어짐, 하반부 좁아짐):
 *   상반부 (row < 2): 아래-왼 = (r+1, c), 아래-오른 = (r+1, c+1)
 *   하반부 (row >= 2): 아래-왼 = (r+1, c-1), 아래-오른 = (r+1, c)
 */

// 일직선 3칸 조합 27개 (가로 9 + 대각선\ 9 + 대각선/ 9)
const ALL_LINES: number[][] = [
  // 가로 (→) - 9개
  [0, 1, 2],
  [3, 4, 5], [4, 5, 6],
  [7, 8, 9], [8, 9, 10], [9, 10, 11],
  [12, 13, 14], [13, 14, 15],
  [16, 17, 18],
  // 대각선 \ (아래-왼) - 9개
  [0, 3, 7],   [1, 4, 8],   [2, 5, 9],     // row 0→1→2
  [4, 8, 12],  [5, 9, 13],  [6, 10, 14],   // row 1→2→3
  [9, 13, 16], [10, 14, 17], [11, 15, 18], // row 2→3→4
  // 대각선 / (아래-오른) - 9개
  [0, 4, 9],   [1, 5, 10],  [2, 6, 11],    // row 0→1→2
  [3, 8, 13],  [4, 9, 14],  [5, 10, 15],   // row 1→2→3
  [7, 12, 16], [8, 13, 17], [9, 14, 18],   // row 2→3→4
];

// 알파벳 19개 (A~S)
const LETTERS = 'ABCDEFGHIJKLMNOPQRS'.split('');

export class HexagonGame {
  static readonly MEMORIZE_TIME = 30000;     // 30초 암기
  static readonly BUZZ_TIME_LIMIT = 10000;   // 10초 답변 시간
  static readonly ROUND_IDLE_TIMEOUT = 60000; // 60초 무도전 시 라운드 종료
  static readonly SKIP_AVAILABLE_TIME = 20000; // 20초 무도전 시 라운드 넘기기 활성화
  static readonly MAX_ROUNDS_SOLO = 10;
  static readonly MAX_ROUNDS_MULTI = 3;
  static readonly MIN_NUMBER = 1;
  static readonly MAX_NUMBER = 9;

  private board: HexagonCell[] = [];
  private scores: number[] = [];
  private currentRound: number = 0;
  private roundState: HexagonRoundState = 'waiting';
  private targetNumber: number = 0;
  private validCombinations: number[][] = [];
  private foundCombinations: FoundCombination[] = [];
  private roundResults: HexagonRoundResult[] = [];
  private isSolo: boolean;
  private playerCount: number;
  private buzzingPlayer: number | null = null;

  constructor(isSolo: boolean = false) {
    this.isSolo = isSolo;
    this.playerCount = isSolo ? 1 : 2;
    this.scores = new Array(this.playerCount).fill(0);
  }

  getBoard(): HexagonCell[] {
    return this.board.map(c => ({ ...c }));
  }

  getLettersOnly(): string[] {
    return this.board.map(c => c.letter);
  }

  getScores(): number[] {
    return [...this.scores];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getRoundState(): HexagonRoundState {
    return this.roundState;
  }

  getTargetNumber(): number {
    return this.targetNumber;
  }

  getFoundCombinations(): FoundCombination[] {
    return this.foundCombinations.map(fc => ({ ...fc }));
  }

  getRoundResults(): HexagonRoundResult[] {
    return [...this.roundResults];
  }

  getIsSolo(): boolean {
    return this.isSolo;
  }

  getBuzzingPlayer(): number | null {
    return this.buzzingPlayer;
  }

  getMaxRounds(): number {
    return this.isSolo ? HexagonGame.MAX_ROUNDS_SOLO : HexagonGame.MAX_ROUNDS_MULTI;
  }

  getValidCombinationCount(): number {
    return this.validCombinations.length;
  }

  getRemainingCombinationCount(): number {
    const foundKeys = new Set(
      this.foundCombinations.map(fc => [...fc.cells].sort((a, b) => a - b).join(','))
    );
    return this.validCombinations.filter(vc => {
      const key = [...vc].sort((a, b) => a - b).join(',');
      return !foundKeys.has(key);
    }).length;
  }

  // 새 라운드 시작
  startRound(): {
    board: HexagonCell[];
    targetNumber: number;
    round: number;
    totalCombinations: number;
  } {
    this.currentRound++;
    this.roundState = 'memorizing';
    this.buzzingPlayer = null;
    this.foundCombinations = [];
    this.generateBoard();

    return {
      board: this.getBoard(),
      targetNumber: this.targetNumber,
      round: this.currentRound,
      totalCombinations: this.validCombinations.length,
    };
  }

  // 암기 시간 종료 → 플레이 상태
  startPlaying(): { letters: string[] } {
    this.roundState = 'playing';
    return { letters: this.getLettersOnly() };
  }

  // 버저 누르기
  buzz(playerIndex: number): { valid: boolean; alreadyBuzzing: boolean } {
    if (this.roundState !== 'playing') {
      return { valid: false, alreadyBuzzing: false };
    }
    if (this.buzzingPlayer !== null) {
      return { valid: false, alreadyBuzzing: true };
    }
    this.buzzingPlayer = playerIndex;
    this.roundState = 'buzzing';
    return { valid: true, alreadyBuzzing: false };
  }

  // 답변 제출 (셀 인덱스 3개)
  submitAnswer(playerIndex: number, cellIndices: number[]): {
    valid: boolean;
    correct: boolean;
    letters: string;
    alreadyFound: boolean;
    scores: number[];
    remainingCombinations: number;
  } {
    const defaultResult = {
      valid: false, correct: false, letters: '', alreadyFound: false,
      scores: this.getScores(), remainingCombinations: this.getRemainingCombinationCount(),
    };

    if (this.roundState !== 'buzzing' || this.buzzingPlayer !== playerIndex) {
      return defaultResult;
    }

    // 인덱스 유효성 검사
    if (cellIndices.length !== 3 || cellIndices.some(i => i < 0 || i >= 19)) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true, correct: false, letters: '', alreadyFound: false,
        scores: this.getScores(), remainingCombinations: this.getRemainingCombinationCount(),
      };
    }

    const sorted = [...cellIndices].sort((a, b) => a - b);
    const key = sorted.join(',');
    const letters = cellIndices.map(i => this.board[i].letter).join('');

    // 이미 찾은 조합인지 확인
    const alreadyFound = this.foundCombinations.some(
      fc => [...fc.cells].sort((a, b) => a - b).join(',') === key
    );

    if (alreadyFound) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true, correct: false, letters, alreadyFound: true,
        scores: this.getScores(), remainingCombinations: this.getRemainingCombinationCount(),
      };
    }

    // 정답 확인
    const isValidLine = this.validCombinations.some(
      vc => [...vc].sort((a, b) => a - b).join(',') === key
    );

    if (isValidLine) {
      this.scores[playerIndex]++;
      this.foundCombinations.push({ cells: cellIndices, letters, playerIndex });
    } else {
      this.scores[playerIndex]--;
    }

    this.buzzingPlayer = null;
    this.roundState = 'playing';
    return {
      valid: true, correct: isValidLine, letters, alreadyFound: false,
      scores: this.getScores(), remainingCombinations: this.getRemainingCombinationCount(),
    };
  }

  // 버저 타임아웃 (10초 내 답변 없음)
  buzzTimeout(): { scores: number[] } {
    if (this.buzzingPlayer !== null) {
      this.scores[this.buzzingPlayer]--;
      this.buzzingPlayer = null;
    }
    this.roundState = 'playing';
    return { scores: this.getScores() };
  }

  // 라운드 종료
  finishRound(): HexagonRoundResult {
    this.roundState = 'finished';
    this.buzzingPlayer = null;
    const result: HexagonRoundResult = {
      round: this.currentRound,
      targetNumber: this.targetNumber,
      board: this.getBoard(),
      foundCombinations: this.getFoundCombinations(),
      totalCombinations: this.validCombinations.length,
    };
    this.roundResults.push(result);
    return result;
  }

  // 게임 종료 여부
  checkGameOver(): boolean {
    if (this.isSolo) {
      return this.currentRound >= HexagonGame.MAX_ROUNDS_SOLO;
    }
    if (this.currentRound >= HexagonGame.MAX_ROUNDS_MULTI) {
      return this.scores[0] !== this.scores[1];
    }
    return false;
  }

  getWinner(): number | null {
    if (this.isSolo) return null;
    if (this.scores[0] > this.scores[1]) return 0;
    if (this.scores[1] > this.scores[0]) return 1;
    return null;
  }

  isGameOver(): boolean {
    return this.checkGameOver();
  }

  // 보드 생성 (유효한 정답이 최소 3개 이상 존재하도록)
  private generateBoard(): void {
    let attempts = 0;
    do {
      this.board = [];
      const shuffledLetters = [...LETTERS].sort(() => Math.random() - 0.5);

      for (let i = 0; i < 19; i++) {
        this.board.push({
          number: Math.floor(Math.random() * (HexagonGame.MAX_NUMBER - HexagonGame.MIN_NUMBER + 1)) + HexagonGame.MIN_NUMBER,
          letter: shuffledLetters[i],
        });
      }

      this.calculateTarget();
      attempts++;
    } while (this.validCombinations.length < 3 && attempts < 100);
  }

  private calculateTarget(): void {
    const sumCounts = new Map<number, number[][]>();
    for (const line of ALL_LINES) {
      const sum = line.reduce((acc, idx) => acc + this.board[idx].number, 0);
      if (!sumCounts.has(sum)) {
        sumCounts.set(sum, []);
      }
      sumCounts.get(sum)!.push(line);
    }

    const candidates: { target: number; lines: number[][] }[] = [];
    for (const [target, lines] of sumCounts.entries()) {
      candidates.push({ target, lines });
    }

    // 3~8개 정답이 있는 타겟 우선
    const ideal = candidates.filter(c => c.lines.length >= 3 && c.lines.length <= 8);
    if (ideal.length > 0) {
      const chosen = ideal[Math.floor(Math.random() * ideal.length)];
      this.targetNumber = chosen.target;
      this.validCombinations = chosen.lines;
    } else {
      candidates.sort((a, b) => b.lines.length - a.lines.length);
      if (candidates.length > 0) {
        this.targetNumber = candidates[0].target;
        this.validCombinations = candidates[0].lines;
      } else {
        this.targetNumber = 15;
        this.validCombinations = [];
      }
    }
  }

  reset(): void {
    this.board = [];
    this.scores = new Array(this.playerCount).fill(0);
    this.currentRound = 0;
    this.roundState = 'waiting';
    this.targetNumber = 0;
    this.validCombinations = [];
    this.foundCombinations = [];
    this.roundResults = [];
    this.buzzingPlayer = null;
  }
}
