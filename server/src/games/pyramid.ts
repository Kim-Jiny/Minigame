/**
 * 수식피라미드(Pyramid) 게임 - 데블스플랜 2 감옥 계산게임 기반
 *
 * 규칙:
 * - 4줄 10장의 연산 카드 피라미드 (+n, -n, ×n)
 * - 타겟 넘버를 정확히 맞추는 카드 선택 순서를 찾아야 함
 * - 첫 카드: 연산자 무시, 숫자값이 시작값
 * - 이후 카드: 연산 적용
 * - 정확히 3장의 카드를 순서대로 선택
 * - 맨 아래줄(Row 3)만 처음에 선택 가능
 * - 아래 두 카드 모두 제거 시 위 카드 활성화
 * - 버저를 누르고 15초 내 카드 순서 제출
 * - 정답 +1, 오답 -1, 3라운드 진행
 * - 60초 무도전 시 라운드 종료
 */

export type PyramidRoundState = 'waiting' | 'playing' | 'buzzing' | 'finished';

export interface PyramidCard {
  operator: '+' | '-' | '*';
  value: number;      // 1-9
  position: number;   // 0-9 (pyramid index)
  row: number;        // 0-3
  col: number;        // 0 ~ row
}

export interface PyramidRoundResult {
  round: number;
  targetNumber: number;
  cards: PyramidCard[];
  validPaths: number[][];
}

/**
 * 피라미드 구조 (4줄, 10장):
 *       [0]           Row 0
 *     [1] [2]         Row 1
 *   [3] [4] [5]       Row 2
 * [6] [7] [8] [9]     Row 3 (initially selectable)
 *
 * 부모-자식 관계: Card(row, col)은 Card(row+1, col)과 Card(row+1, col+1) 위에 올라가 있음
 */

// 각 카드의 자식 인덱스 (아래 두 카드)
const CHILDREN_MAP: { [key: number]: number[] } = {
  0: [1, 2],
  1: [3, 4],
  2: [4, 5],
  3: [6, 7],
  4: [7, 8],
  5: [8, 9],
  // Row 3 (6,7,8,9): 자식 없음 (맨 아래줄)
};

const OPERATORS: ('+' | '-' | '*')[] = ['+', '-', '*'];

export class PyramidGame {
  static readonly BUZZ_TIME_LIMIT = 15000;       // 15초 답변 시간
  static readonly ROUND_IDLE_TIMEOUT = 60000;    // 60초 무도전 시 라운드 종료
  static readonly SKIP_AVAILABLE_TIME = 20000;  // 20초 무도전 시 라운드 넘기기 활성화
  static readonly MAX_ROUNDS_MULTI = 3;
  static readonly MAX_ROUNDS_SOLO = 10;

  private cards: PyramidCard[] = [];
  private scores: number[] = [];
  private currentRound: number = 0;
  private roundState: PyramidRoundState = 'waiting';
  private targetNumber: number = 0;
  private validPaths: number[][] = [];
  private roundResults: PyramidRoundResult[] = [];
  private buzzingPlayer: number | null = null;
  private isSolo: boolean;

  constructor(isSolo: boolean = false) {
    this.isSolo = isSolo;
    this.scores = isSolo ? [0] : [0, 0];
  }

  getCards(): PyramidCard[] {
    return this.cards.map(c => ({ ...c }));
  }

  getScores(): number[] {
    return [...this.scores];
  }

  getCurrentRound(): number {
    return this.currentRound;
  }

  getRoundState(): PyramidRoundState {
    return this.roundState;
  }

  getTargetNumber(): number {
    return this.targetNumber;
  }

  getValidPaths(): number[][] {
    return this.validPaths.map(p => [...p]);
  }

  getRoundResults(): PyramidRoundResult[] {
    return [...this.roundResults];
  }

  getBuzzingPlayer(): number | null {
    return this.buzzingPlayer;
  }

  getMaxRounds(): number {
    return this.isSolo ? PyramidGame.MAX_ROUNDS_SOLO : PyramidGame.MAX_ROUNDS_MULTI;
  }

  // 새 라운드 시작
  startRound(): {
    cards: PyramidCard[];
    targetNumber: number;
    round: number;
    validPaths: number[][];
  } {
    this.currentRound++;
    this.roundState = 'playing';
    this.buzzingPlayer = null;
    this.generatePuzzle();

    return {
      cards: this.getCards(),
      targetNumber: this.targetNumber,
      round: this.currentRound,
      validPaths: this.getValidPaths(),
    };
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

  // 답변 제출 (카드 인덱스 시퀀스)
  submitAnswer(playerIndex: number, sequence: number[]): {
    valid: boolean;
    correct: boolean;
    scores: number[];
    calculationSteps: string[];
  } {
    const defaultResult = {
      valid: false,
      correct: false,
      scores: this.getScores(),
      calculationSteps: [],
    };

    if (this.roundState !== 'buzzing' || this.buzzingPlayer !== playerIndex) {
      return defaultResult;
    }

    // 시퀀스 유효성 검사: 정확히 3장
    if (sequence.length !== 3) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true,
        correct: false,
        scores: this.getScores(),
        calculationSteps: ['정확히 3장을 선택해야 합니다'],
      };
    }

    // 인덱스 범위 검사
    if (sequence.some(i => i < 0 || i >= 10)) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true,
        correct: false,
        scores: this.getScores(),
        calculationSteps: ['잘못된 카드 인덱스'],
      };
    }

    // 중복 인덱스 검사
    if (new Set(sequence).size !== sequence.length) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true,
        correct: false,
        scores: this.getScores(),
        calculationSteps: ['중복 카드 선택'],
      };
    }

    // 피라미드 제약 조건 검사: 각 단계에서 선택한 카드가 유효한지
    const usedSet = new Set<number>();
    const steps: string[] = [];
    let isValidSequence = true;

    for (let i = 0; i < sequence.length; i++) {
      const cardIdx = sequence[i];
      if (!this.isSelectable(cardIdx, usedSet)) {
        isValidSequence = false;
        steps.push(`카드 ${cardIdx}은 선택 불가`);
        break;
      }
      usedSet.add(cardIdx);
    }

    if (!isValidSequence) {
      this.scores[playerIndex]--;
      this.buzzingPlayer = null;
      this.roundState = 'playing';
      return {
        valid: true,
        correct: false,
        scores: this.getScores(),
        calculationSteps: steps,
      };
    }

    // 계산
    const { result, calculationSteps } = this.calculateSequence(sequence);

    const correct = result === this.targetNumber;
    if (correct) {
      this.scores[playerIndex]++;
    } else {
      this.scores[playerIndex]--;
    }

    this.buzzingPlayer = null;
    this.roundState = 'playing';

    return {
      valid: true,
      correct,
      scores: this.getScores(),
      calculationSteps,
    };
  }

  // 버저 타임아웃 (15초 내 답변 없음)
  buzzTimeout(): { scores: number[] } {
    if (this.buzzingPlayer !== null) {
      this.scores[this.buzzingPlayer]--;
      this.buzzingPlayer = null;
    }
    this.roundState = 'playing';
    return { scores: this.getScores() };
  }

  // 라운드 종료
  finishRound(): PyramidRoundResult {
    this.roundState = 'finished';
    this.buzzingPlayer = null;
    const result: PyramidRoundResult = {
      round: this.currentRound,
      targetNumber: this.targetNumber,
      cards: this.getCards(),
      validPaths: this.getValidPaths(),
    };
    this.roundResults.push(result);
    return result;
  }

  // 게임 종료 여부
  checkGameOver(): boolean {
    if (this.isSolo) {
      return this.currentRound >= PyramidGame.MAX_ROUNDS_SOLO;
    }
    if (this.currentRound >= PyramidGame.MAX_ROUNDS_MULTI) {
      return this.scores[0] !== this.scores[1];
    }
    return false;
  }

  getWinner(): number | null {
    if (this.scores[0] > this.scores[1]) return 0;
    if (this.scores[1] > this.scores[0]) return 1;
    return null;
  }

  isGameOver(): boolean {
    return this.checkGameOver();
  }

  // ========== Private Methods ==========

  // 카드가 현재 선택 가능한지 확인
  private isSelectable(cardIdx: number, usedCards: Set<number>): boolean {
    const card = this.cards[cardIdx];
    if (!card) return false;

    // 이미 선택한 카드는 불가
    if (usedCards.has(cardIdx)) return false;

    // 모든 카드 자유롭게 선택 가능
    return true;
  }

  // 시퀀스 계산 (연산자 우선순위 적용: × 먼저, +/- 나중)
  private calculateSequence(sequence: number[]): { result: number; calculationSteps: string[] } {
    return PyramidGame.evaluateWithPrecedence(
      sequence.map(i => this.cards[i])
    );
  }

  // 연산자 우선순위 적용 계산 (static으로 DFS에서도 재사용)
  static evaluateWithPrecedence(cards: PyramidCard[]): { result: number; calculationSteps: string[] } {
    const steps: string[] = [];

    // 수식 구성: 첫 카드 값 + 이후 (연산자, 값) 쌍
    const values: number[] = [cards[0].value];
    const operators: string[] = [];

    for (let i = 1; i < cards.length; i++) {
      values.push(cards[i].value);
      operators.push(cards[i].operator);
    }

    // 수식 표시
    let expr = `${values[0]}`;
    for (let i = 0; i < operators.length; i++) {
      const opSymbol = operators[i] === '*' ? '×' : operators[i];
      expr += ` ${opSymbol} ${values[i + 1]}`;
    }
    steps.push(expr);

    // Phase 1: 곱셈 먼저 처리
    const reduced: number[] = [values[0]];
    const reducedOps: string[] = [];

    for (let i = 0; i < operators.length; i++) {
      if (operators[i] === '*') {
        const last = reduced[reduced.length - 1];
        reduced[reduced.length - 1] = last * values[i + 1];
        steps.push(`${last} × ${values[i + 1]} = ${reduced[reduced.length - 1]}`);
      } else {
        reduced.push(values[i + 1]);
        reducedOps.push(operators[i]);
      }
    }

    // Phase 2: 덧셈/뺄셈 왼→오른쪽
    let result = reduced[0];
    for (let i = 0; i < reducedOps.length; i++) {
      const prev = result;
      if (reducedOps[i] === '+') {
        result += reduced[i + 1];
      } else {
        result -= reduced[i + 1];
      }
      steps.push(`${prev} ${reducedOps[i]} ${reduced[i + 1]} = ${result}`);
    }

    return { result, calculationSteps: steps };
  }

  // 퍼즐 생성 (유효한 답이 1-5개인 타겟 찾기)
  private generatePuzzle(): void {
    let attempts = 0;
    do {
      this.generateCards();
      this.findValidTarget();
      attempts++;
    } while (this.validPaths.length === 0 && attempts < 100);
  }

  // 10장 랜덤 카드 생성
  private generateCards(): void {
    this.cards = [];
    let position = 0;
    for (let row = 0; row < 4; row++) {
      for (let col = 0; col <= row; col++) {
        this.cards.push({
          operator: OPERATORS[Math.floor(Math.random() * OPERATORS.length)],
          value: Math.floor(Math.random() * 9) + 1,  // 1-9
          position,
          row,
          col,
        });
        position++;
      }
    }
  }

  // DFS로 유효한 시퀀스 탐색 → 타겟 선택 (연산자 우선순위 적용)
  private findValidTarget(): void {
    const allPaths: { path: number[]; result: number }[] = [];

    // DFS 탐색: 정확히 길이 3의 모든 유효 시퀀스
    const dfs = (usedSet: Set<number>, path: number[]) => {
      if (path.length === 3) {
        // 연산자 우선순위 적용하여 결과 계산
        const cards = path.map(i => this.cards[i]);
        const { result } = PyramidGame.evaluateWithPrecedence(cards);
        allPaths.push({ path: [...path], result });
        return;
      }

      for (let i = 0; i < 10; i++) {
        if (usedSet.has(i)) continue;
        if (!this.isSelectable(i, usedSet)) continue;

        usedSet.add(i);
        path.push(i);
        dfs(usedSet, path);
        path.pop();
        usedSet.delete(i);
      }
    };

    dfs(new Set(), []);

    // 결과값별 그룹핑
    const resultMap = new Map<number, number[][]>();
    for (const { path, result } of allPaths) {
      if (!resultMap.has(result)) {
        resultMap.set(result, []);
      }
      resultMap.get(result)!.push(path);
    }

    // 유효 시퀀스 1~5개인 결과를 타겟 후보로
    const candidates: { target: number; paths: number[][] }[] = [];
    for (const [target, paths] of resultMap.entries()) {
      if (paths.length >= 1 && paths.length <= 5) {
        candidates.push({ target, paths });
      }
    }

    if (candidates.length > 0) {
      const chosen = candidates[Math.floor(Math.random() * candidates.length)];
      this.targetNumber = chosen.target;
      this.validPaths = chosen.paths;
    } else {
      // 1~5개 조건 실패 시 아무 결과나 선택
      const allCandidates: { target: number; paths: number[][] }[] = [];
      for (const [target, paths] of resultMap.entries()) {
        allCandidates.push({ target, paths });
      }
      if (allCandidates.length > 0) {
        // 시퀀스가 적은 것 우선
        allCandidates.sort((a, b) => a.paths.length - b.paths.length);
        const chosen = allCandidates[0];
        this.targetNumber = chosen.target;
        this.validPaths = chosen.paths;
      } else {
        this.targetNumber = 0;
        this.validPaths = [];
      }
    }
  }

  reset(): void {
    this.cards = [];
    this.scores = this.isSolo ? [0] : [0, 0];
    this.currentRound = 0;
    this.roundState = 'waiting';
    this.targetNumber = 0;
    this.validPaths = [];
    this.roundResults = [];
    this.buzzingPlayer = null;
  }
}
