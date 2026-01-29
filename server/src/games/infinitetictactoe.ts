/**
 * 무한 틱택토 게임 로직
 *
 * 규칙:
 * - 3×3 보드에서 O와 X가 번갈아 놓음
 * - 각 플레이어는 최대 3개의 말만 보드에 존재 가능
 * - 4번째 수부터는 가장 오래된 말이 사라짐
 * - 3개 연속으로 놓으면 승리
 * - 무승부 없음!
 */

export class InfiniteTicTacToeGame {
  private board: (number | null)[];  // null: 빈칸, 0: 플레이어1, 1: 플레이어2
  private currentPlayer: number;      // 0 또는 1
  private moveHistory: { position: number; player: number }[];  // 이동 기록
  private readonly maxPiecesPerPlayer = 3;  // 플레이어당 최대 말 개수

  // 승리 조합
  private readonly winPatterns = [
    [0, 1, 2], // 가로
    [3, 4, 5],
    [6, 7, 8],
    [0, 3, 6], // 세로
    [1, 4, 7],
    [2, 5, 8],
    [0, 4, 8], // 대각선
    [2, 4, 6],
  ];

  constructor() {
    this.board = Array(9).fill(null);
    this.currentPlayer = 0;
    this.moveHistory = [];
  }

  getBoard(): (number | null)[] {
    return [...this.board];
  }

  getCurrentPlayer(): number {
    return this.currentPlayer;
  }

  getMoveHistory(): { position: number; player: number }[] {
    return [...this.moveHistory];
  }

  // 플레이어의 말 개수 계산
  private countPlayerPieces(player: number): number {
    return this.board.filter(cell => cell === player).length;
  }

  // 플레이어의 가장 오래된 말 위치 찾기
  private getOldestPiecePosition(player: number): number | null {
    for (const move of this.moveHistory) {
      if (move.player === player && this.board[move.position] === player) {
        return move.position;
      }
    }
    return null;
  }

  // 사라질 예정인 말 위치 반환 (미리보기용)
  getNextToDisappear(player: number): number | null {
    if (this.countPlayerPieces(player) >= this.maxPiecesPerPlayer) {
      return this.getOldestPiecePosition(player);
    }
    return null;
  }

  makeMove(position: number, player: number): {
    valid: boolean;
    message?: string;
    gameOver?: boolean;
    winner?: number | null;
    isDraw?: boolean;
    removedPosition?: number | null;  // 사라진 말의 위치
  } {
    // 유효성 검사
    if (position < 0 || position > 8) {
      return { valid: false, message: 'Invalid position' };
    }

    if (player !== this.currentPlayer) {
      return { valid: false, message: 'Not your turn' };
    }

    if (this.board[position] !== null) {
      return { valid: false, message: 'Cell already occupied' };
    }

    let removedPosition: number | null = null;

    // 이미 3개의 말이 있으면 가장 오래된 말 제거
    if (this.countPlayerPieces(player) >= this.maxPiecesPerPlayer) {
      removedPosition = this.getOldestPiecePosition(player);
      if (removedPosition !== null) {
        this.board[removedPosition] = null;
        // moveHistory에서 제거된 말 기록 삭제
        const removeIndex = this.moveHistory.findIndex(
          m => m.position === removedPosition && m.player === player
        );
        if (removeIndex !== -1) {
          this.moveHistory.splice(removeIndex, 1);
        }
      }
    }

    // 수 두기
    this.board[position] = player;
    this.moveHistory.push({ position, player });

    // 승리 체크
    const winner = this.checkWinner();
    if (winner !== null) {
      return {
        valid: true,
        gameOver: true,
        winner,
        isDraw: false,
        removedPosition,
      };
    }

    // 무한 틱택토는 무승부 없음 (계속 진행)
    // 턴 교체
    this.currentPlayer = this.currentPlayer === 0 ? 1 : 0;

    return { valid: true, gameOver: false, removedPosition };
  }

  private checkWinner(): number | null {
    for (const pattern of this.winPatterns) {
      const [a, b, c] = pattern;
      if (
        this.board[a] !== null &&
        this.board[a] === this.board[b] &&
        this.board[a] === this.board[c]
      ) {
        return this.board[a]!;
      }
    }
    return null;
  }

  reset(): void {
    this.board = Array(9).fill(null);
    this.currentPlayer = 0;
    this.moveHistory = [];
  }
}
