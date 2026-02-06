import { Router, Request, Response } from 'express';
import { getPool } from '../config/database';
import { verifyToken } from '../utils/jwt';

const router = Router();

// POST /api/inquiry - 문의 등록
router.post('/', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const { category, title, content } = req.body;

    if (!category || !title?.trim() || !content?.trim()) {
      res.status(400).json({ error: 'category, title, content are required' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `INSERT INTO dm_inquiries (user_id, category, title, content)
       VALUES ($1, $2, $3, $4)
       RETURNING id, category, title, content, status, created_at`,
      [payload.userId, category, title, content]
    );

    res.json({
      success: true,
      inquiry: result.rows[0],
    });
  } catch (error) {
    console.error('Create inquiry error:', error);
    res.status(500).json({ error: 'Failed to create inquiry' });
  }
});

// GET /api/inquiry - 내 문의 목록
router.get('/', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `SELECT id, category, title, content, status, reply, replied_at, is_read, created_at
       FROM dm_inquiries
       WHERE user_id = $1
       ORDER BY created_at DESC
       LIMIT 50`,
      [payload.userId]
    );

    res.json({
      dm_inquiries: result.rows,
    });
  } catch (error) {
    console.error('Get dm_inquiries error:', error);
    res.status(500).json({ error: 'Failed to get dm_inquiries' });
  }
});

// GET /api/inquiry/unread-count - 읽지 않은 답변 수
router.get('/unread-count', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    const result = await pool.query(
      `SELECT COUNT(*) FROM dm_inquiries
       WHERE user_id = $1 AND status = 'replied' AND is_read = FALSE`,
      [payload.userId]
    );

    res.json({
      count: parseInt(result.rows[0].count),
    });
  } catch (error) {
    console.error('Get unread count error:', error);
    res.status(500).json({ error: 'Failed to get unread count' });
  }
});

// PUT /api/inquiry/:id/read - 문의 읽음 처리
router.put('/:id/read', async (req: Request, res: Response): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ error: 'No token provided' });
      return;
    }

    const token = authHeader.split(' ')[1];
    const payload = verifyToken(token);

    if (!payload) {
      res.status(401).json({ error: 'Invalid token' });
      return;
    }

    const { id } = req.params;
    const pool = getPool();
    if (!pool) {
      res.status(500).json({ error: 'Database not available' });
      return;
    }

    await pool.query(
      `UPDATE dm_inquiries SET is_read = TRUE WHERE id = $1 AND user_id = $2`,
      [id, payload.userId]
    );

    res.json({ success: true });
  } catch (error) {
    console.error('Mark read error:', error);
    res.status(500).json({ error: 'Failed to mark as read' });
  }
});

export default router;
