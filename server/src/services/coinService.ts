import { getPool } from '../config/database';

// 코인 보상 설정
const COIN_REWARDS = {
  WIN: 5,
  LOSE: 2,
  DRAW: 3,
  STREAK_BONUS: 10,  // 5연승 보너스
  AD_WATCH: 10,
  DAILY_FIRST_GAME: 5,
};

// 연승 설정
const STREAK_CONFIG = {
  BONUS_AT: 5,  // 5연승 시 보너스
  DAILY_SAME_OPPONENT_LIMIT: 5,  // 같은 상대 일일 5회 제한
};

export interface StreakInfo {
  currentStreak: number;
  updatedAt: Date | null;
}

export interface GameRewardResult {
  coinsEarned: number;
  totalCoins: number;
  streakBefore: number;
  streakAfter: number;
  streakBonusEarned: boolean;
  streakCountedThisGame: boolean;  // 연승 카운트 됐는지
  dailyMatchCount: number;  // 오늘 이 상대와 몇 번째
  message?: string;
}

export const coinService = {
  // 코인 조회 (기존 마일리지 테이블 사용)
  async getCoins(userId: number): Promise<number> {
    const pool = getPool();
    if (!pool) return 0;

    const result = await pool.query(
      'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
      [userId]
    );

    return result.rows.length > 0 ? result.rows[0].mileage : 0;
  },

  // 코인 추가
  async addCoins(userId: number, amount: number, reason: string): Promise<number> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 레코드 확인/생성
    const existing = await pool.query(
      'SELECT * FROM dm_user_mileage WHERE user_id = $1',
      [userId]
    );

    if (existing.rows.length === 0) {
      await pool.query(
        'INSERT INTO dm_user_mileage (user_id, mileage) VALUES ($1, $2)',
        [userId, amount]
      );
    } else {
      await pool.query(
        'UPDATE dm_user_mileage SET mileage = mileage + $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [amount, userId]
      );
    }

    // 기록 저장
    await pool.query(
      'INSERT INTO dm_mileage_history (user_id, amount, reason) VALUES ($1, $2, $3)',
      [userId, amount, reason]
    );

    const result = await pool.query(
      'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
      [userId]
    );

    return result.rows[0].mileage;
  },

  // 연승 정보 조회
  async getStreak(userId: number): Promise<StreakInfo> {
    const pool = getPool();
    if (!pool) return { currentStreak: 0, updatedAt: null };

    const result = await pool.query(
      'SELECT current_streak, updated_at FROM dm_user_streak WHERE user_id = $1',
      [userId]
    );

    if (result.rows.length === 0) {
      return { currentStreak: 0, updatedAt: null };
    }

    return {
      currentStreak: result.rows[0].current_streak,
      updatedAt: result.rows[0].updated_at,
    };
  },

  // 오늘 특정 상대와 게임 횟수 조회
  async getDailyMatchCount(userId: number, opponentId: number): Promise<number> {
    const pool = getPool();
    if (!pool) return 0;

    const result = await pool.query(
      `SELECT count FROM dm_daily_match_count
       WHERE user_id = $1 AND opponent_id = $2 AND match_date = CURRENT_DATE`,
      [userId, opponentId]
    );

    return result.rows.length > 0 ? result.rows[0].count : 0;
  },

  // 일일 매치 카운트 증가
  async incrementDailyMatchCount(userId: number, opponentId: number): Promise<number> {
    const pool = getPool();
    if (!pool) return 0;

    await pool.query(
      `INSERT INTO dm_daily_match_count (user_id, opponent_id, match_date, count)
       VALUES ($1, $2, CURRENT_DATE, 1)
       ON CONFLICT (user_id, opponent_id, match_date)
       DO UPDATE SET count = dm_daily_match_count.count + 1`,
      [userId, opponentId]
    );

    const result = await pool.query(
      `SELECT count FROM dm_daily_match_count
       WHERE user_id = $1 AND opponent_id = $2 AND match_date = CURRENT_DATE`,
      [userId, opponentId]
    );

    return result.rows[0].count;
  },

  // 연승 업데이트
  async updateStreak(userId: number, newStreak: number): Promise<void> {
    const pool = getPool();
    if (!pool) return;

    await pool.query(
      `INSERT INTO dm_user_streak (user_id, current_streak, updated_at)
       VALUES ($1, $2, CURRENT_TIMESTAMP)
       ON CONFLICT (user_id)
       DO UPDATE SET current_streak = $2, updated_at = CURRENT_TIMESTAMP`,
      [userId, newStreak]
    );
  },

  // 게임 종료 시 보상 처리
  async processGameReward(
    userId: number,
    opponentId: number,
    result: 'win' | 'loss' | 'draw'
  ): Promise<GameRewardResult> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 현재 연승 정보
    const streakInfo = await this.getStreak(userId);
    const streakBefore = streakInfo.currentStreak;

    // 일일 매치 카운트 증가
    const dailyMatchCount = await this.incrementDailyMatchCount(userId, opponentId);

    // 기본 코인 계산
    let coinsEarned = 0;
    if (result === 'win') {
      coinsEarned = COIN_REWARDS.WIN;
    } else if (result === 'loss') {
      coinsEarned = COIN_REWARDS.LOSE;
    } else {
      coinsEarned = COIN_REWARDS.DRAW;
    }

    let streakAfter = streakBefore;
    let streakBonusEarned = false;
    let streakCountedThisGame = false;
    let message: string | undefined;

    // 승리 시 연승 처리
    if (result === 'win') {
      // 일일 제한 체크
      if (dailyMatchCount <= STREAK_CONFIG.DAILY_SAME_OPPONENT_LIMIT) {
        // 연승 카운트 가능
        streakAfter = streakBefore + 1;
        streakCountedThisGame = true;

        // 5연승 보너스 체크
        if (streakAfter >= STREAK_CONFIG.BONUS_AT) {
          coinsEarned += COIN_REWARDS.STREAK_BONUS;
          streakBonusEarned = true;
          streakAfter = 0;  // 리셋
          message = `🔥 ${STREAK_CONFIG.BONUS_AT}연승 달성! +${COIN_REWARDS.STREAK_BONUS} 보너스!`;
        }
      } else {
        // 일일 제한 초과 - 연승 유지만 (카운트 안 함)
        message = `이 상대와 오늘 ${dailyMatchCount}회째 - 연승 카운트 제외`;
      }
    } else {
      // 패배/무승부 시 연승 리셋
      if (result === 'loss' && streakBefore > 0) {
        message = `💔 ${streakBefore}연승 끊김...`;
      }
      streakAfter = 0;
    }

    // 연승 업데이트
    await this.updateStreak(userId, streakAfter);

    // 코인 지급
    const totalCoins = await this.addCoins(userId, coinsEarned, `game_${result}`);

    return {
      coinsEarned,
      totalCoins,
      streakBefore,
      streakAfter,
      streakBonusEarned,
      streakCountedThisGame,
      dailyMatchCount,
      message,
    };
  },

  // 오래된 dm_daily_match_count 정리 (7일 이상)
  async cleanupOldMatchCounts(): Promise<void> {
    const pool = getPool();
    if (!pool) return;

    await pool.query(
      `DELETE FROM dm_daily_match_count WHERE match_date < CURRENT_DATE - INTERVAL '7 days'`
    );
  },
};
