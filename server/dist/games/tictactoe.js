"use strict";
/**
 * 틱택토 게임 로직
 *
 * 보드 구조:
 * [0][1][2]
 * [3][4][5]
 * [6][7][8]
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.TicTacToeGame = void 0;
class TicTacToeGame {
    constructor() {
        // 승리 조합
        this.winPatterns = [
            [0, 1, 2], // 가로
            [3, 4, 5],
            [6, 7, 8],
            [0, 3, 6], // 세로
            [1, 4, 7],
            [2, 5, 8],
            [0, 4, 8], // 대각선
            [2, 4, 6],
        ];
        this.board = Array(9).fill(null);
        this.currentPlayer = 0;
        this.moveCount = 0;
    }
    getBoard() {
        return [...this.board];
    }
    getCurrentPlayer() {
        return this.currentPlayer;
    }
    makeMove(position, player) {
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
        // 수 두기
        this.board[position] = player;
        this.moveCount++;
        // 승리 체크
        const winner = this.checkWinner();
        if (winner !== null) {
            return {
                valid: true,
                gameOver: true,
                winner,
                isDraw: false,
            };
        }
        // 무승부 체크
        if (this.moveCount === 9) {
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
    checkWinner() {
        for (const pattern of this.winPatterns) {
            const [a, b, c] = pattern;
            if (this.board[a] !== null &&
                this.board[a] === this.board[b] &&
                this.board[a] === this.board[c]) {
                return this.board[a];
            }
        }
        return null;
    }
    reset() {
        this.board = Array(9).fill(null);
        this.currentPlayer = 0;
        this.moveCount = 0;
    }
}
exports.TicTacToeGame = TicTacToeGame;
