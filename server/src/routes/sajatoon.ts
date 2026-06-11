// [SAJA] 사자툰(SajaToon) 전용 라우트 — 파일 전체가 SajaToon 소유. 삭제·리팩터링 금지.
//        앱 소스는 별도 리포 ~/Documents/Jiny/SajaToon (Android Kotlin, 추후 iOS).
//        자세한 소유권 규칙은 리포 루트 CLAUDE.md 의 [SAJA] 섹션 참고.
//
// 사자툰 — "매일 한 편의 만화로 배우는 사자성어".
// 로그인이 없는 앱이라 JWT 없이 공개 엔드포인트로 동작한다.
// 사용자 식별/진도 동기화는 앱이 생성한 임의 deviceId(UUID) 로 한다.
// 테이블 프리픽스는 sj_ 로 다른 앱(dm_/ctr_)과 분리. (스키마는 config/database.ts)
//
//   GET  /api/sajatoon/idioms                      -> { version, idioms: [...] }   (오프라인 캐시용 전체 콘텐츠)
//   POST /api/sajatoon/devices/ping                { deviceId, platform?, ... }    (앱 실행 시 익명 통계)
//   GET  /api/sajatoon/progress?deviceId=...       -> { progress: [...] }          (기기 학습 진도 동기화)
//   POST /api/sajatoon/progress                    { deviceId, idiomId, learned?, quizResult?, bookmarked? }
import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';

const router = Router();

function cleanDeviceId(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim().slice(0, 64) : null;
}

// GET /api/sajatoon/idioms — 활성 사자성어 전체(학습 순서대로). 앱이 받아 Room 에 캐시.
//   version = 최신 updated_at(ms) + 개수. ETag 로 콘텐츠 미변경 시 304(본문 0바이트) 반환.
router.get('/idioms', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    // 1) 버전·개수만 싸게 조회 → ETag 생성. 변경 없으면 전체 조회 없이 304.
    const ver = await pool.query(
      `SELECT COALESCE(EXTRACT(EPOCH FROM MAX(updated_at)) * 1000, 0)::bigint AS version,
              COUNT(*)::int AS n
       FROM sj_idioms WHERE is_active = TRUE`
    );
    const version = Number(ver.rows[0].version);
    const count = ver.rows[0].n as number;
    const etag = `"saja-${version}-${count}"`;

    res.set('Cache-Control', 'no-cache'); // 항상 재검증(ETag) → 미변경 시 304
    res.set('ETag', etag);
    if (req.headers['if-none-match'] === etag) {
      res.status(304).end();
      return;
    }

    // 2) 변경됐을 때만 전체 조회.
    const result = await pool.query(
      `SELECT id, slug, hanja, reading, meaning, origin, modern_example,
              category, level, day_index, comic, images, thumbnail, chars, quiz, quizzes, updated_at
       FROM sj_idioms
       WHERE is_active = TRUE
       ORDER BY day_index ASC NULLS LAST, id ASC`
    );

    const idioms = result.rows.map((row: any) => ({
      id: row.id,
      slug: row.slug,
      hanja: row.hanja,
      reading: row.reading,
      meaning: row.meaning,
      origin: row.origin,
      modernExample: row.modern_example,
      category: row.category,
      level: row.level,
      dayIndex: row.day_index,
      comic: row.comic ?? [],
      images: row.images ?? [],   // 실제 만화 이미지 URL 리스트 (4컷=1장, 8컷=2장…)
      thumbnail: row.thumbnail ?? null, // 모아보기 대표 썸네일
      chars: row.chars ?? [],           // 한자 한 글자씩 풀이
      quiz: row.quiz ?? null,           // (레거시) 단일 퀴즈
      // 퀴즈 여러 개. 비어 있으면 레거시 단일 quiz 로 폴백.
      quizzes: (Array.isArray(row.quizzes) && row.quizzes.length > 0)
        ? row.quizzes
        : (row.quiz ? [row.quiz] : []),
    }));

    res.json({ version, idioms });
  } catch (error) {
    console.error('SAJA idioms error:', error);
    res.status(500).json({ error: 'Failed to load idioms' });
  }
});

// POST /api/sajatoon/devices/ping — 앱 실행 시 1회. 익명 유저 카운팅/통계.
router.post('/devices/ping', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    const body = req.body ?? {};
    const deviceId = cleanDeviceId(body.deviceId);
    if (!deviceId) { res.status(400).json({ error: 'deviceId is required' }); return; }

    const platform = body.platform === 'ios' || body.platform === 'android' ? body.platform : null;
    const country =
      typeof body.country === 'string' && /^[A-Za-z]{2}$/.test(body.country)
        ? body.country.toUpperCase()
        : null;
    const appVersion = typeof body.appVersion === 'string' ? body.appVersion.slice(0, 20) : null;
    const osVersion = typeof body.osVersion === 'string' ? body.osVersion.slice(0, 30) : null;

    await pool.query(
      `INSERT INTO sj_devices (device_id, platform, country, app_version, os_version)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (device_id) DO UPDATE SET
         platform = COALESCE(EXCLUDED.platform, sj_devices.platform),
         country = COALESCE(EXCLUDED.country, sj_devices.country),
         app_version = COALESCE(EXCLUDED.app_version, sj_devices.app_version),
         os_version = COALESCE(EXCLUDED.os_version, sj_devices.os_version),
         launch_count = sj_devices.launch_count + 1,
         last_seen = CURRENT_TIMESTAMP`,
      [deviceId, platform, country, appVersion, osVersion]
    );
    await pool.query(
      `INSERT INTO sj_device_daily (device_id, day, platform)
       VALUES ($1, CURRENT_DATE, $2)
       ON CONFLICT (device_id, day) DO NOTHING`,
      [deviceId, platform]
    );

    res.json({ success: true });
  } catch (error) {
    console.error('SAJA device ping error:', error);
    res.status(500).json({ error: 'Failed to ping' });
  }
});

// GET /api/sajatoon/progress?deviceId=... — 기기 학습 진도 조회(동기화).
router.get('/progress', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    const deviceId = cleanDeviceId(req.query.deviceId);
    if (!deviceId) { res.status(400).json({ error: 'deviceId is required' }); return; }

    const result = await pool.query(
      `SELECT idiom_id, learned, learned_at, quiz_correct, quiz_attempts, bookmarked, updated_at
       FROM sj_progress
       WHERE device_id = $1
       ORDER BY updated_at DESC`,
      [deviceId]
    );

    const progress = result.rows.map((row: any) => ({
      idiomId: row.idiom_id,
      learned: row.learned,
      learnedAt: row.learned_at,
      quizCorrect: row.quiz_correct,
      quizAttempts: row.quiz_attempts,
      bookmarked: row.bookmarked,
      updatedAt: row.updated_at,
    }));

    res.json({ progress });
  } catch (error) {
    console.error('SAJA get progress error:', error);
    res.status(500).json({ error: 'Failed to get progress' });
  }
});

// POST /api/sajatoon/progress — 학습/퀴즈/북마크 이벤트 upsert.
//   body: { deviceId, idiomId, learned?(bool), quizResult?('correct'|'wrong'), bookmarked?(bool) }
//   부분 업데이트: 보내지 않은 필드는 기존 값 유지. quizResult 는 시도/정답 카운트를 누적한다.
router.post('/progress', async (req: Request, res: Response): Promise<void> => {
  try {
    const pool = getPool();
    if (!pool) { res.status(500).json({ error: 'Database not available' }); return; }

    const body = req.body ?? {};
    const deviceId = cleanDeviceId(body.deviceId);
    const idiomId = Number(body.idiomId);
    if (!deviceId) { res.status(400).json({ error: 'deviceId is required' }); return; }
    if (!Number.isInteger(idiomId) || idiomId <= 0) {
      res.status(400).json({ error: 'idiomId must be a positive integer' });
      return;
    }

    const learned = typeof body.learned === 'boolean' ? body.learned : null;
    const bookmarked = typeof body.bookmarked === 'boolean' ? body.bookmarked : null;
    const quizResult =
      body.quizResult === 'correct' ? 'correct' : body.quizResult === 'wrong' ? 'wrong' : null;
    const attemptDelta = quizResult ? 1 : 0;
    const correctDelta = quizResult === 'correct' ? 1 : 0;

    const result = await pool.query(
      `INSERT INTO sj_progress (device_id, idiom_id, learned, learned_at, quiz_correct, quiz_attempts, bookmarked)
       VALUES (
         $1, $2,
         COALESCE($3, FALSE),
         CASE WHEN $3 = TRUE THEN CURRENT_TIMESTAMP ELSE NULL END,
         $5, $4,
         COALESCE($6, FALSE)
       )
       ON CONFLICT (device_id, idiom_id) DO UPDATE SET
         learned = CASE WHEN $3 IS NULL THEN sj_progress.learned ELSE $3 END,
         learned_at = CASE
           WHEN $3 = TRUE AND sj_progress.learned_at IS NULL THEN CURRENT_TIMESTAMP
           ELSE sj_progress.learned_at END,
         quiz_attempts = sj_progress.quiz_attempts + $4,
         quiz_correct = sj_progress.quiz_correct + $5,
         bookmarked = CASE WHEN $6 IS NULL THEN sj_progress.bookmarked ELSE $6 END,
         updated_at = CURRENT_TIMESTAMP
       RETURNING idiom_id, learned, learned_at, quiz_correct, quiz_attempts, bookmarked`,
      [deviceId, idiomId, learned, attemptDelta, correctDelta, bookmarked]
    );

    const row = result.rows[0];
    res.json({
      success: true,
      progress: {
        idiomId: row.idiom_id,
        learned: row.learned,
        learnedAt: row.learned_at,
        quizCorrect: row.quiz_correct,
        quizAttempts: row.quiz_attempts,
        bookmarked: row.bookmarked,
      },
    });
  } catch (error) {
    console.error('SAJA upsert progress error:', error);
    res.status(500).json({ error: 'Failed to save progress' });
  }
});

export default router;
