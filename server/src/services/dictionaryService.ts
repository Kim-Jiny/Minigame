import { getPool } from '../config/database';
import { HunminGame } from '../games/hunmin';

class DictionaryService {
  private apiKey: string | null = null;
  private initialized = false;

  private ensureInit() {
    if (this.initialized) return;
    this.initialized = true;
    this.apiKey = process.env.KRDICT_API_KEY || null;
    if (this.apiKey) {
      console.log('✅ Korean dictionary API key loaded');
    } else {
      console.log('⚠️  KRDICT_API_KEY not set, using local DB only for dictionary');
    }
  }

  /**
   * 단어 유효성 검증 (하이브리드: 로컬 DB → API 폴백)
   */
  async isValidWord(word: string): Promise<{ valid: boolean; source: 'local' | 'api' | 'none' }> {
    this.ensureInit();
    // 1차: 로컬 DB 조회
    const localResult = await this.checkLocalDB(word);
    if (localResult) {
      return { valid: true, source: 'local' };
    }

    // 2차: API 폴백 (키가 있을 때만)
    if (this.apiKey) {
      const apiResult = await this.checkKrdictAPI(word);
      if (apiResult) {
        // API 결과를 로컬 DB에 캐싱
        await this.cacheWord(word);
        return { valid: true, source: 'api' };
      }
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
   * 한국어기초사전 API로 단어 검증
   */
  private async checkKrdictAPI(word: string): Promise<boolean> {
    if (!this.apiKey) return false;

    try {
      const params = new URLSearchParams({
        key: this.apiKey,
        q: word,
        part: 'word',
        sort: 'dict',
        num: '10',
        type1: 'word',
      });

      const url = `https://krdict.korean.go.kr/api/search?${params.toString()}`;
      const response = await fetch(url, {
        signal: AbortSignal.timeout(5000),
        headers: { 'User-Agent': 'Mozilla/5.0 MinigameServer' },
      });

      if (!response.ok) {
        console.error(`Krdict API error: ${response.status}`);
        return false;
      }

      const text = await response.text();

      // XML 파싱: <word> 태그에서 정확한 단어 일치 확인
      // 응답 형식: <item><word>단어</word>...</item>
      const wordMatches = text.match(/<word>(.*?)<\/word>/g);
      if (!wordMatches) return false;

      for (const match of wordMatches) {
        const extracted = match.replace(/<\/?word>/g, '').trim();
        // 하이픈, 공백 제거 후 비교
        const cleaned = extracted.replace(/[-\s]/g, '');
        if (cleaned === word) {
          return true;
        }
      }

      return false;
    } catch (err) {
      console.error('Krdict API check error:', err);
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
