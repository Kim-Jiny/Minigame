import { getPool } from '../config/database';
import { HunminGame } from '../games/hunmin';

class DictionaryService {
  /**
   * 단어 유효성 검증 (하이브리드: 로컬 DB → 네이버 사전 폴백)
   */
  async isValidWord(word: string): Promise<{ valid: boolean; source: 'local' | 'api' | 'none' }> {
    // 1차: 로컬 DB 조회
    const localResult = await this.checkLocalDB(word);
    if (localResult) {
      return { valid: true, source: 'local' };
    }

    // 2차: 네이버 사전 폴백
    const apiResult = await this.checkNaverDict(word);
    if (apiResult) {
      // 결과를 로컬 DB에 캐싱
      await this.cacheWord(word);
      return { valid: true, source: 'api' };
    }

    return { valid: false, source: 'none' };
  }

  /**
   * 로컬 DB에서 단어 조회
   */
  private async checkLocalDB(word: string): Promise<boolean> {
    const pool = getPool();
    if (!pool) return false;

    try {
      const result = await pool.query(
        'SELECT 1 FROM dm_korean_words WHERE word = $1 LIMIT 1',
        [word]
      );
      return result.rows.length > 0;
    } catch (err) {
      console.error('Dictionary local DB check error:', err);
      return false;
    }
  }

  /**
   * 네이버 국어사전 자동완성 API로 단어 검증
   */
  private async checkNaverDict(word: string): Promise<boolean> {
    try {
      const url = `https://ac-dict.naver.com/koko/ac?q=${encodeURIComponent(word)}&st=11&r_lt=11&r_format=json`;
      const response = await fetch(url, {
        signal: AbortSignal.timeout(5000),
      });

      if (!response.ok) {
        console.error(`Naver dict API error: ${response.status}`);
        return false;
      }

      const data: any = await response.json();
      const items = data?.items?.[0] || [];

      for (const item of items) {
        const dictWord = (item?.[0]?.[0] || '').replace(/[-\s]/g, '');
        if (dictWord === word) {
          return true;
        }
      }

      return false;
    } catch (err) {
      console.error('Naver dict API check error:', err);
      return false;
    }
  }

  /**
   * API에서 확인된 단어를 로컬 DB에 캐싱
   */
  private async cacheWord(word: string): Promise<void> {
    const pool = getPool();
    if (!pool) return;

    try {
      const chosung = HunminGame.getChosung(word);
      await pool.query(
        `INSERT INTO dm_korean_words (word, chosung, source)
         VALUES ($1, $2, 'api')
         ON CONFLICT (word) DO NOTHING`,
        [word, chosung]
      );
    } catch (err) {
      console.error('Dictionary cache error:', err);
    }
  }
}

export const dictionaryService = new DictionaryService();
