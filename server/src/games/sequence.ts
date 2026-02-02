/**
 * 순서 기억하기 게임
 *
 * 규칙:
 * - 9개(3x3) 버튼
 * - 매 라운드 새로운 시퀀스가 순서대로 깜빡임
 * - 플레이어가 같은 순서로 터치
 * - 성공하면 다음 레벨 (시퀀스 길이 +1)
 * - 실패하면 게임 오버
 * - 두 플레이어 중 더 높은 레벨에 도달한 사람이 승리
 */

export class SequenceGame {
  private sequence: number[] = [];
  private playerInputs: [number[], number[]] = [[], []];
  private playerFailed: [boolean, boolean] = [false, false];
  private playerMaxLevel: [number, number] = [0, 0]; // 각 플레이어가 도달한 최대 레벨
  private currentLevel: number = 0;
  private gridSize: number = 9; // 3x3 그리드
  private gameOver: boolean = false;
  private isHardcore: boolean = false;

  static readonly INITIAL_SEQUENCE_LENGTH = 4; // 4개부터 시작
  static readonly SHOW_DELAY_NORMAL = 500; // 각 버튼 표시 시간 (ms)
  static readonly SHOW_DELAY_HARDCORE = 280; // 하드코어: 더 빠름

  constructor(isHardcore: boolean = false) {
    this.isHardcore = isHardcore;
    this.gridSize = isHardcore ? 16 : 9; // 하드코어: 4x4, 일반: 3x3
    this.reset();
  }

  getShowDelay(): number {
    return this.isHardcore ? SequenceGame.SHOW_DELAY_HARDCORE : SequenceGame.SHOW_DELAY_NORMAL;
  }

  getIsHardcore(): boolean {
    return this.isHardcore;
  }

  getSequence(): number[] {
    return [...this.sequence];
  }

  getCurrentLevel(): number {
    return this.currentLevel;
  }

  getGridSize(): number {
    return this.gridSize;
  }

  getPlayerInputs(): [number[], number[]] {
    return [[...this.playerInputs[0]], [...this.playerInputs[1]]];
  }

  getPlayerFailed(): [boolean, boolean] {
    return [...this.playerFailed] as [boolean, boolean];
  }

  getPlayerMaxLevel(): [number, number] {
    return [...this.playerMaxLevel] as [number, number];
  }

  isGameOver(): boolean {
    return this.gameOver;
  }

  // 입력 제한 시간 (시퀀스 길이 + 5초)
  getTimeLimit(): number {
    return (this.sequence.length + 5) * 1000; // ms
  }

  // 타임아웃으로 실패 처리
  handleTimeout(playerIndex: number): void {
    if (!this.playerFailed[playerIndex]) {
      this.playerFailed[playerIndex] = true;
      this.playerMaxLevel[playerIndex] = this.currentLevel - 1;
    }
  }

  // 새 라운드 시작 - 완전히 새로운 시퀀스 생성
  startNewRound(): { sequence: number[]; level: number } {
    this.currentLevel++;

    // 새로운 시퀀스 생성 (레벨 + 3개)
    const sequenceLength = this.currentLevel + 3;
    this.sequence = [];
    for (let i = 0; i < sequenceLength; i++) {
      this.sequence.push(Math.floor(Math.random() * this.gridSize));
    }

    // 플레이어 입력 초기화
    this.playerInputs = [[], []];

    return {
      sequence: [...this.sequence],
      level: this.currentLevel,
    };
  }

  // 플레이어 입력 처리
  handleInput(playerIndex: number, position: number): {
    valid: boolean;
    correct: boolean;
    inputIndex: number;
    completed: boolean;
    failed: boolean;
  } {
    if (this.playerFailed[playerIndex]) {
      return { valid: false, correct: false, inputIndex: -1, completed: false, failed: true };
    }

    const currentInputIndex = this.playerInputs[playerIndex].length;
    const expectedPosition = this.sequence[currentInputIndex];
    const correct = position === expectedPosition;

    this.playerInputs[playerIndex].push(position);

    if (!correct) {
      // 틀림 - 실패 처리
      this.playerFailed[playerIndex] = true;
      this.playerMaxLevel[playerIndex] = this.currentLevel - 1;

      return {
        valid: true,
        correct: false,
        inputIndex: currentInputIndex,
        completed: false,
        failed: true,
      };
    }

    // 현재 시퀀스 완료 체크
    const completed = this.playerInputs[playerIndex].length === this.sequence.length;

    if (completed) {
      this.playerMaxLevel[playerIndex] = this.currentLevel;
    }

    return {
      valid: true,
      correct: true,
      inputIndex: currentInputIndex,
      completed,
      failed: false,
    };
  }

  // 둘 다 현재 라운드 완료했는지 확인
  bothPlayersCompleted(): boolean {
    const p0Completed = this.playerInputs[0].length === this.sequence.length || this.playerFailed[0];
    const p1Completed = this.playerInputs[1].length === this.sequence.length || this.playerFailed[1];
    return p0Completed && p1Completed;
  }

  // 라운드 결과 확인
  checkRoundResult(): {
    bothPassed: boolean;
    bothFailed: boolean;
    gameOver: boolean;
    winnerIndex: number | null;
  } {
    const p0Passed = !this.playerFailed[0] && this.playerInputs[0].length === this.sequence.length;
    const p1Passed = !this.playerFailed[1] && this.playerInputs[1].length === this.sequence.length;

    if (p0Passed && p1Passed) {
      // 둘 다 성공 - 다음 라운드
      return { bothPassed: true, bothFailed: false, gameOver: false, winnerIndex: null };
    }

    if (this.playerFailed[0] && this.playerFailed[1]) {
      // 둘 다 실패 - 더 멀리 간 사람 승리
      this.gameOver = true;
      let winnerIndex: number | null = null;

      if (this.playerMaxLevel[0] > this.playerMaxLevel[1]) {
        winnerIndex = 0;
      } else if (this.playerMaxLevel[1] > this.playerMaxLevel[0]) {
        winnerIndex = 1;
      }
      // 같으면 무승부 (null)

      return { bothPassed: false, bothFailed: true, gameOver: true, winnerIndex };
    }

    if (this.playerFailed[0] || this.playerFailed[1]) {
      // 한 명만 실패 - 상대방 승리
      this.gameOver = true;
      const winnerIndex = this.playerFailed[0] ? 1 : 0;
      return { bothPassed: false, bothFailed: false, gameOver: true, winnerIndex };
    }

    // 아직 진행 중
    return { bothPassed: false, bothFailed: false, gameOver: false, winnerIndex: null };
  }

  // 승자 확인
  getWinner(): number | null {
    if (!this.gameOver) return null;

    if (this.playerFailed[0] && !this.playerFailed[1]) return 1;
    if (this.playerFailed[1] && !this.playerFailed[0]) return 0;

    // 둘 다 실패한 경우 레벨 비교
    if (this.playerMaxLevel[0] > this.playerMaxLevel[1]) return 0;
    if (this.playerMaxLevel[1] > this.playerMaxLevel[0]) return 1;

    return null; // 무승부
  }

  reset(): void {
    this.sequence = [];
    this.playerInputs = [[], []];
    this.playerFailed = [false, false];
    this.playerMaxLevel = [0, 0];
    this.currentLevel = 1; // 레벨 1부터 시작
    this.gameOver = false;

    // 초기 시퀀스 생성 (4개)
    for (let i = 0; i < SequenceGame.INITIAL_SEQUENCE_LENGTH; i++) {
      this.sequence.push(Math.floor(Math.random() * this.gridSize));
    }
  }
}
