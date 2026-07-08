// [PP] PerlerPixel 모더레이션 유틸 — 별도 리포 소유. 삭제·리팩터링 금지.
//      금지어 필터, 신고 자동 비공개 임계치, unlisted 공유코드 생성.
import { randomBytes } from 'crypto';
import { getPool } from '../config/database';

/** 서로 다른 유저의 신고가 이 수를 넘으면 게시글을 자동 pending(비공개) 처리. */
export const REPORT_AUTO_HIDE_THRESHOLD = 3;

// 저작권·상표권 / 부적절한 이미지 / 욕설·혐오 / 개인정보·초상권 / 스팸·광고 / 기타
export const REPORT_REASONS = ['copyright', 'inappropriate', 'abuse', 'privacy', 'spam', 'other'] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

// 기본 금지어(운영 중 pp_banned_keywords 로 추가/편집). 최소 기본셋.
const DEFAULT_BANNED = ['씨발', '시발', 'ㅅㅂ', '개새끼', 'fuck', 'shit', 'porn', '섹스', '자살'];

let cache: { at: number; words: string[] } | null = null;

/** DB 금지어 + 기본셋(소문자). 60초 캐시. */
async function bannedWords(): Promise<string[]> {
  const now = Date.now();
  if (cache && now - cache.at < 60_000) return cache.words;
  let db: string[] = [];
  try {
    const pool = getPool();
    if (pool) {
      const r = await pool.query('SELECT word FROM pp_banned_keywords');
      db = r.rows.map((x: { word: string }) => String(x.word).toLowerCase());
    }
  } catch {
    // 조회 실패 시 기본셋만 사용
  }
  const words = Array.from(new Set([...DEFAULT_BANNED, ...db].map((w) => w.toLowerCase())));
  cache = { at: now, words };
  return words;
}

/** 텍스트에 금지어가 포함되면 true. */
export async function containsBannedWord(text: string): Promise<boolean> {
  const lower = (text || '').toLowerCase();
  if (!lower.trim()) return false;
  const words = await bannedWords();
  return words.some((w) => w && lower.includes(w));
}

/** unlisted 게시글용 공유 코드(URL 안전, 12자). */
export function generateShareCode(): string {
  return randomBytes(9).toString('base64url').slice(0, 12);
}
