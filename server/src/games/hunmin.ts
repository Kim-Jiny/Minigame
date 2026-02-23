export class HunminGame {
  static readonly TURN_TIME_LIMIT = 15000;
  static readonly ROUNDS_TO_WIN = 2;
  static readonly MAX_ROUNDS = 3;

  // ~40개 큐레이팅된 초성 패턴 (2글자)
  static readonly CHOSUNG_PATTERNS = [
    'ㄱㅅ','ㄱㅈ','ㄱㄹ','ㄱㅁ','ㄱㅂ','ㄱㅇ','ㄱㅎ',
    'ㄴㅁ','ㄴㅂ','ㄴㅇ','ㄴㅈ',
    'ㄷㅈ','ㄷㅎ',
    'ㅁㅅ','ㅁㅈ','ㅁㅇ','ㅁㅎ',
    'ㅂㅈ','ㅂㅎ','ㅂㅅ','ㅂㅇ',
    'ㅅㅎ','ㅅㅈ','ㅅㅇ','ㅅㄱ',
    'ㅇㅈ','ㅇㅎ','ㅇㅅ','ㅇㄱ','ㅇㄷ',
    'ㅈㅇ','ㅈㅎ','ㅈㅅ','ㅈㄱ',
    'ㅊㅅ','ㅊㅇ',
    'ㅎㄱ','ㅎㅈ','ㅎㅇ','ㅎㅅ',
  ];

  // 한글 초성 테이블 (유니코드 순서)
  private static readonly CHOSUNG_LIST = [
    'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ',
    'ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'
  ];

  // 상태
  private scores: number[] = [0, 0];
  private currentRound: number = 0;
  private roundState: 'waiting' | 'playing' | 'finished' = 'waiting';
  private currentChosung: string = '';
  private usedWords: string[] = [];
  private currentTurnPlayer: number = 0; // 0 또는 1
  private lastRoundLoser: number | null = null;
  private roundResults: { round: number; winnerIndex: number | null; reason: string }[] = [];

  /**
   * 한글 단어에서 초성을 추출
   */
  static getChosung(word: string): string {
    let result = '';
    for (let i = 0; i < word.length; i++) {
      const code = word.charCodeAt(i);
      // 한글 유니코드 범위: 0xAC00 ~ 0xD7A3
      if (code >= 0xAC00 && code <= 0xD7A3) {
        const chosungIndex = Math.floor((code - 0xAC00) / 588);
        result += HunminGame.CHOSUNG_LIST[chosungIndex];
      }
    }
    return result;
  }

  /**
   * 새 라운드 시작
   */
  startRound(): { round: number; chosung: string; firstPlayer: number; scores: number[] } {
    this.currentRound++;
    this.roundState = 'playing';
    this.usedWords = [];

    // 초성 랜덤 선택
    const randomIndex = Math.floor(Math.random() * HunminGame.CHOSUNG_PATTERNS.length);
    this.currentChosung = HunminGame.CHOSUNG_PATTERNS[randomIndex];

    // 선공 결정: 1라운드는 랜덤, 이후는 전 라운드 패자
    if (this.currentRound === 1) {
      this.currentTurnPlayer = Math.random() < 0.5 ? 0 : 1;
    } else if (this.lastRoundLoser !== null) {
      this.currentTurnPlayer = this.lastRoundLoser;
    }

    return {
      round: this.currentRound,
      chosung: this.currentChosung,
      firstPlayer: this.currentTurnPlayer,
      scores: [...this.scores],
    };
  }

  /**
   * 단어 제출 - 기본 검증만 수행 (사전 검증은 외부에서)
   */
  submitWord(playerIndex: number, word: string): {
    valid: boolean;
    reason?: string;
    needsDictionaryCheck: boolean;
  } {
    // 턴 확인
    if (playerIndex !== this.currentTurnPlayer) {
      return { valid: false, reason: 'not_your_turn', needsDictionaryCheck: false };
    }

    // 라운드 진행 중 확인
    if (this.roundState !== 'playing') {
      return { valid: false, reason: 'round_not_playing', needsDictionaryCheck: false };
    }

    // 2글자 확인
    if (word.length !== 2) {
      return { valid: false, reason: 'invalid_length', needsDictionaryCheck: false };
    }

    // 한글 확인
    for (let i = 0; i < word.length; i++) {
      const code = word.charCodeAt(i);
      if (code < 0xAC00 || code > 0xD7A3) {
        return { valid: false, reason: 'not_korean', needsDictionaryCheck: false };
      }
    }

    // 초성 일치 확인
    const wordChosung = HunminGame.getChosung(word);
    if (wordChosung !== this.currentChosung) {
      return { valid: false, reason: 'chosung_mismatch', needsDictionaryCheck: false };
    }

    // 중복 확인
    if (this.usedWords.includes(word)) {
      return { valid: false, reason: 'duplicate_word', needsDictionaryCheck: false };
    }

    // 기본 검증 통과 → 사전 검증 필요
    return { valid: true, needsDictionaryCheck: true };
  }

  /**
   * 사전 검증 통과 후 단어 확정
   */
  confirmWordValid(playerIndex: number, word: string): {
    usedWords: string[];
    nextPlayer: number;
  } {
    this.usedWords.push(word);
    this.currentTurnPlayer = playerIndex === 0 ? 1 : 0;

    return {
      usedWords: [...this.usedWords],
      nextPlayer: this.currentTurnPlayer,
    };
  }

  /**
   * 라운드 패배 처리
   */
  handleRoundLoss(loserIndex: number, reason: string): {
    winnerIndex: number;
    scores: number[];
    roundResult: { round: number; winnerIndex: number; reason: string };
  } {
    this.roundState = 'finished';
    const winnerIndex = loserIndex === 0 ? 1 : 0;
    this.scores[winnerIndex]++;
    this.lastRoundLoser = loserIndex;

    const roundResult = {
      round: this.currentRound,
      winnerIndex,
      reason,
    };
    this.roundResults.push(roundResult);

    return {
      winnerIndex,
      scores: [...this.scores],
      roundResult,
    };
  }

  /**
   * 타임아웃 처리 (현재 턴 플레이어가 패배)
   */
  handleTimeout(): {
    loserIndex: number;
    winnerIndex: number;
    scores: number[];
    roundResult: { round: number; winnerIndex: number; reason: string };
  } {
    const loserIndex = this.currentTurnPlayer;
    const result = this.handleRoundLoss(loserIndex, 'timeout');
    return {
      loserIndex,
      ...result,
    };
  }

  /**
   * 게임 종료 여부 확인
   */
  checkGameOver(): boolean {
    return this.scores[0] >= HunminGame.ROUNDS_TO_WIN ||
           this.scores[1] >= HunminGame.ROUNDS_TO_WIN ||
           this.currentRound >= HunminGame.MAX_ROUNDS;
  }

  /**
   * 승자 반환 (null이면 무승부)
   */
  getWinner(): number | null {
    if (this.scores[0] > this.scores[1]) return 0;
    if (this.scores[1] > this.scores[0]) return 1;
    return null;
  }

  /**
   * 게임 리셋
   */
  reset(): void {
    this.scores = [0, 0];
    this.currentRound = 0;
    this.roundState = 'waiting';
    this.currentChosung = '';
    this.usedWords = [];
    this.currentTurnPlayer = 0;
    this.lastRoundLoser = null;
    this.roundResults = [];
  }

  // Getters
  getScores(): number[] { return [...this.scores]; }
  getCurrentRound(): number { return this.currentRound; }
  getRoundState(): string { return this.roundState; }
  getCurrentChosung(): string { return this.currentChosung; }
  getUsedWords(): string[] { return [...this.usedWords]; }
  getCurrentTurnPlayer(): number { return this.currentTurnPlayer; }
  getRoundResults(): any[] { return [...this.roundResults]; }
}
