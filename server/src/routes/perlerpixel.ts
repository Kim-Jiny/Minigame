// [PP] PerlerPixel(비즈픽셀) 커뮤니티 게시판 공개/인증 API — 별도 리포
//      ~/Documents/Jiny/PerlerPixel 소유. 파일 전체가 PP 소유. 삭제·리팩터링 금지.
//
//   정책: 오리지널·직접제작만(업로드 시 권리확인 필수) + 사후 신고 기반 모더레이션.
//   게이팅: 리스트(GET /posts)는 비로그인 허용, 상세/다운로드/업로드/상호작용은 로그인 필요.
//   토큰: scope:'pp' JWT (ppAuth). 유저는 pp_users(듀오 dm_users 와 무관).
import { Router, Request, Response, NextFunction } from 'express';
import multer from 'multer';
import sharp from 'sharp';
import { randomBytes } from 'crypto';
import fs from 'fs';
import path from 'path';
import { getPool } from '../config/database';
import {
  verifyApple, verifyGoogle, verifyKakao,
  signPpToken, verifyPpToken,
  findOrCreatePpUser, getPpUserById, getActivePpBan,
  type PpUser,
} from '../services/ppAuth';
import {
  containsBannedWord, generateShareCode,
  REPORT_REASONS, REPORT_AUTO_HIDE_THRESHOLD,
} from '../services/ppModeration';

const router = Router();

const uploadsDir = path.join(__dirname, '../../public/pp/uploads');
try { fs.mkdirSync(uploadsDir, { recursive: true }); } catch { /* 이미 존재 */ }

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 6 * 1024 * 1024 } });

interface AuthedRequest extends Request { ppUser?: PpUser; ppBan?: { ban_type: string; reason: string } | null }

function bearer(req: Request): string | null {
  const h = req.headers.authorization;
  return h && h.startsWith('Bearer ') ? h.slice(7) : null;
}

// 로그인 필수 미들웨어
async function requireAuth(req: AuthedRequest, res: Response, next: NextFunction): Promise<void> {
  const token = bearer(req);
  const userId = token ? verifyPpToken(token) : null;
  if (!userId) { res.status(401).json({ error: 'login_required' }); return; }
  const user = await getPpUserById(userId);
  if (!user) { res.status(401).json({ error: 'user_not_found' }); return; }
  const ban = await getActivePpBan(userId);
  if (ban && ban.ban_type === 'full') { res.status(403).json({ error: 'banned', reason: ban.reason }); return; }
  req.ppUser = user;
  req.ppBan = ban;
  next();
}

// 선택적 로그인(리스트용): 토큰이 있으면 유저를 붙이고, 없어도 통과
async function optionalAuth(req: AuthedRequest, _res: Response, next: NextFunction): Promise<void> {
  const token = bearer(req);
  const userId = token ? verifyPpToken(token) : null;
  if (userId) req.ppUser = (await getPpUserById(userId)) ?? undefined;
  next();
}

function publicUser(u: PpUser) {
  return { id: u.id, nickname: u.nickname, avatarUrl: u.avatar_url };
}

// ───────────────────────── 인증 ─────────────────────────
router.post('/auth/:provider', async (req: Request, res: Response): Promise<void> => {
  try {
    const provider = String(req.params.provider);
    const body = req.body ?? {};
    let social = null as Awaited<ReturnType<typeof verifyApple>>;

    if (provider === 'apple') social = await verifyApple(String(body.idToken || ''));
    else if (provider === 'google') social = await verifyGoogle(String(body.idToken || ''));
    else if (provider === 'kakao') social = await verifyKakao(String(body.accessToken || ''));
    else { res.status(400).json({ error: 'unknown_provider' }); return; }

    if (!social) { res.status(401).json({ error: 'invalid_token' }); return; }

    // 실명 노출 방지: 소셜 이름을 쓰지 않고 중립 placeholder 로 생성. 유저가 첫 로그인에
    // 닉네임을 직접 정한다(needsNickname). 기존 유저는 저장된 닉네임 유지.
    const placeholder = `유저${social.uid.slice(-6)}`;
    const user = await findOrCreatePpUser(
      provider as 'apple' | 'google' | 'kakao',
      social.uid, social.email, placeholder, social.avatar
    );
    const ban = await getActivePpBan(user.id);
    if (ban && ban.ban_type === 'full') { res.status(403).json({ error: 'banned', reason: ban.reason }); return; }

    res.json({
      token: signPpToken(user.id),
      user: { ...publicUser(user), email: user.email },
      needsNickname: !user.nickname_set,
    });
  } catch (e) {
    console.error('[PP] auth error:', e);
    res.status(500).json({ error: 'auth_failed' });
  }
});

router.get('/me', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const u = req.ppUser!;
  res.json({
    user: { ...publicUser(u), email: u.email },
    uploadBanned: req.ppBan?.ban_type === 'upload',
    needsNickname: !u.nickname_set,
  });
});

router.put('/me/nickname', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const nickname = typeof req.body?.nickname === 'string' ? req.body.nickname.trim() : '';
  if (nickname.length < 2 || nickname.length > 20) { res.status(400).json({ error: 'nickname_length' }); return; }
  if (await containsBannedWord(nickname)) { res.status(400).json({ error: 'banned_word' }); return; }
  // 중복 닉네임(대소문자 무시) 방지
  const dup = await pool.query(
    `SELECT 1 FROM pp_users WHERE LOWER(nickname)=LOWER($1) AND nickname_set=TRUE AND id<>$2 LIMIT 1`,
    [nickname, req.ppUser!.id]
  );
  if (dup.rows.length) { res.status(409).json({ error: 'nickname_taken' }); return; }
  try {
    await pool.query(`UPDATE pp_users SET nickname=$1, nickname_set=TRUE, updated_at=CURRENT_TIMESTAMP WHERE id=$2`, [nickname, req.ppUser!.id]);
  } catch (e: any) {
    if (e?.code === '23505') { res.status(409).json({ error: 'nickname_taken' }); return; }  // 유니크 인덱스 백스톱
    throw e;
  }
  res.json({ user: { ...publicUser(req.ppUser!), nickname } });
});

// 탈퇴 — 유저 행 삭제. 게시글은 author_id=NULL(익명화)로 보존(FK ON DELETE SET NULL).
router.delete('/account', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  await pool.query('DELETE FROM pp_users WHERE id=$1', [req.ppUser!.id]);
  res.json({ success: true });
});

// ───────────────────────── 게시판 리스트(비로그인 허용) ─────────────────────────
router.get('/posts', optionalAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const limit = Math.min(Math.max(parseInt(String(req.query.limit ?? '30'), 10) || 30, 1), 50);
  const offset = Math.max(0, parseInt(String(req.query.cursor ?? '0'), 10) || 0);
  const viewer = req.ppUser?.id ?? null;

  // 최신순 / 인기순(좋아요) / 다운로드순
  const sort = String(req.query.sort ?? 'recent');
  const order = sort === 'popular' ? 'p.like_count DESC, p.id DESC'
    : sort === 'downloads' ? 'p.download_count DESC, p.id DESC'
    : 'p.id DESC';

  const q = typeof req.query.q === 'string' ? req.query.q.trim().slice(0, 40) : '';
  const params: any[] = [];
  let where = `p.visibility='public' AND p.status='active'`;
  if (q) {
    params.push(`%${q}%`);
    const p = `$${params.length}`;
    where += ` AND (p.title ILIKE ${p} OR EXISTS (SELECT 1 FROM unnest(p.tags) t WHERE t ILIKE ${p}))`;
  }
  if (viewer) {
    params.push(viewer);
    const v = `$${params.length}`;
    where += ` AND NOT EXISTS (SELECT 1 FROM pp_blocks b WHERE b.blocker_id=${v} AND b.blocked_id=p.author_id)`;
    where += ` AND NOT EXISTS (SELECT 1 FROM pp_hidden h WHERE h.user_id=${v} AND h.post_id=p.id)`;
  }
  params.push(limit); const limitP = `$${params.length}`;
  params.push(offset); const offsetP = `$${params.length}`;
  const rows = (await pool.query(
    `SELECT p.id, p.title, p.width, p.height, p.bead_count, p.like_count, p.download_count,
            p.preview_path, p.created_at,
            u.nickname AS author_nickname, p.author_id
       FROM pp_posts p LEFT JOIN pp_users u ON u.id = p.author_id
      WHERE ${where}
      ORDER BY ${order}
      LIMIT ${limitP} OFFSET ${offsetP}`,
    params
  )).rows;
  const nextCursor = rows.length === limit ? offset + limit : null;   // 다음 offset
  res.json({ posts: rows.map(toListItem), nextCursor });
});

function toListItem(r: any) {
  return {
    id: r.id, title: r.title, width: r.width, height: r.height, beadCount: r.bead_count,
    likeCount: r.like_count, downloadCount: r.download_count, previewPath: r.preview_path,
    createdAt: r.created_at,
    author: r.author_id ? { id: r.author_id, nickname: r.author_nickname } : null, // null=익명화
  };
}

// 금주 인기 Top 10 — 최근 7일 좋아요+다운로드 합산 점수순(비로그인 허용).
// 주의: '/posts/:id' 보다 먼저 선언해야 함(안 그러면 id='popular' 로 잡힘).
router.get('/posts/popular', optionalAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const viewer = req.ppUser?.id ?? null;
  const params: any[] = [];
  let visibility = `p.visibility='public' AND p.status='active'`;
  if (viewer) {
    params.push(viewer);
    const v = `$${params.length}`;
    visibility += ` AND NOT EXISTS (SELECT 1 FROM pp_blocks b WHERE b.blocker_id=${v} AND b.blocked_id=p.author_id)`;
    visibility += ` AND NOT EXISTS (SELECT 1 FROM pp_hidden h WHERE h.user_id=${v} AND h.post_id=p.id)`;
  }
  const rows = (await pool.query(
    `SELECT p.id, p.title, p.width, p.height, p.bead_count, p.like_count, p.download_count,
            p.preview_path, p.created_at, u.nickname AS author_nickname, p.author_id,
            ((SELECT COUNT(*) FROM pp_likes l WHERE l.post_id=p.id AND l.created_at > NOW()-INTERVAL '7 days')
           + (SELECT COUNT(*) FROM pp_downloads d WHERE d.post_id=p.id AND d.created_at > NOW()-INTERVAL '7 days')) AS score
       FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id
      WHERE ${visibility}
      ORDER BY score DESC, p.id DESC
      LIMIT 10`, params
  )).rows;
  res.json({ posts: rows.map(toListItem) });
});

// ───────────────────────── 상세(로그인 필요) ─────────────────────────
async function loadVisiblePost(pool: any, id: number, viewer: number): Promise<any | null> {
  const r = await pool.query(
    `SELECT p.*, u.nickname AS author_nickname FROM pp_posts p
       LEFT JOIN pp_users u ON u.id=p.author_id WHERE p.id=$1`, [id]
  );
  const post = r.rows[0];
  if (!post) return null;
  const isOwner = post.author_id === viewer;
  if (!isOwner) {
    if (post.status !== 'active') return null;
    const blocked = await pool.query(
      'SELECT 1 FROM pp_blocks WHERE blocker_id=$1 AND blocked_id=$2', [viewer, post.author_id]
    );
    if (blocked.rows.length) return null;
    const hidden = await pool.query('SELECT 1 FROM pp_hidden WHERE user_id=$1 AND post_id=$2', [viewer, id]);
    if (hidden.rows.length) return null;
  }
  return post;
}

router.get('/posts/:id', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const post = Number.isFinite(id) ? await loadVisiblePost(pool, id, req.ppUser!.id) : null;
  if (!post) { res.status(404).json({ error: 'not_found' }); return; }
  const liked = (await pool.query('SELECT 1 FROM pp_likes WHERE user_id=$1 AND post_id=$2', [req.ppUser!.id, id])).rows.length > 0;
  res.json({ post: toDetail(post), liked, isOwner: post.author_id === req.ppUser!.id });
});

function toDetail(p: any) {
  return {
    id: p.id, title: p.title, description: p.description, tags: p.tags ?? [],
    visibility: p.visibility, width: p.width, height: p.height, beadCount: p.bead_count,
    likeCount: p.like_count, downloadCount: p.download_count, previewPath: p.preview_path,
    shareCode: p.visibility === 'unlisted' ? p.share_code : null, createdAt: p.created_at,
    author: p.author_id ? { id: p.author_id, nickname: p.author_nickname } : null,
  };
}

// unlisted 공유코드 접근
router.get('/posts/code/:code', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const r = await pool.query(
    `SELECT p.*, u.nickname AS author_nickname FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id
      WHERE p.share_code=$1 AND p.status='active'`, [String(req.params.code)]
  );
  if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
  res.json({ post: toDetail(r.rows[0]) });
});

// ───────────────────────── 업로드(로그인 + 권리확인) ─────────────────────────
router.post('/posts', requireAuth, upload.fields([{ name: 'preview', maxCount: 1 }, { name: 'pattern', maxCount: 1 }]),
  async (req: AuthedRequest, res: Response): Promise<void> => {
    try {
      const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
      if (req.ppBan?.ban_type === 'upload') { res.status(403).json({ error: 'upload_banned', reason: req.ppBan.reason }); return; }

      const b = req.body ?? {};
      const files = req.files as Record<string, Express.Multer.File[]> | undefined;
      const previewFile = files?.preview?.[0];
      const patternFile = files?.pattern?.[0];

      // 권리 확인 필수
      if (String(b.rightsAck) !== 'true') { res.status(400).json({ error: 'rights_ack_required' }); return; }

      const title = typeof b.title === 'string' ? b.title.trim() : '';
      if (title.length < 1 || title.length > 120) { res.status(400).json({ error: 'title_length' }); return; }
      const description = (typeof b.description === 'string' ? b.description : '').slice(0, 2000);
      const tags = String(b.tags || '').split(',').map((t) => t.trim()).filter(Boolean).slice(0, 10);
      const visibility = b.visibility === 'unlisted' ? 'unlisted' : 'public';

      if (await containsBannedWord(`${title} ${description} ${tags.join(' ')}`)) {
        res.status(400).json({ error: 'banned_word' }); return;
      }
      if (!patternFile || patternFile.buffer.length < 9 || patternFile.buffer.length > 512 * 1024) {
        res.status(400).json({ error: 'invalid_pattern' }); return;
      }
      // compact 헤더("PPX1" + w u16 + h u16)에서 크기를 서버가 직접 읽음(클라 신뢰 X)
      const buf = patternFile.buffer;
      if (buf.toString('latin1', 0, 4) !== 'PPX1') { res.status(400).json({ error: 'invalid_pattern' }); return; }
      const width = buf.readUInt16BE(4), height = buf.readUInt16BE(6);
      if (width < 1 || width > 400 || height < 1 || height > 400) { res.status(400).json({ error: 'invalid_size' }); return; }
      const beadCount = Math.max(0, parseInt(String(b.beadCount ?? '0'), 10) || 0);

      // 프리뷰: sharp 로 재인코딩(메타 제거 + 크기 제한). 워터마크는 앱에서 오버레이로 표시.
      // 도안은 색 수가 적어 팔레트 PNG로 저장하면 파일이 매우 작아진다(수십 KB 수준).
      if (!previewFile) { res.status(400).json({ error: 'preview_required' }); return; }
      const previewPng = await sharp(previewFile.buffer)
        .resize({ width: 640, height: 640, fit: 'inside', withoutEnlargement: true })
        .png({ palette: true, compressionLevel: 9, quality: 90 })
        .toBuffer();
      const fname = `${randomBytes(8).toString('hex')}.png`;
      fs.writeFileSync(path.join(uploadsDir, fname), previewPng);
      const previewPath = `/pp/uploads/${fname}`;

      const shareCode = visibility === 'unlisted' ? generateShareCode() : null;
      const inserted = await pool.query(
        `INSERT INTO pp_posts (author_id, title, description, tags, visibility, share_code,
                               pattern_data, preview_path, width, height, bead_count)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id, share_code`,
        [req.ppUser!.id, title, description, tags, visibility, shareCode, buf, previewPath, width, height, beadCount]
      );
      res.json({ id: inserted.rows[0].id, shareCode: inserted.rows[0].share_code, previewPath });
    } catch (e) {
      console.error('[PP] upload error:', e);
      res.status(500).json({ error: 'upload_failed' });
    }
  });

// 내 글 삭제(소프트)
router.delete('/posts/:id', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const r = await pool.query(`UPDATE pp_posts SET status='deleted', updated_at=CURRENT_TIMESTAMP
                              WHERE id=$1 AND author_id=$2 AND status<>'deleted' RETURNING id`, [id, req.ppUser!.id]);
  if (!r.rows[0]) { res.status(404).json({ error: 'not_found' }); return; }
  res.json({ success: true });
});

// 다운로드 — 집계 + pattern_data(base64) 반환
router.post('/posts/:id/download', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const post = Number.isFinite(id) ? await loadVisiblePost(pool, id, req.ppUser!.id) : null;
  if (!post) { res.status(404).json({ error: 'not_found' }); return; }
  // 유저별 최초 1회만 집계 — 재다운로드는 데이터만 반환하고 카운트는 올리지 않음.
  const first = await pool.query(
    'INSERT INTO pp_downloads (user_id, post_id) VALUES ($1,$2) ON CONFLICT (user_id, post_id) DO NOTHING RETURNING id',
    [req.ppUser!.id, id]
  );
  if (first.rows.length) {
    await pool.query('UPDATE pp_posts SET download_count=download_count+1 WHERE id=$1', [id]);
  }
  res.json({ patternData: Buffer.from(post.pattern_data).toString('base64') });
});

// 좋아요 토글(Phase 2 정식이지만 스키마/엔드포인트는 미리)
router.post('/posts/:id/like', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const on = req.body?.like !== false;
  if (on) {
    await pool.query('INSERT INTO pp_likes (user_id,post_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [req.ppUser!.id, id]);
  } else {
    await pool.query('DELETE FROM pp_likes WHERE user_id=$1 AND post_id=$2', [req.ppUser!.id, id]);
  }
  const cnt = (await pool.query('SELECT COUNT(*)::int AS c FROM pp_likes WHERE post_id=$1', [id])).rows[0].c;
  await pool.query('UPDATE pp_posts SET like_count=$1 WHERE id=$2', [cnt, id]);
  res.json({ liked: on, likeCount: cnt });
});

// 신고 — 신고자에게 즉시 개인숨김 + 큐 적재 + 임계치 도달 시 자동 pending
router.post('/posts/:id/report', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const reason = REPORT_REASONS.includes(req.body?.reason) ? req.body.reason : 'other';
  const detail = (typeof req.body?.detail === 'string' ? req.body.detail : '').slice(0, 1000);
  const exists = await pool.query('SELECT 1 FROM pp_posts WHERE id=$1', [id]);
  if (!exists.rows.length) { res.status(404).json({ error: 'not_found' }); return; }

  await pool.query('INSERT INTO pp_hidden (user_id,post_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [req.ppUser!.id, id]);
  const ins = await pool.query(
    `INSERT INTO pp_reports (reporter_id,post_id,reason,detail) VALUES ($1,$2,$3,$4)
     ON CONFLICT (reporter_id,post_id) DO NOTHING RETURNING id`,
    [req.ppUser!.id, id, reason, detail]
  );
  if (ins.rows.length) {
    const cnt = (await pool.query(`SELECT COUNT(*)::int AS c FROM pp_reports WHERE post_id=$1 AND status='open'`, [id])).rows[0].c;
    await pool.query('UPDATE pp_posts SET report_count=$1 WHERE id=$2', [cnt, id]);
    if (cnt >= REPORT_AUTO_HIDE_THRESHOLD) {
      await pool.query(`UPDATE pp_posts SET status='pending' WHERE id=$1 AND status='active'`, [id]);
    }
  }
  res.json({ success: true });
});

// 작성자 차단
router.post('/blocks', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const blockedId = parseInt(String(req.body?.userId ?? ''), 10);
  if (!Number.isFinite(blockedId) || blockedId === req.ppUser!.id) { res.status(400).json({ error: 'invalid_user' }); return; }
  await pool.query('INSERT INTO pp_blocks (blocker_id,blocked_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [req.ppUser!.id, blockedId]);
  res.json({ success: true });
});

router.delete('/blocks/:userId', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  await pool.query('DELETE FROM pp_blocks WHERE blocker_id=$1 AND blocked_id=$2', [req.ppUser!.id, parseInt(String(req.params.userId), 10)]);
  res.json({ success: true });
});

// 내가 올린 도안
router.get('/me/posts', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const rows = (await pool.query(
    `SELECT id,title,width,height,bead_count,like_count,download_count,report_count,preview_path,visibility,status,created_at
       FROM pp_posts WHERE author_id=$1 AND status<>'deleted' ORDER BY id DESC`, [req.ppUser!.id]
  )).rows;
  res.json({ posts: rows.map((r: any) => ({
    id: r.id, title: r.title, width: r.width, height: r.height, beadCount: r.bead_count,
    likeCount: r.like_count, downloadCount: r.download_count, reportCount: r.report_count,
    previewPath: r.preview_path, visibility: r.visibility, status: r.status, createdAt: r.created_at,
  })) });
});

// ───────────────────────── 문의하기 ─────────────────────────
// 문의 등록
router.post('/inquiries', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const content = typeof req.body?.content === 'string' ? req.body.content.trim() : '';
  if (content.length < 1 || content.length > 2000) { res.status(400).json({ error: 'content_length' }); return; }
  const r = await pool.query(
    `INSERT INTO pp_inquiries (user_id, content) VALUES ($1,$2)
     RETURNING id, content, status, reply, replied_at, is_read, created_at`,
    [req.ppUser!.id, content]
  );
  res.json({ inquiry: r.rows[0] });
});

// 내 문의 목록(답변 포함)
router.get('/inquiries', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const rows = (await pool.query(
    `SELECT id, content, status, reply, replied_at, is_read, created_at
       FROM pp_inquiries WHERE user_id=$1 ORDER BY id DESC LIMIT 100`, [req.ppUser!.id]
  )).rows;
  res.json({ inquiries: rows });
});

// 답변 읽음 처리
router.post('/inquiries/read', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  await pool.query(`UPDATE pp_inquiries SET is_read=TRUE WHERE user_id=$1 AND status='replied'`, [req.ppUser!.id]);
  res.json({ success: true });
});

// 안 읽은 답변 수(배지용)
router.get('/inquiries/unread-count', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const c = (await pool.query(
    `SELECT COUNT(*)::int c FROM pp_inquiries WHERE user_id=$1 AND status='replied' AND is_read=FALSE`, [req.ppUser!.id]
  )).rows[0].c;
  res.json({ unread: c });
});

// FCM 디바이스 토큰 등록/갱신(푸시용)
router.post('/device-token', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const token = typeof req.body?.token === 'string' ? req.body.token.trim() : '';
  const platform = req.body?.platform === 'android' ? 'android' : 'ios';
  if (!token) { res.status(400).json({ error: 'token_required' }); return; }
  await pool.query(
    `INSERT INTO pp_device_tokens (token, user_id, platform, updated_at)
     VALUES ($1,$2,$3,CURRENT_TIMESTAMP)
     ON CONFLICT (token) DO UPDATE SET user_id=EXCLUDED.user_id, platform=EXCLUDED.platform, updated_at=CURRENT_TIMESTAMP`,
    [token, req.ppUser!.id, platform]
  );
  res.json({ success: true });
});

// 작성자 프로필 — 그 유저의 공개 도안 모두보기 + 내가 차단했는지
router.get('/users/:id/posts', requireAuth, async (req: AuthedRequest, res: Response): Promise<void> => {
  const pool = getPool(); if (!pool) { res.status(500).json({ error: 'db' }); return; }
  const id = parseInt(String(req.params.id), 10);
  const u = (await pool.query(`SELECT nickname FROM pp_users WHERE id=$1 AND status='active'`, [id])).rows[0];
  if (!u) { res.status(404).json({ error: 'not_found' }); return; }
  const rows = (await pool.query(
    `SELECT p.id, p.title, p.width, p.height, p.bead_count, p.like_count, p.download_count,
            p.preview_path, p.created_at, u.nickname AS author_nickname, p.author_id
       FROM pp_posts p LEFT JOIN pp_users u ON u.id=p.author_id
      WHERE p.author_id=$1 AND p.visibility='public' AND p.status='active'
      ORDER BY p.id DESC LIMIT 60`, [id]
  )).rows;
  const blocked = (await pool.query('SELECT 1 FROM pp_blocks WHERE blocker_id=$1 AND blocked_id=$2', [req.ppUser!.id, id])).rows.length > 0;
  res.json({ nickname: u.nickname, posts: rows.map(toListItem), blocked });
});

router.get('/health', (_req: Request, res: Response) => { res.json({ ok: true }); });

export default router;
