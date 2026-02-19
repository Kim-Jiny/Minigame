import { getPool } from '../config/database';

export interface ShopItem {
  id: number;
  category: string;
  itemKey: string;
  name: string;
  description: string;
  price: number;
  durationDays: number | null;
  rarity: string;
  previewData: any;
  sortOrder: number;
  isActive: boolean;
  isDefault: boolean;
}

export interface UserItem {
  id: number;
  userId: number;
  itemId: number;
  purchasedAt: Date;
  expiresAt: Date | null;
  item?: ShopItem;
}

export interface UserProfileSettings {
  userId: number;
  activeFrameId: number | null;
  activeTitleId: number | null;
  activeThemeId: number | null;
  activeAvatarId: number | null;
  activeFrame?: ShopItem | null;
  activeTitle?: ShopItem | null;
  activeTheme?: ShopItem | null;
  activeAvatar?: ShopItem | null;
}

function mapShopItem(row: any): ShopItem {
  return {
    id: row.id,
    category: row.category,
    itemKey: row.item_key,
    name: row.name,
    description: row.description,
    price: row.price,
    durationDays: row.duration_days,
    rarity: row.rarity,
    previewData: row.preview_data,
    sortOrder: row.sort_order,
    isActive: row.is_active,
    isDefault: row.is_default,
  };
}

export const shopService = {
  // 상점 아이템 목록 조회
  async getShopItems(category?: string): Promise<ShopItem[]> {
    const pool = getPool();
    if (!pool) return [];

    let query = 'SELECT * FROM dm_shop_items WHERE is_active = TRUE';
    const params: any[] = [];

    if (category) {
      query += ' AND category = $1';
      params.push(category);
    }

    query += ' ORDER BY category, sort_order, price';

    const result = await pool.query(query, params);
    return result.rows.map(mapShopItem);
  },

  // 유저 보유 아이템 목록 조회
  async getUserItems(userId: number): Promise<UserItem[]> {
    const pool = getPool();
    if (!pool) return [];

    const result = await pool.query(
      `SELECT ui.*, si.category, si.item_key, si.name, si.description, si.price,
              si.duration_days, si.rarity, si.preview_data, si.sort_order, si.is_active, si.is_default
       FROM dm_user_items ui
       JOIN dm_shop_items si ON ui.item_id = si.id
       WHERE ui.user_id = $1
       AND (ui.expires_at IS NULL OR ui.expires_at > CURRENT_TIMESTAMP)
       ORDER BY si.category, si.sort_order`,
      [userId]
    );

    return result.rows.map(row => ({
      id: row.id,
      userId: row.user_id,
      itemId: row.item_id,
      purchasedAt: row.purchased_at,
      expiresAt: row.expires_at,
      item: mapShopItem(row),
    }));
  },

  // 유저 프로필 설정 조회
  async getUserProfileSettings(userId: number): Promise<UserProfileSettings> {
    const pool = getPool();
    if (!pool) {
      return { userId, activeFrameId: null, activeTitleId: null, activeThemeId: null, activeAvatarId: null };
    }

    // 설정 조회
    const settingsResult = await pool.query(
      'SELECT * FROM dm_user_profile_settings WHERE user_id = $1',
      [userId]
    );

    let settings: UserProfileSettings;

    if (settingsResult.rows.length === 0) {
      // 기본 설정 생성
      await pool.query(
        `INSERT INTO dm_user_profile_settings (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING`,
        [userId]
      );
      settings = { userId, activeFrameId: null, activeTitleId: null, activeThemeId: null, activeAvatarId: null };
    } else {
      const row = settingsResult.rows[0];
      settings = {
        userId: row.user_id,
        activeFrameId: row.active_frame_id,
        activeTitleId: row.active_title_id,
        activeThemeId: row.active_theme_id,
        activeAvatarId: row.active_avatar_id,
      };
    }

    // 장착 아이템 상세 조회
    if (settings.activeFrameId) {
      const frameResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1', [settings.activeFrameId]);
      if (frameResult.rows.length > 0) {
        settings.activeFrame = mapShopItem(frameResult.rows[0]);
      }
    }
    if (settings.activeTitleId) {
      const titleResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1', [settings.activeTitleId]);
      if (titleResult.rows.length > 0) {
        settings.activeTitle = mapShopItem(titleResult.rows[0]);
      }
    }
    if (settings.activeThemeId) {
      const themeResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1', [settings.activeThemeId]);
      if (themeResult.rows.length > 0) {
        settings.activeTheme = mapShopItem(themeResult.rows[0]);
      }
    }
    if (settings.activeAvatarId) {
      const avatarResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1', [settings.activeAvatarId]);
      if (avatarResult.rows.length > 0) {
        settings.activeAvatar = mapShopItem(avatarResult.rows[0]);
      }
    }

    return settings;
  },

  // 아이템 구매
  async purchaseItem(userId: number, itemId: number): Promise<{ success: boolean; message: string; item?: UserItem; coins?: number }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    try {
      // 아이템 정보 조회
      const itemResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1 AND is_active = TRUE', [itemId]);
      if (itemResult.rows.length === 0) {
        return { success: false, message: '아이템을 찾을 수 없습니다.' };
      }
      const item = mapShopItem(itemResult.rows[0]);

      // 티켓이 아닌 경우 이미 보유중인지 확인
      if (item.category !== 'ticket') {
        const ownedResult = await pool.query(
          `SELECT * FROM dm_user_items WHERE user_id = $1 AND item_id = $2
           AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)`,
          [userId, itemId]
        );
        if (ownedResult.rows.length > 0) {
          return { success: false, message: '이미 보유 중인 아이템입니다.' };
        }
      }

      // 코인 확인
      const mileageResult = await pool.query('SELECT mileage FROM dm_user_mileage WHERE user_id = $1', [userId]);
      const currentCoins = mileageResult.rows.length > 0 ? mileageResult.rows[0].mileage : 0;

      if (currentCoins < item.price) {
        return { success: false, message: '코인이 부족합니다.', coins: currentCoins };
      }

      // 코인 차감
      await pool.query(
        'UPDATE dm_user_mileage SET mileage = mileage - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [item.price, userId]
      );

      // 기록 저장
      await pool.query(
        'INSERT INTO dm_mileage_history (user_id, amount, reason) VALUES ($1, $2, $3)',
        [userId, -item.price, `purchase_${item.itemKey}`]
      );

      // 만료일 계산
      let expiresAt = null;
      if (item.durationDays) {
        expiresAt = new Date();
        expiresAt.setDate(expiresAt.getDate() + item.durationDays);
      }

      // 티켓은 dm_user_items에 저장하지 않고 바로 반환
      if (item.category === 'ticket') {
        const newBalance = currentCoins - item.price;
        return {
          success: true,
          message: `${item.name}을(를) 구매했습니다!`,
          coins: newBalance,
          item: {
            id: 0,
            userId,
            itemId: item.id,
            purchasedAt: new Date(),
            expiresAt: null,
            item: item,
          }
        };
      }

      // 아이템 지급
      const insertResult = await pool.query(
        `INSERT INTO dm_user_items (user_id, item_id, expires_at)
         VALUES ($1, $2, $3)
         ON CONFLICT (user_id, item_id) DO UPDATE SET expires_at = $3
         RETURNING *`,
        [userId, itemId, expiresAt]
      );

      const newBalance = currentCoins - item.price;

      return {
        success: true,
        message: `${item.name}을(를) 구매했습니다!`,
        coins: newBalance,
        item: {
          id: insertResult.rows[0].id,
          userId: insertResult.rows[0].user_id,
          itemId: insertResult.rows[0].item_id,
          purchasedAt: insertResult.rows[0].purchased_at,
          expiresAt: insertResult.rows[0].expires_at,
          item: item,
        }
      };
    } catch (error) {
      console.error('Purchase item error:', error);
      return { success: false, message: '구매 중 오류가 발생했습니다.' };
    }
  },

  // 아이템 장착
  async equipItem(userId: number, itemId: number): Promise<{ success: boolean; message: string; settings?: UserProfileSettings }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    try {
      // 아이템 정보 조회
      const itemResult = await pool.query('SELECT * FROM dm_shop_items WHERE id = $1', [itemId]);
      if (itemResult.rows.length === 0) {
        return { success: false, message: '아이템을 찾을 수 없습니다.' };
      }
      const item = mapShopItem(itemResult.rows[0]);

      // 장착 가능한 카테고리 확인
      if (!['frame', 'title', 'theme', 'avatar'].includes(item.category)) {
        return { success: false, message: '장착할 수 없는 아이템입니다.' };
      }

      // 기본 아이템이 아닌 경우 보유 여부 확인
      if (!item.isDefault) {
        const ownedResult = await pool.query(
          `SELECT * FROM dm_user_items WHERE user_id = $1 AND item_id = $2
           AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)`,
          [userId, itemId]
        );
        if (ownedResult.rows.length === 0) {
          return { success: false, message: '보유하지 않은 아이템입니다.' };
        }
      }

      // 카테고리별 필드 결정
      let field: string;
      switch (item.category) {
        case 'frame': field = 'active_frame_id'; break;
        case 'title': field = 'active_title_id'; break;
        case 'theme': field = 'active_theme_id'; break;
        case 'avatar': field = 'active_avatar_id'; break;
        default: return { success: false, message: '잘못된 카테고리입니다.' };
      }

      // 프로필 설정 업데이트
      await pool.query(
        `INSERT INTO dm_user_profile_settings (user_id, ${field}, updated_at)
         VALUES ($1, $2, CURRENT_TIMESTAMP)
         ON CONFLICT (user_id) DO UPDATE SET ${field} = $2, updated_at = CURRENT_TIMESTAMP`,
        [userId, itemId]
      );

      const settings = await this.getUserProfileSettings(userId);
      return { success: true, message: `${item.name}을(를) 장착했습니다!`, settings };
    } catch (error) {
      console.error('Equip item error:', error);
      return { success: false, message: '장착 중 오류가 발생했습니다.' };
    }
  },

  // 아이템 장착 해제
  async unequipItem(userId: number, category: string): Promise<{ success: boolean; message: string; settings?: UserProfileSettings }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    try {
      // 카테고리별 필드 결정
      let field: string;
      switch (category) {
        case 'frame': field = 'active_frame_id'; break;
        case 'title': field = 'active_title_id'; break;
        case 'theme': field = 'active_theme_id'; break;
        case 'avatar': field = 'active_avatar_id'; break;
        default: return { success: false, message: '잘못된 카테고리입니다.' };
      }

      // 프로필 설정 업데이트
      await pool.query(
        `UPDATE dm_user_profile_settings SET ${field} = NULL, updated_at = CURRENT_TIMESTAMP WHERE user_id = $1`,
        [userId]
      );

      const settings = await this.getUserProfileSettings(userId);
      return { success: true, message: '장착 해제되었습니다.', settings };
    } catch (error) {
      console.error('Unequip item error:', error);
      return { success: false, message: '장착 해제 중 오류가 발생했습니다.' };
    }
  },

  // 패배 삭제 처리 (코인 차감 포함, count로 삭제 수량 지정)
  async deleteLoss(userId: number, gameType: string, count: number = 1, price: number = 50): Promise<{ success: boolean; message: string; stats?: any; coins?: number }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // 1. 현재 코인(마일리지) 확인
      const coinResult = await client.query(
        'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
        [userId]
      );

      const currentCoins = coinResult.rows.length > 0 ? (coinResult.rows[0].mileage || 0) : 0;
      if (currentCoins < price) {
        await client.query('ROLLBACK');
        return { success: false, message: `코인이 부족합니다. (현재: ${currentCoins}, 필요: ${price})` };
      }

      // 2. 현재 통계 조회
      const statsResult = await client.query(
        'SELECT * FROM dm_user_game_stats WHERE user_id = $1 AND game_type = $2',
        [userId, gameType]
      );

      if (statsResult.rows.length === 0 || statsResult.rows[0].losses <= 0) {
        await client.query('ROLLBACK');
        return { success: false, message: '삭제할 패배 기록이 없습니다.' };
      }

      // 실제 삭제 가능한 수량 (현재 패배 수를 초과하지 않도록)
      const actualCount = Math.min(count, statsResult.rows[0].losses);

      // 3. 코인(마일리지) 차감
      await client.query(
        'UPDATE dm_user_mileage SET mileage = mileage - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [price, userId]
      );

      // 4. 패배 감소
      await client.query(
        `UPDATE dm_user_game_stats
         SET losses = losses - $1, updated_at = CURRENT_TIMESTAMP
         WHERE user_id = $2 AND game_type = $3`,
        [actualCount, userId, gameType]
      );

      await client.query('COMMIT');

      // 업데이트된 통계 조회
      const updatedStats = await pool.query(
        'SELECT * FROM dm_user_game_stats WHERE user_id = $1 AND game_type = $2',
        [userId, gameType]
      );

      // 업데이트된 코인 조회
      const updatedCoins = await pool.query(
        'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
        [userId]
      );

      const stats = updatedStats.rows[0];
      const totalGames = stats.wins + stats.losses + stats.draws;
      const winRate = totalGames > 0 ? Math.round((stats.wins / totalGames) * 100) : 0;

      return {
        success: true,
        message: `패배 ${actualCount}회가 삭제되었습니다!`,
        coins: updatedCoins.rows[0]?.mileage || 0,
        stats: {
          gameType: stats.game_type,
          wins: stats.wins,
          losses: stats.losses,
          draws: stats.draws,
          level: stats.level,
          exp: stats.exp,
          winRate,
          totalGames,
        }
      };
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('Delete loss error:', error);
      return { success: false, message: '패배 삭제 중 오류가 발생했습니다.' };
    } finally {
      client.release();
    }
  },

  // 닉네임 변경 (코인 차감 포함)
  async changeNickname(userId: number, newNickname: string): Promise<{ success: boolean; message: string; nickname?: string; coins?: number }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    const TICKET_PRICE = 100; // 닉네임 변경권 가격

    // 닉네임 유효성 검사
    if (!newNickname || newNickname.length < 2 || newNickname.length > 20) {
      return { success: false, message: '닉네임은 2-20자여야 합니다.' };
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // 1. 현재 코인(마일리지) 확인
      const coinResult = await client.query(
        'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
        [userId]
      );

      const currentCoins = coinResult.rows.length > 0 ? (coinResult.rows[0].mileage || 0) : 0;
      if (currentCoins < TICKET_PRICE) {
        await client.query('ROLLBACK');
        return { success: false, message: `코인이 부족합니다. (현재: ${currentCoins}, 필요: ${TICKET_PRICE})` };
      }

      // 2. 코인(마일리지) 차감
      await client.query(
        'UPDATE dm_user_mileage SET mileage = mileage - $1, updated_at = CURRENT_TIMESTAMP WHERE user_id = $2',
        [TICKET_PRICE, userId]
      );

      // 3. 닉네임 변경
      await client.query(
        'UPDATE dm_users SET nickname = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2',
        [newNickname, userId]
      );

      await client.query('COMMIT');

      // 업데이트된 코인 조회
      const updatedCoins = await pool.query(
        'SELECT mileage FROM dm_user_mileage WHERE user_id = $1',
        [userId]
      );

      return {
        success: true,
        message: '닉네임이 변경되었습니다!',
        nickname: newNickname,
        coins: updatedCoins.rows[0]?.mileage || 0,
      };
    } catch (error) {
      await client.query('ROLLBACK');
      console.error('Change nickname error:', error);
      return { success: false, message: '닉네임 변경 중 오류가 발생했습니다.' };
    } finally {
      client.release();
    }
  },

  // 신규 유저 기본 아이템 지급
  async grantDefaultItems(userId: number): Promise<void> {
    const pool = getPool();
    if (!pool) return;

    try {
      // 이미 아이템이 있으면 스킵
      const existing = await pool.query('SELECT COUNT(*) FROM dm_user_items WHERE user_id = $1', [userId]);
      if (parseInt(existing.rows[0].count) > 0) return;

      // 기본 아이템 조회
      const defaultItems = await pool.query('SELECT id FROM dm_shop_items WHERE is_default = TRUE');

      // 기본 아이템 지급
      for (const item of defaultItems.rows) {
        await pool.query(
          `INSERT INTO dm_user_items (user_id, item_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
          [userId, item.id]
        );
      }

      console.log(`✅ Default items granted to user ${userId}`);
    } catch (error) {
      console.error('Grant default items error:', error);
    }
  },

  // 만료된 아이템 정리 (장착 해제)
  async cleanupExpiredItems(): Promise<void> {
    const pool = getPool();
    if (!pool) return;

    try {
      // 만료된 아이템 ID 조회
      const expiredItems = await pool.query(
        `SELECT DISTINCT item_id FROM dm_user_items WHERE expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP`
      );

      // 만료된 아이템을 장착 중인 경우 해제
      for (const row of expiredItems.rows) {
        const itemId = row.item_id;

        // 프레임 장착 해제
        await pool.query(
          `UPDATE dm_user_profile_settings SET active_frame_id = NULL WHERE active_frame_id = $1`,
          [itemId]
        );
        // 칭호 장착 해제
        await pool.query(
          `UPDATE dm_user_profile_settings SET active_title_id = NULL WHERE active_title_id = $1`,
          [itemId]
        );
        // 테마 장착 해제
        await pool.query(
          `UPDATE dm_user_profile_settings SET active_theme_id = NULL WHERE active_theme_id = $1`,
          [itemId]
        );
        // 아바타 장착 해제
        await pool.query(
          `UPDATE dm_user_profile_settings SET active_avatar_id = NULL WHERE active_avatar_id = $1`,
          [itemId]
        );
      }

      // 만료된 아이템 삭제
      await pool.query(
        `DELETE FROM dm_user_items WHERE expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP`
      );

      console.log('✅ Expired items cleaned up');
    } catch (error) {
      console.error('Cleanup expired items error:', error);
    }
  },

  // 기본 아이템 조회 (무료)
  async getDefaultItems(): Promise<ShopItem[]> {
    const pool = getPool();
    if (!pool) return [];

    const result = await pool.query(
      'SELECT * FROM dm_shop_items WHERE is_default = TRUE ORDER BY category, sort_order'
    );
    return result.rows.map(mapShopItem);
  },

  // 아이템 보유 여부 확인
  async hasItem(userId: number, itemId: number): Promise<boolean> {
    const pool = getPool();
    if (!pool) return false;

    // 기본 아이템인지 확인
    const itemResult = await pool.query('SELECT is_default FROM dm_shop_items WHERE id = $1', [itemId]);
    if (itemResult.rows.length > 0 && itemResult.rows[0].is_default) {
      return true;
    }

    // 보유 여부 확인
    const result = await pool.query(
      `SELECT * FROM dm_user_items WHERE user_id = $1 AND item_id = $2
       AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)`,
      [userId, itemId]
    );
    return result.rows.length > 0;
  },
};
