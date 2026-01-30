import { getPool } from '../config/database';

export interface GameRecord {
  id: number;
  gameType: string;
  opponentNickname: string;
  result: 'win' | 'loss' | 'draw';
  expGained: number;
  createdAt: string;
}

export interface GameStats {
  gameType: string;
  wins: number;
  losses: number;
  draws: number;
  level: number;
  exp: number;
  winRate: number;
  totalGames: number;
  expToNextLevel: number;
}

export interface UserMileage {
  mileage: number;
}

// 레벨별 필요 경험치 계산 (레벨이 올라갈수록 더 많은 경험치 필요)
function getExpForLevel(level: number): number {
  return level * 100; // 레벨 1: 100, 레벨 2: 200, ...
}

// 경험치 획득량
const EXP_WIN = 30;
const EXP_LOSE = 10;
const EXP_DRAW = 15;

// 결과에 따른 경험치 반환
function getExpForResult(result: 'win' | 'loss' | 'draw'): number {
  switch (result) {
    case 'win': return EXP_WIN;
    case 'loss': return EXP_LOSE;
    case 'draw': return EXP_DRAW;
  }
}

export const statsService = {
  // 게임 결과 기록 및 통계 업데이트
  async recordGameResult(
    userId: number,
    gameType: string,
    result: 'win' | 'loss' | 'draw'
  ): Promise<GameStats> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 기존 통계 조회 또는 생성
    let stats = await pool.query(
      'SELECT * FROM user_game_stats WHERE user_id = $1 AND game_type = $2',
      [userId, gameType]
    );

    if (stats.rows.length === 0) {
      await pool.query(
        'INSERT INTO user_game_stats (user_id, game_type) VALUES ($1, $2)',
        [userId, gameType]
      );
      stats = await pool.query(
        'SELECT * FROM user_game_stats WHERE user_id = $1 AND game_type = $2',
        [userId, gameType]
      );
    }

    const currentStats = stats.rows[0];
    let { wins, losses, draws, level, exp } = currentStats;

    // 결과에 따른 업데이트
    let expGain = 0;
    if (result === 'win') {
      wins++;
      expGain = EXP_WIN;
    } else if (result === 'loss') {
      losses++;
      expGain = EXP_LOSE;
    } else {
      draws++;
      expGain = EXP_DRAW;
    }

    exp += expGain;

    // 레벨업 체크
    let expNeeded = getExpForLevel(level);
    while (exp >= expNeeded) {
      exp -= expNeeded;
      level++;
      expNeeded = getExpForLevel(level);
    }

    // 통계 업데이트
    await pool.query(
      `UPDATE user_game_stats
       SET wins = $1, losses = $2, draws = $3, level = $4, exp = $5, updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $6 AND game_type = $7`,
      [wins, losses, draws, level, exp, userId, gameType]
    );

    const totalGames = wins + losses + draws;
    const winRate = totalGames > 0 ? Math.round((wins / totalGames) * 100) : 0;

    return {
      gameType,
      wins,
      losses,
      draws,
      level,
      exp,
      winRate,
      totalGames,
      expToNextLevel: getExpForLevel(level),
    };
  },

  // 탈주 시 전적만 기록 (경험치 없음)
  async recordGameResultNoExp(
    userId: number,
    gameType: string,
    result: 'win' | 'loss'
  ): Promise<GameStats> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 기존 통계 조회 또는 생성
    let stats = await pool.query(
      'SELECT * FROM user_game_stats WHERE user_id = $1 AND game_type = $2',
      [userId, gameType]
    );

    if (stats.rows.length === 0) {
      await pool.query(
        'INSERT INTO user_game_stats (user_id, game_type) VALUES ($1, $2)',
        [userId, gameType]
      );
      stats = await pool.query(
        'SELECT * FROM user_game_stats WHERE user_id = $1 AND game_type = $2',
        [userId, gameType]
      );
    }

    const currentStats = stats.rows[0];
    let { wins, losses, draws, level, exp } = currentStats;

    // 결과에 따른 업데이트 (경험치 없음)
    if (result === 'win') {
      wins++;
    } else {
      losses++;
    }

    // 통계 업데이트
    await pool.query(
      `UPDATE user_game_stats
       SET wins = $1, losses = $2, draws = $3, updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $4 AND game_type = $5`,
      [wins, losses, draws, userId, gameType]
    );

    const totalGames = wins + losses + draws;
    const winRate = totalGames > 0 ? Math.round((wins / totalGames) * 100) : 0;

    return {
      gameType,
      wins,
      losses,
      draws,
      level,
      exp,
      winRate,
      totalGames,
      expToNextLevel: getExpForLevel(level),
    };
  },

  // 탈주 게임 기록 저장 (경험치 0)
  async saveGameRecordNoExp(
    userId: number,
    opponentId: number,
    gameType: string,
    result: 'win' | 'loss'
  ): Promise<void> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    await pool.query(
      `INSERT INTO game_records (game_type, player1_id, player2_id, winner_id, game_data)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        gameType,
        userId,
        opponentId,
        result === 'win' ? userId : opponentId,
        JSON.stringify({ result, expGained: 0, isQuit: true })
      ]
    );
  },

  // 특정 게임 통계 조회
  async getGameStats(userId: number, gameType: string): Promise<GameStats> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      'SELECT * FROM user_game_stats WHERE user_id = $1 AND game_type = $2',
      [userId, gameType]
    );

    if (result.rows.length === 0) {
      return {
        gameType,
        wins: 0,
        losses: 0,
        draws: 0,
        level: 1,
        exp: 0,
        winRate: 0,
        totalGames: 0,
        expToNextLevel: getExpForLevel(1),
      };
    }

    const stats = result.rows[0];
    const totalGames = stats.wins + stats.losses + stats.draws;
    const winRate = totalGames > 0 ? Math.round((stats.wins / totalGames) * 100) : 0;

    return {
      gameType: stats.game_type,
      wins: stats.wins,
      losses: stats.losses,
      draws: stats.draws,
      level: stats.level,
      exp: stats.exp,
      winRate,
      totalGames,
      expToNextLevel: getExpForLevel(stats.level),
    };
  },

  // 모든 게임 통계 조회
  async getAllGameStats(userId: number): Promise<GameStats[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      'SELECT * FROM user_game_stats WHERE user_id = $1',
      [userId]
    );

    const gameTypes = ['tictactoe', 'infinite_tictactoe', 'gomoku', 'reaction', 'rps'];
    const statsMap = new Map<string, any>();

    result.rows.forEach(row => {
      statsMap.set(row.game_type, row);
    });

    return gameTypes.map(gameType => {
      const stats = statsMap.get(gameType);
      if (!stats) {
        return {
          gameType,
          wins: 0,
          losses: 0,
          draws: 0,
          level: 1,
          exp: 0,
          winRate: 0,
          totalGames: 0,
          expToNextLevel: getExpForLevel(1),
        };
      }

      const totalGames = stats.wins + stats.losses + stats.draws;
      const winRate = totalGames > 0 ? Math.round((stats.wins / totalGames) * 100) : 0;

      return {
        gameType: stats.game_type,
        wins: stats.wins,
        losses: stats.losses,
        draws: stats.draws,
        level: stats.level,
        exp: stats.exp,
        winRate,
        totalGames,
        expToNextLevel: getExpForLevel(stats.level),
      };
    });
  },

  // 승률 초기화
  async resetStats(userId: number, gameType: string): Promise<{ success: boolean; message: string }> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `UPDATE user_game_stats
       SET wins = 0, losses = 0, draws = 0, updated_at = CURRENT_TIMESTAMP
       WHERE user_id = $1 AND game_type = $2`,
      [userId, gameType]
    );

    if (result.rowCount === 0) {
      return { success: false, message: '통계를 찾을 수 없습니다.' };
    }

    return { success: true, message: '승률이 초기화되었습니다.' };
  },

  // 마일리지 조회
  async getMileage(userId: number): Promise<number> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      'SELECT mileage FROM user_mileage WHERE user_id = $1',
      [userId]
    );

    return result.rows.length > 0 ? result.rows[0].mileage : 0;
  },

  // 마일리지 추가
  async addMileage(userId: number, amount: number, reason: string): Promise<number> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    // 마일리지 레코드 확인/생성
    const existing = await pool.query(
      'SELECT * FROM user_mileage WHERE user_id = $1',
      [userId]
    );

    if (existing.rows.length === 0) {
      await pool.query(
        'INSERT INTO user_mileage (user_id, mileage) VALUES ($1, $2)',
        [userId, amount]
      );
    } else {
      await pool.query(
        'UPDATE user_mileage SET mileage = mileage + $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [amount, userId]
      );
    }

    // 기록 저장
    await pool.query(
      'INSERT INTO mileage_history (user_id, amount, reason) VALUES ($1, $2, $3)',
      [userId, amount, reason]
    );

    const result = await pool.query(
      'SELECT mileage FROM user_mileage WHERE user_id = $1',
      [userId]
    );

    return result.rows[0].mileage;
  },

  // 마일리지 차감
  async useMileage(userId: number, amount: number, reason: string): Promise<{ success: boolean; message: string; mileage: number }> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const current = await this.getMileage(userId);

    if (current < amount) {
      return { success: false, message: '마일리지가 부족합니다.', mileage: current };
    }

    await pool.query(
      'UPDATE user_mileage SET mileage = mileage - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
      [amount, userId]
    );

    // 기록 저장 (음수로)
    await pool.query(
      'INSERT INTO mileage_history (user_id, amount, reason) VALUES ($1, $2, $3)',
      [userId, -amount, reason]
    );

    const result = await pool.query(
      'SELECT mileage FROM user_mileage WHERE user_id = $1',
      [userId]
    );

    return { success: true, message: '마일리지가 사용되었습니다.', mileage: result.rows[0].mileage };
  },

  // 게임 기록 저장
  async saveGameRecord(
    userId: number,
    opponentId: number,
    gameType: string,
    result: 'win' | 'loss' | 'draw'
  ): Promise<void> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const expGained = getExpForResult(result);

    await pool.query(
      `INSERT INTO game_records (game_type, player1_id, player2_id, winner_id, game_data)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        gameType,
        userId,
        opponentId,
        result === 'win' ? userId : (result === 'loss' ? opponentId : null),
        JSON.stringify({ result, expGained })
      ]
    );
  },

  // 최근 게임 기록 조회
  async getRecentRecords(userId: number, limit: number = 20): Promise<GameRecord[]> {
    const pool = getPool();
    if (!pool) throw new Error('Database not connected');

    const result = await pool.query(
      `SELECT
        gr.id,
        gr.game_type,
        gr.winner_id,
        gr.game_data,
        gr.created_at,
        CASE
          WHEN gr.player1_id = $1 THEN u2.nickname
          ELSE u1.nickname
        END as opponent_nickname
       FROM game_records gr
       LEFT JOIN users u1 ON gr.player1_id = u1.id
       LEFT JOIN users u2 ON gr.player2_id = u2.id
       WHERE gr.player1_id = $1 OR gr.player2_id = $1
       ORDER BY gr.created_at DESC
       LIMIT $2`,
      [userId, limit]
    );

    return result.rows.map(row => {
      let recordResult: 'win' | 'loss' | 'draw';
      if (row.winner_id === null) {
        recordResult = 'draw';
      } else if (row.winner_id === userId) {
        recordResult = 'win';
      } else {
        recordResult = 'loss';
      }

      const gameData = row.game_data || {};

      return {
        id: row.id,
        gameType: row.game_type,
        opponentNickname: row.opponent_nickname || '알 수 없음',
        result: recordResult,
        expGained: getExpForResult(recordResult),
        createdAt: row.created_at.toISOString(),
      };
    });
  },
};
