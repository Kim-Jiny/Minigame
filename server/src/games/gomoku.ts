/**
 * 오목(Gomoku) 게임 로직
 *
 * 보드 구조: 19x19 = 361칸 (0~360)
 * 위치 계산: row * 19 + col
 * 승리 조건: 5개 연속 (가로/세로/대각선)
 */

export class GomokuGame {
  private board: (number | null)[]; // null: 빈칸, 0: 플레이어1(흑), 1: 플레이어2(백)
  private currentPlayer: number; // 0 또는 1
  private moveCount: number;

  // 보드 크기
  static readonly BOARD_SIZE = 15;
  static readonly TOTAL_CELLS = 15 * 15; // 225

  // 8방향 탐색용 (상, 하, 좌, 우, 대각선 4방향)
  private readonly directions = [
    [0, 1],   // 오른쪽
    [1, 0],   // 아래
    [1, 1],   // 대각선 오른쪽 아래
    [1, -1],  // 대각선 왼쪽 아래
  ];

  constructor() {
    this.board = Array(GomokuGame.TOTAL_CELLS).fill(null);
    this.currentPlayer = 0; // 흑돌(player 0)이 선공
    this.moveCount = 0;
  }

  getBoard(): (number | null)[] {
    return [...this.board];
  }

  getCurrentPlayer(): number {
    return this.currentPlayer;
  }

  // 1차원 인덱스를 2차원 좌표로 변환
  private indexToCoord(index: number): [number, number] {
    const row = Math.floor(index / GomokuGame.BOARD_SIZE);
    const col = index % GomokuGame.BOARD_SIZE;
    return [row, col];
  }

  // 2차원 좌표를 1차원 인덱스로 변환
  private coordToIndex(row: number, col: number): number {
    return row * GomokuGame.BOARD_SIZE + col;
  }

  // 좌표가 보드 범위 내인지 확인
  private isValidCoord(row: number, col: number): boolean {
    return row >= 0 && row < GomokuGame.BOARD_SIZE && col >= 0 && col < GomokuGame.BOARD_SIZE;
  }

  makeMove(position: number, player: number): {
    valid: boolean;
    message?: string;
    gameOver?: boolean;
    winner?: number | null;
    isDraw?: boolean;
  } {
    // 유효성 검사
    if (position < 0 || position >= GomokuGame.TOTAL_CELLS) {
      return { valid: false, message: 'Invalid position' };
    }

    if (player !== this.currentPlayer) {
      return { valid: false, message: 'Not your turn' };
    }

    if (this.board[position] !== null) {
      return { valid: false, message: 'Cell already occupied' };
    }

    // 수 두기
    this.board[position] = player;
    this.moveCount++;

    // 승리 체크
    const winner = this.checkWinner(position);
    if (winner !== null) {
      return {
        valid: true,
        gameOver: true,
        winner,
        isDraw: false,
      };
    }

    // 무승부 체크 (보드가 가득 찬 경우)
    if (this.moveCount === GomokuGame.TOTAL_CELLS) {
      return {
        valid: true,
        gameOver: true,
        winner: null,
        isDraw: true,
      };
    }

    // 턴 교체
    this.currentPlayer = this.currentPlayer === 0 ? 1 : 0;

    return { valid: true, gameOver: false };
  }

  // 마지막으로 둔 위치를 기준으로 승리 판정
  private checkWinner(lastPosition: number): number | null {
    const [row, col] = this.indexToCoord(lastPosition);
    const player = this.board[lastPosition];

    if (player === null) return null;

    // 4방향 검사 (각 방향에서 양쪽으로 카운트)
    for (const [dr, dc] of this.directions) {
      let count = 1; // 현재 위치 포함

      // 정방향으로 카운트
      let r = row + dr;
      let c = col + dc;
      while (this.isValidCoord(r, c) && this.board[this.coordToIndex(r, c)] === player) {
        count++;
        r += dr;
        c += dc;
      }

      // 역방향으로 카운트
      r = row - dr;
      c = col - dc;
      while (this.isValidCoord(r, c) && this.board[this.coordToIndex(r, c)] === player) {
        count++;
        r -= dr;
        c -= dc;
      }

      // 5개 이상 연속이면 승리
      if (count >= 5) {
        return player;
      }
    }

    return null;
  }

  reset(): void {
    this.board = Array(GomokuGame.TOTAL_CELLS).fill(null);
    this.currentPlayer = 0;
    this.moveCount = 0;
  }
}
