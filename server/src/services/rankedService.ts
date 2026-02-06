import { getPool } from '../config/database';

// 티어 정의
export interface TierInfo {
  name: string;
  minElo: number;
  maxElo: number;
  color: string;
}

export const TIERS: TierInfo[] = [
  { name: 'Iron', minElo: 0, maxElo: 799, color: '#5C5C5C' },
  { name: 'Bronze', minElo: 800, maxElo: 999, color: '#CD7F32' },
  { name: 'Silver', minElo: 1000, maxElo: 1199, color: '#C0C0C0' },
  { name: 'Gold', minElo: 1200, maxElo: 1399, color: '#FFD700' },
  { name: 'Platinum', minElo: 1400, maxElo: 1599, color: '#00CED1' },
  { name: 'Diamond', minElo: 1600, maxElo: 1799, color: '#B9F2FF' },
  { name: 'Master', minElo: 1800, maxElo: 1999, color: '#9B59B6' },
  { name: 'Challenger', minElo: 2000, maxElo: 9999, color: '#FF4500' },
];

// 랭크 게임 목록 (오목, 무한틱택토 제외)
export const RANKED_GAMES = [
  'tictactoe',
  'sequence',
  'stroop',
  'reaction',
  'rps',
  'speedtap',
];

// 하드코어 모드 게임 (랭크전에서 자동 하드코어)
export const HARDCORE_GAMES = ['tictactoe', 'sequence', 'stroop'];

// 기본 ELO
export const DEFAULT_ELO = 1200;

export interface RankedStats {
  elo: number;
  tier: string;
  tierColor: string;
  wins: number;
  losses: number;
  winStreak: number;
  maxWinStreak: number;
  winRate: number;
  totalGames: number;
}

export interface LeaderboardEntry {
  rank: number;
  userId: number;
  nickname: string;
  elo: number;
  tier: string;
  tierColor: string;
  wins: number;
  losses: number;
  winRate: number;
}

export const rankedService = {
  // ELO로 티어 계산
  getTierFromElo(elo: number): TierInfo {
    for (let i = TIERS.length - 1; i >= 0; i--) {
      if (elo >= TIERS[i].minElo) {
        return TIERS[i];
      }
    }
    return TIERS[0]; // Iron
  },

  // ELO 변동 계산
  calculateEloChange(winnerElo: number, loserElo: number): { winnerGain: number; loserLoss: number } {
    // K-factor: Master 이상은 16, 그 외는 32
    const winnerTier = this.getTierFromElo(winnerElo);
    const loserTier = this.getTierFromElo(loserElo);

    const winnerK = winnerTier.name === 'Master' || winnerTier.name === 'Challenger' ? 16 : 32;
    const loserK = loserTier.name === 'Master' || loserTier.name === 'Challenger' ? 16 : 32;

    // 예상 승률 계산
    const expectedWinner = 1 / (1 + Math.pow(10, (loserElo - winnerElo) / 400));
    const expectedLoser = 1 / (1 + Math.pow(10, (winnerElo - loserElo) / 400));

    // ELO 변동
    const winnerGain = Math.round(winnerK * (1 - expectedWinner));
    const loserLoss = Math.round(loserK * expectedLoser);

    return { winnerGain, loserLoss };
  },

  // 유저 랭크 통계 조회 (없으면 생성)
  async getRankedStats(userId: number): Promise<RankedStats> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 기존 통계 조회
    let result = await pool.query(
      'SELECT * FROM dm_user_ranked_stats WHERE user_id = $1',
      [userId]
    );

    // 없으면 생성
    if (result.rows.length === 0) {
      await pool.query(
        'INSERT INTO dm_user_ranked_stats (user_id) VALUES ($1)',
        [userId]
      );
      result = await pool.query(
        'SELECT * FROM dm_user_ranked_stats WHERE user_id = $1',
        [userId]
      );
    }

    const stats = result.rows[0];
    const tier = this.getTierFromElo(stats.elo);
    const totalGames = stats.wins + stats.losses;
    const winRate = totalGames > 0 ? Math.round((stats.wins / totalGames) * 100) : 0;

    return {
      elo: stats.elo,
      tier: tier.name,
      tierColor: tier.color,
      wins: stats.wins,
      losses: stats.losses,
      winStreak: stats.win_streak,
      maxWinStreak: stats.max_win_streak,
      winRate,
      totalGames,
    };
  },

  // 리더보드 조회
  async getLeaderboard(limit: number = 100, offset: number = 0): Promise<LeaderboardEntry[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT
        urs.user_id,
        u.nickname,
        urs.elo,
        urs.tier,
        urs.wins,
        urs.losses
       FROM dm_user_ranked_stats urs
       JOIN dm_users u ON urs.user_id = u.id
       ORDER BY urs.elo DESC, urs.wins DESC
       LIMIT $1 OFFSET $2`,
      [limit, offset]
    );

    return result.rows.map((row, index) => {
      const tier = this.getTierFromElo(row.elo);
      const totalGames = row.wins + row.losses;
      const winRate = totalGames > 0 ? Math.round((row.wins / totalGames) * 100) : 0;

      return {
        rank: offset + index + 1,
        userId: row.user_id,
        nickname: row.nickname,
        elo: row.elo,
        tier: tier.name,
        tierColor: tier.color,
        wins: row.wins,
        losses: row.losses,
        winRate,
      };
    });
  },

  // 유저 순위 조회
  async getUserRank(userId: number): Promise<number> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 먼저 해당 유저의 ELO를 조회
    const userResult = await pool.query(
      'SELECT elo, wins FROM dm_user_ranked_stats WHERE user_id = $1',
      [userId]
    );

    if (userResult.rows.length === 0) {
      // 랭크 통계가 없으면 생성 후 순위 반환
      await this.getRankedStats(userId);
      return await this.getUserRank(userId);
    }

    const { elo, wins } = userResult.rows[0];

    // 해당 유저보다 높은 ELO (또는 같은 ELO에서 더 많은 승리)를 가진 유저 수 + 1
    const result = await pool.query(
      `SELECT COUNT(*) as rank FROM dm_user_ranked_stats
       WHERE elo > $1 OR (elo = $1 AND wins > $2)`,
      [elo, wins]
    );

    return parseInt(result.rows[0].rank) + 1;
  },

  // 랭크전 결과 반영
  async updateRankedResult(
    winnerId: number,
    loserId: number,
    gamesPlayed: { gameType: string; winnerId: number }[]
  ): Promise<{
    winnerStats: RankedStats;
    loserStats: RankedStats;
    winnerEloChange: number;
    loserEloChange: number;
  }> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 현재 통계 조회
    const winnerStatsBefore = await this.getRankedStats(winnerId);
    const loserStatsBefore = await this.getRankedStats(loserId);

    // ELO 변동 계산
    const { winnerGain, loserLoss } = this.calculateEloChange(
      winnerStatsBefore.elo,
      loserStatsBefore.elo
    );

    // 새 ELO 계산 (최소 0)
    const newWinnerElo = winnerStatsBefore.elo + winnerGain;
    const newLoserElo = Math.max(0, loserStatsBefore.elo - loserLoss);

    // 새 티어 계산
    const newWinnerTier = this.getTierFromElo(newWinnerElo);
    const newLoserTier = this.getTierFromElo(newLoserElo);

    // 승자 통계 업데이트
    const newWinStreak = winnerStatsBefore.winStreak + 1;
    const newMaxWinStreak = Math.max(winnerStatsBefore.maxWinStreak, newWinStreak);

    await pool.query(
      `UPDATE dm_user_ranked_stats
       SET elo = $1, tier = $2, wins = wins + 1,
           win_streak = $3, max_win_streak = $4,
           updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $5`,
      [newWinnerElo, newWinnerTier.name, newWinStreak, newMaxWinStreak, winnerId]
    );

    // 패자 통계 업데이트
    await pool.query(
      `UPDATE dm_user_ranked_stats
       SET elo = $1, tier = $2, losses = losses + 1,
           win_streak = 0,
           updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $3`,
      [newLoserElo, newLoserTier.name, loserId]
    );

    // 매치 기록 저장
    await pool.query(
      `INSERT INTO dm_ranked_matches
       (player1_id, player2_id, winner_id, games_played,
        player1_elo_before, player2_elo_before, player1_elo_after, player2_elo_after)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        winnerId,
        loserId,
        winnerId,
        JSON.stringify(gamesPlayed),
        winnerStatsBefore.elo,
        loserStatsBefore.elo,
        newWinnerElo,
        newLoserElo,
      ]
    );

    // 업데이트된 통계 반환
    const winnerStats = await this.getRankedStats(winnerId);
    const loserStats = await this.getRankedStats(loserId);

    return {
      winnerStats,
      loserStats,
      winnerEloChange: winnerGain,
      loserEloChange: -loserLoss,
    };
  },

  // 랜덤 게임 3개 선택
  selectRandomGames(): string[] {
    const shuffled = [...RANKED_GAMES].sort(() => Math.random() - 0.5);
    return shuffled.slice(0, 3);
  },

  // 게임이 하드코어 모드인지 확인
  isHardcoreGame(gameType: string): boolean {
    return HARDCORE_GAMES.includes(gameType);
  },

  // 무승부 결과 반영 (LP 높은 쪽이 30% 페널티로 패배)
  async updateRankedResultAsDraw(
    winnerId: number,
    loserId: number,
    gamesPlayed: { gameType: string; winnerId: number }[]
  ): Promise<{
    winnerStats: RankedStats;
    loserStats: RankedStats;
    winnerEloChange: number;
    loserEloChange: number;
  }> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 현재 통계 조회
    const winnerStatsBefore = await this.getRankedStats(winnerId);
    const loserStatsBefore = await this.getRankedStats(loserId);

    // ELO 변동 계산 (정상 계산 후 30% 적용)
    const { winnerGain, loserLoss } = this.calculateEloChange(
      winnerStatsBefore.elo,
      loserStatsBefore.elo
    );

    // 무승부이므로 30%만 적용
    const reducedWinnerGain = Math.round(winnerGain * 0.3);
    const reducedLoserLoss = Math.round(loserLoss * 0.3);

    // 새 ELO 계산 (최소 0)
    const newWinnerElo = winnerStatsBefore.elo + reducedWinnerGain;
    const newLoserElo = Math.max(0, loserStatsBefore.elo - reducedLoserLoss);

    // 새 티어 계산
    const newWinnerTier = this.getTierFromElo(newWinnerElo);
    const newLoserTier = this.getTierFromElo(newLoserElo);

    // 승자 통계 업데이트 (무승부이므로 연승은 유지하되 증가하지 않음, wins도 증가하지 않음)
    await pool.query(
      `UPDATE dm_user_ranked_stats
       SET elo = $1, tier = $2,
           updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $3`,
      [newWinnerElo, newWinnerTier.name, winnerId]
    );

    // 패자 통계 업데이트 (무승부이므로 연승만 리셋, losses도 증가하지 않음)
    await pool.query(
      `UPDATE dm_user_ranked_stats
       SET elo = $1, tier = $2, win_streak = 0,
           updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $3`,
      [newLoserElo, newLoserTier.name, loserId]
    );

    // 매치 기록 저장 (무승부로 표시)
    await pool.query(
      `INSERT INTO dm_ranked_matches
       (player1_id, player2_id, winner_id, games_played,
        player1_elo_before, player2_elo_before, player1_elo_after, player2_elo_after)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        winnerId,
        loserId,
        null,  // 무승부이므로 winner_id는 null
        JSON.stringify(gamesPlayed),
        winnerStatsBefore.elo,
        loserStatsBefore.elo,
        newWinnerElo,
        newLoserElo,
      ]
    );

    // 업데이트된 통계 반환
    const winnerStats = await this.getRankedStats(winnerId);
    const loserStats = await this.getRankedStats(loserId);

    return {
      winnerStats,
      loserStats,
      winnerEloChange: reducedWinnerGain,
      loserEloChange: -reducedLoserLoss,
    };
  },
};
