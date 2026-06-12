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
  private readonly playerCount: number;
  private scores: number[];
  private currentRound: number = 0;
  private roundState: 'waiting' | 'playing' | 'finished' = 'waiting';
  private currentChosung: string = '';
  private usedWords: string[] = [];
  private currentTurnPlayer: number = 0;
  private lastRoundLoser: number | null = null;
  private roundResults: { round: number; winnerIndex: number | null; reason: string }[] = [];
  // [N인 탈락제] 이번 라운드에서 탈락한 플레이어. 라운드마다 초기화(이탈자는 항상 포함).
  private eliminatedThisRound: Set<number> = new Set();
  // [N인] 도중 영구 이탈한 플레이어. 모든 라운드·승자·보상에서 제외.
  private leftPlayers: Set<number> = new Set();

  constructor(playerCount: number = 2) {
    this.playerCount = Math.max(2, playerCount);
    this.scores = new Array(this.playerCount).fill(0);
  }

  getPlayerCount(): number { return this.playerCount; }
  getEliminated(): number[] { return [...this.eliminatedThisRound]; }
  getLeftPlayers(): number[] { return [...this.leftPlayers]; }

  /** loserIndex 다음의 '활성(미탈락)' 플레이어 인덱스를 순환하며 찾는다. */
  private nextActivePlayer(from: number): number {
    for (let step = 1; step <= this.playerCount; step++) {
      const idx = (from + step) % this.playerCount;
      if (!this.eliminatedThisRound.has(idx)) return idx;
    }
    return from; // 이론상 도달 안 함(최소 1명 활성)
  }

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
  startRound(): { round: number; chosung: string; firstPlayer: number; scores: number[]; eliminated: number[] } {
    this.currentRound++;
    this.roundState = 'playing';
    this.usedWords = [];
    // 이번 라운드 탈락자 = 영구 이탈자만으로 초기화(이탈자는 라운드 시작부터 탈락 상태).
    this.eliminatedThisRound = new Set(this.leftPlayers);

    // 초성 랜덤 선택
    const randomIndex = Math.floor(Math.random() * HunminGame.CHOSUNG_PATTERNS.length);
    this.currentChosung = HunminGame.CHOSUNG_PATTERNS[randomIndex];

    // 선공 결정: 활성(미탈락) 플레이어 중에서.
    // 2인은 1라운드 랜덤·이후 전 라운드 패자(기존 규칙 유지), 3인+는 활성 중 랜덤.
    const active: number[] = [];
    for (let i = 0; i < this.playerCount; i++) {
      if (!this.eliminatedThisRound.has(i)) active.push(i);
    }
    if (this.playerCount === 2 && this.currentRound > 1 && this.lastRoundLoser !== null &&
        !this.eliminatedThisRound.has(this.lastRoundLoser)) {
      this.currentTurnPlayer = this.lastRoundLoser;
    } else {
      this.currentTurnPlayer = active[Math.floor(Math.random() * active.length)] ?? 0;
    }

    return {
      round: this.currentRound,
      chosung: this.currentChosung,
      firstPlayer: this.currentTurnPlayer,
      scores: [...this.scores],
      eliminated: [...this.eliminatedThisRound],
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
    this.currentTurnPlayer = this.nextActivePlayer(playerIndex); // 다음 생존 플레이어

    return {
      usedWords: [...this.usedWords],
      nextPlayer: this.currentTurnPlayer,
    };
  }

  /**
   * 라운드 탈락 처리 (탈락제).
   * 해당 플레이어를 이번 라운드에서 탈락시키고, 활성 1명만 남으면 그 사람이 라운드 승(+1점).
   * 2인이면 한 명 탈락 = 즉시 라운드 종료(기존 동작과 동일).
   */
  eliminate(loserIndex: number, reason: string): {
    eliminatedIndex: number;
    roundEnded: boolean;
    nextPlayer?: number; // 라운드 계속 시 다음 턴
    winnerIndex?: number; // 라운드 종료 시 승자
    scores: number[];
    roundResult?: { round: number; winnerIndex: number; reason: string };
  } {
    if (this.roundState !== 'playing' || this.eliminatedThisRound.has(loserIndex)) {
      return { eliminatedIndex: loserIndex, roundEnded: false, scores: [...this.scores] };
    }
    this.eliminatedThisRound.add(loserIndex);
    this.lastRoundLoser = loserIndex; // 2인 호환: 마지막 탈락자

    const active: number[] = [];
    for (let i = 0; i < this.playerCount; i++) {
      if (!this.eliminatedThisRound.has(i)) active.push(i);
    }

    if (active.length <= 1) {
      // 라운드 종료 — 마지막 생존자 승리(전원 탈락이면 승자 없음)
      this.roundState = 'finished';
      const winnerIndex = active.length === 1 ? active[0] : -1;
      if (winnerIndex >= 0) this.scores[winnerIndex]++;
      const roundResult = { round: this.currentRound, winnerIndex, reason };
      this.roundResults.push(roundResult);
      return {
        eliminatedIndex: loserIndex,
        roundEnded: true,
        winnerIndex: winnerIndex >= 0 ? winnerIndex : undefined,
        scores: [...this.scores],
        roundResult,
      };
    }

    // 라운드 계속 — 탈락자가 '현재 턴'이었을 때만 다음 생존자로 턴 이동.
    // (이탈 등으로 현재 턴이 아닌 사람이 탈락하면 진행 중인 턴은 유지)
    if (loserIndex === this.currentTurnPlayer) {
      this.currentTurnPlayer = this.nextActivePlayer(loserIndex);
    }
    return {
      eliminatedIndex: loserIndex,
      roundEnded: false,
      nextPlayer: this.currentTurnPlayer,
      scores: [...this.scores],
    };
  }

  /** 타임아웃 — 현재 턴 플레이어 탈락 */
  handleTimeout() {
    return this.eliminate(this.currentTurnPlayer, 'timeout');
  }

  /** [N인] 플레이어 영구 이탈(끊김/나감). 이후 모든 라운드·승자에서 제외. */
  markLeft(index: number) {
    this.leftPlayers.add(index);
    // 진행 중인 라운드에서도 탈락 처리(턴이면 다음 사람으로 넘어감)
    if (this.roundState === 'playing' && !this.eliminatedThisRound.has(index)) {
      return this.eliminate(index, 'left');
    }
    return { eliminatedIndex: index, roundEnded: false, scores: [...this.scores] };
  }

  /**
   * 게임 종료 여부 확인
   */
  checkGameOver(): boolean {
    // 누가 2라운드 선취 / 비이탈 1명 이하 / (2인 한정)최대 라운드 도달
    if (this.scores.some(s => s >= HunminGame.ROUNDS_TO_WIN)) return true;
    if (this.playerCount - this.leftPlayers.size <= 1) return true;
    if (this.playerCount === 2 && this.currentRound >= HunminGame.MAX_ROUNDS) return true;
    return false;
  }

  /**
   * 승자 반환 (null이면 무승부). 이탈자는 승자 후보에서 제외.
   */
  getWinner(): number | null {
    let best = -1;
    let leaders: number[] = [];
    for (let i = 0; i < this.playerCount; i++) {
      if (this.leftPlayers.has(i)) continue;
      if (this.scores[i] > best) { best = this.scores[i]; leaders = [i]; }
      else if (this.scores[i] === best) leaders.push(i);
    }
    return leaders.length === 1 ? leaders[0] : null;
  }

  /**
   * 게임 리셋
   */
  reset(): void {
    this.scores = new Array(this.playerCount).fill(0);
    this.currentRound = 0;
    this.roundState = 'waiting';
    this.currentChosung = '';
    this.usedWords = [];
    this.currentTurnPlayer = 0;
    this.lastRoundLoser = null;
    this.roundResults = [];
    this.eliminatedThisRound = new Set();
    this.leftPlayers = new Set();
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
