/**
 * 순서 기억하기 게임
 *
 * 규칙:
 * - 4개(2x2) 또는 9개(3x3) 버튼
 * - 시퀀스가 순서대로 깜빡임
 * - 플레이어가 같은 순서로 터치
 * - 성공하면 시퀀스에 1개 추가
 * - 실패하면 게임 오버
 * - 두 플레이어 중 더 긴 시퀀스를 기억한 사람이 승리
 */

export class SequenceGame {
  private sequence: number[] = [];
  private playerInputs: [number[], number[]] = [[], []];
  private playerFailed: [boolean, boolean] = [false, false];
  private playerMaxLevel: [number, number] = [0, 0]; // 각 플레이어가 도달한 최대 레벨
  private currentLevel: number = 0;
  private gridSize: number = 9; // 3x3 그리드
  private gameOver: boolean = false;

  static readonly INITIAL_SEQUENCE_LENGTH = 3;
  static readonly SHOW_DELAY = 600; // 각 버튼 표시 시간 (ms)

  constructor(gridSize: number = 9) {
    this.gridSize = gridSize;
    this.reset();
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

  // 새 라운드 시작 - 시퀀스에 하나 추가
  startNewRound(): { sequence: number[]; level: number } {
    this.currentLevel++;

    // 새로운 랜덤 위치 추가
    const newPosition = Math.floor(Math.random() * this.gridSize);
    this.sequence.push(newPosition);

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
    this.currentLevel = 0;
    this.gameOver = false;

    // 초기 시퀀스 생성
    for (let i = 0; i < SequenceGame.INITIAL_SEQUENCE_LENGTH; i++) {
      this.sequence.push(Math.floor(Math.random() * this.gridSize));
    }
    this.currentLevel = SequenceGame.INITIAL_SEQUENCE_LENGTH;
  }
}
