import { getPool } from '../config/database';

export interface ShopItem {
  id: number;
  category: string;
  itemKey: string;
  name: string;
  description: string;
  price: number; // 유효 가격(할인 적용). 구버전 앱은 이 값만 읽는다
  originalPrice: number; // 정가
  discountPercent: number; // 할인 없음/만료면 0
  saleEndsAt: string | null;
  badge: 'new' | 'hot' | 'limited' | null;
  isFeatured: boolean;
  availableUntil: string | null;
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
  isExpiringSoon?: boolean; // 만료 3일 이내
  item?: ShopItem;
}

export interface UserProfileSettings {
  userId: number;
  activeFrameId: number | null;
  activeTitleId: number | null;
  activeThemeId: number | null;
  activeAvatarId: number | null;
  activeMascotId: number | null;
  activeFrame?: ShopItem | null;
  activeTitle?: ShopItem | null;
  activeTheme?: ShopItem | null;
  activeAvatar?: ShopItem | null;
  activeMascot?: ShopItem | null;
}

// 할인·판매기간·신규 판정은 DB 시계(CURRENT_TIMESTAMP)로 계산해 컬럼으로 함께 가져온다.
const SHOP_COMPUTED = `(sale_percent > 0 AND (sale_ends_at IS NULL OR sale_ends_at > CURRENT_TIMESTAMP)) AS sale_active,
  (available_until IS NULL OR available_until > CURRENT_TIMESTAMP) AS is_available,
  (created_at > CURRENT_TIMESTAMP - INTERVAL '14 days') AS is_new`;

// 장착 가능한 카테고리 → 프로필 설정 컬럼
const EQUIP_FIELDS: Record<string, string> = {
  frame: 'active_frame_id',
  title: 'active_title_id',
  theme: 'active_theme_id',
  avatar: 'active_avatar_id',
  mascot: 'active_mascot_id',
};

function iso(v: any): string | null {
  return v ? new Date(v).toISOString() : null;
}

function effectivePrice(row: any): number {
  const base: number = row.price;
  if (base > 0 && row.sale_active && row.sale_percent > 0) {
    return Math.max(1, Math.round((base * (100 - row.sale_percent)) / 100));
  }
  return base;
}

function mapShopItem(row: any): ShopItem {
  const saleOn = !!row.sale_active && row.sale_percent > 0 && row.price > 0;
  const price = effectivePrice(row);
  let badge: ShopItem['badge'] = null;
  if (row.badge === 'new' || row.badge === 'hot' || row.badge === 'limited') badge = row.badge;
  else if (row.available_until) badge = 'limited';
  else if (row.is_new && row.price > 0) badge = 'new';
  return {
    // 보유 목록 조인 시 row.id 는 dm_user_items.id 이므로 상점 아이템 id 는 shop_item_id 를 우선
    id: row.shop_item_id ?? row.id,
    category: row.category,
    itemKey: row.item_key,
    name: row.name,
    description: row.description,
    price,
    originalPrice: row.price,
    discountPercent: saleOn ? row.sale_percent : 0,
    saleEndsAt: saleOn ? iso(row.sale_ends_at) : null,
    badge,
    isFeatured: !!row.is_featured,
    availableUntil: iso(row.available_until),
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

    let query = `SELECT *, ${SHOP_COMPUTED} FROM dm_shop_items WHERE is_active = TRUE AND (available_until IS NULL OR available_until > CURRENT_TIMESTAMP)`;
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
      `SELECT ui.*, si.id AS shop_item_id, si.category, si.item_key, si.name, si.description, si.price,
              si.duration_days, si.rarity, si.preview_data, si.sort_order, si.is_active, si.is_default,
              si.sale_percent, si.sale_ends_at, si.badge, si.is_featured, si.available_until, si.created_at,
              (si.sale_percent > 0 AND (si.sale_ends_at IS NULL OR si.sale_ends_at > CURRENT_TIMESTAMP)) AS sale_active,
              (si.created_at > CURRENT_TIMESTAMP - INTERVAL '14 days') AS is_new,
              (ui.expires_at IS NOT NULL AND ui.expires_at <= CURRENT_TIMESTAMP + INTERVAL '3 days') AS is_expiring_soon
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
      isExpiringSoon: !!row.is_expiring_soon,
      item: mapShopItem(row),
    }));
  },

  // 유저 프로필 설정 조회
  async getUserProfileSettings(userId: number): Promise<UserProfileSettings> {
    const pool = getPool();
    const empty: UserProfileSettings = { userId, activeFrameId: null, activeTitleId: null, activeThemeId: null, activeAvatarId: null, activeMascotId: null };
    if (!pool) return empty;

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
      settings = { ...empty };
    } else {
      const row = settingsResult.rows[0];
      settings = {
        userId: row.user_id,
        activeFrameId: row.active_frame_id,
        activeTitleId: row.active_title_id,
        activeThemeId: row.active_theme_id,
        activeAvatarId: row.active_avatar_id,
        activeMascotId: row.active_mascot_id ?? null,
      };
    }

    // 장착 아이템 상세 조회 + 보유 만료된 장착은 해제(DB도 정리 → 기본값으로 복귀)
    const slots: Array<[string, keyof UserProfileSettings, keyof UserProfileSettings]> = [
      ['active_frame_id', 'activeFrameId', 'activeFrame'],
      ['active_title_id', 'activeTitleId', 'activeTitle'],
      ['active_theme_id', 'activeThemeId', 'activeTheme'],
      ['active_avatar_id', 'activeAvatarId', 'activeAvatar'],
      ['active_mascot_id', 'activeMascotId', 'activeMascot'],
    ];
    const ids = slots.map(([, idKey]) => settings[idKey] as number | null).filter((v): v is number => !!v);
    if (ids.length > 0) {
      const itemsResult = await pool.query(
        `SELECT *, ${SHOP_COMPUTED},
                EXISTS (SELECT 1 FROM dm_user_items ui WHERE ui.user_id = $1 AND ui.item_id = dm_shop_items.id
                        AND (ui.expires_at IS NULL OR ui.expires_at > CURRENT_TIMESTAMP)) AS owned
         FROM dm_shop_items WHERE id = ANY($2::int[])`,
        [userId, ids]
      );
      const byId = new Map<number, any>(itemsResult.rows.map((r: any) => [r.id, r]));
      const clear: string[] = [];
      for (const [col, idKey, itemKey] of slots) {
        const id = settings[idKey] as number | null;
        if (!id) continue;
        const r = byId.get(id);
        if (r && (r.is_default || r.owned)) {
          (settings as any)[itemKey] = mapShopItem(r);
        } else {
          (settings as any)[idKey] = null;
          clear.push(col);
        }
      }
      if (clear.length > 0) {
        await pool.query(
          `UPDATE dm_user_profile_settings SET ${clear.map(c => `${c} = NULL`).join(', ')} WHERE user_id = $1`,
          [userId]
        );
      }
    }

    return settings;
  },

  // 아이템 구매 — 한 트랜잭션(코인 행 FOR UPDATE + 잔액 가드 차감). 기간제는 보유 중 연장(갱신) 가능.
  async purchaseItem(userId: number, itemId: number): Promise<{ success: boolean; message: string; item?: UserItem; coins?: number }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // 아이템 정보 조회 (판매 중 + 판매기간 이내)
      const itemResult = await client.query(
        `SELECT *, ${SHOP_COMPUTED} FROM dm_shop_items WHERE id = $1 AND is_active = TRUE`,
        [itemId]
      );
      if (itemResult.rows.length === 0 || !itemResult.rows[0].is_available) {
        await client.query('ROLLBACK');
        return { success: false, message: '아이템을 찾을 수 없습니다.' };
      }
      const row = itemResult.rows[0];
      const item = mapShopItem(row);
      const price = item.price; // 유효 가격
      const isTicket = item.category === 'ticket';
      const durationDays: number | null = row.duration_days || null;

      // 보유 확인(행 잠금). 티켓은 소모품이라 건너뜀
      let renewal = false;
      if (!isTicket) {
        const owned = await client.query(
          `SELECT expires_at IS NULL AS permanent,
                  (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP) AS active,
                  (expires_at >= CURRENT_TIMESTAMP + INTERVAL '365 days') AS cap_reached
           FROM dm_user_items WHERE user_id = $1 AND item_id = $2 FOR UPDATE`,
          [userId, itemId]
        );
        if (owned.rows.length > 0 && owned.rows[0].active) {
          if (owned.rows[0].permanent || !durationDays) {
            await client.query('ROLLBACK');
            return { success: false, message: '이미 보유 중인 아이템입니다.' };
          }
          if (owned.rows[0].cap_reached) {
            await client.query('ROLLBACK');
            return { success: false, message: '더 이상 연장할 수 없어요. (최대 365일까지 보유 가능)' };
          }
          renewal = true;
        }
      }

      // 코인 행 잠금 후 잔액 확인
      const mileageResult = await client.query('SELECT mileage FROM dm_user_mileage WHERE user_id = $1 FOR UPDATE', [userId]);
      const currentCoins: number = mileageResult.rows.length > 0 ? (mileageResult.rows[0].mileage || 0) : 0;
      if (currentCoins < price) {
        await client.query('ROLLBACK');
        return { success: false, message: '코인이 부족합니다.', coins: currentCoins };
      }

      // 코인 차감 (잔액 가드)
      const deducted = await client.query(
        `UPDATE dm_user_mileage SET mileage = mileage - $1, updated_at = CURRENT_TIMESTAMP
         WHERE user_id = $2 AND mileage >= $1 RETURNING mileage`,
        [price, userId]
      );
      if (deducted.rows.length === 0) {
        await client.query('ROLLBACK');
        return { success: false, message: '코인이 부족합니다.', coins: currentCoins };
      }
      const newBalance: number = deducted.rows[0].mileage;

      // 기록 저장 (코인 내역 + 상점 구매 내역)
      await client.query(
        'INSERT INTO dm_mileage_history (user_id, amount, reason) VALUES ($1, $2, $3)',
        [userId, -price, `purchase_${item.itemKey}`]
      );
      await client.query(
        `INSERT INTO dm_shop_purchases (user_id, item_id, item_key, category, price_paid, original_price, discount_percent, is_renewal, duration_days)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [userId, itemId, item.itemKey, item.category, price, item.originalPrice, item.discountPercent, renewal, durationDays]
      );

      // 티켓은 dm_user_items에 저장하지 않고 바로 반환
      if (isTicket) {
        await client.query('COMMIT');
        return {
          success: true,
          message: `${item.name}을(를) 구매했습니다!`,
          coins: newBalance,
          item: { id: 0, userId, itemId: item.id, purchasedAt: new Date(), expiresAt: null, item },
        };
      }

      // 아이템 지급 / 기간 연장 (만료일은 DB 시계로 계산: 연장은 max(now, 현재 만료) + 기간, 최대 now+365일)
      const insertResult = renewal
        ? await client.query(
            `UPDATE dm_user_items
             SET expires_at = LEAST(GREATEST(CURRENT_TIMESTAMP, expires_at) + make_interval(days => $3::int),
                                    CURRENT_TIMESTAMP + INTERVAL '365 days')
             WHERE user_id = $1 AND item_id = $2 RETURNING *`,
            [userId, itemId, durationDays]
          )
        : await client.query(
            `INSERT INTO dm_user_items (user_id, item_id, expires_at, purchased_at)
             VALUES ($1, $2, CASE WHEN $3::int IS NULL THEN NULL ELSE CURRENT_TIMESTAMP + make_interval(days => $3::int) END, CURRENT_TIMESTAMP)
             ON CONFLICT (user_id, item_id) DO UPDATE SET expires_at = EXCLUDED.expires_at, purchased_at = CURRENT_TIMESTAMP
             RETURNING *`,
            [userId, itemId, durationDays]
          );

      await client.query('COMMIT');

      return {
        success: true,
        message: renewal ? `${item.name} 기간을 연장했습니다!` : `${item.name}을(를) 구매했습니다!`,
        coins: newBalance,
        item: {
          id: insertResult.rows[0].id,
          userId: insertResult.rows[0].user_id,
          itemId: insertResult.rows[0].item_id,
          purchasedAt: insertResult.rows[0].purchased_at,
          expiresAt: insertResult.rows[0].expires_at,
          item,
        },
      };
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { /* ignore */ }
      console.error('Purchase item error:', error);
      return { success: false, message: '구매 중 오류가 발생했습니다.' };
    } finally {
      client.release();
    }
  },

  // 아이템 장착
  async equipItem(userId: number, itemId: number): Promise<{ success: boolean; message: string; settings?: UserProfileSettings }> {
    const pool = getPool();
    if (!pool) return { success: false, message: '데이터베이스 연결 실패' };

    try {
      // 아이템 정보 조회
      const itemResult = await pool.query(`SELECT *, ${SHOP_COMPUTED} FROM dm_shop_items WHERE id = $1`, [itemId]);
      if (itemResult.rows.length === 0) {
        return { success: false, message: '아이템을 찾을 수 없습니다.' };
      }
      const item = mapShopItem(itemResult.rows[0]);

      // 장착 가능한 카테고리 확인
      if (!(item.category in EQUIP_FIELDS)) {
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
      const field = EQUIP_FIELDS[item.category];
      if (!field) return { success: false, message: '잘못된 카테고리입니다.' };

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
      const field = EQUIP_FIELDS[category];
      if (!field) return { success: false, message: '잘못된 카테고리입니다.' };

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
      // 보유가 만료된 아이템을 장착 중인 유저의 장착 해제 (갱신해서 아직 유효한 유저는 유지, 기본 아이템 제외)
      for (const field of Object.values(EQUIP_FIELDS)) {
        await pool.query(
          `UPDATE dm_user_profile_settings ps SET ${field} = NULL
           WHERE ps.${field} IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM dm_shop_items si WHERE si.id = ps.${field} AND si.is_default)
             AND NOT EXISTS (SELECT 1 FROM dm_user_items ui WHERE ui.user_id = ps.user_id AND ui.item_id = ps.${field}
                             AND (ui.expires_at IS NULL OR ui.expires_at > CURRENT_TIMESTAMP))`
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
      `SELECT *, ${SHOP_COMPUTED} FROM dm_shop_items WHERE is_default = TRUE ORDER BY category, sort_order`
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
