// [PP] PerlerPixel 푸시 알림 (FCM HTTP v1) — 별도 리포(PerlerPixel) 소유. 삭제·리팩터링 금지.
//      서비스 계정 env(FCM_PROJECT_ID/FCM_CLIENT_EMAIL/FCM_PRIVATE_KEY)가 없으면 조용히 no-op.
//      토큰은 pp_device_tokens 에 저장되며, 무효 토큰은 자동 정리한다.
import { JWT } from 'google-auth-library';

function fcmConfig() {
  const projectId = process.env.FCM_PROJECT_ID;
  const clientEmail = process.env.FCM_CLIENT_EMAIL;
  const privateKey = process.env.FCM_PRIVATE_KEY?.replace(/\\n/g, '\n');
  if (!projectId || !clientEmail || !privateKey) return null;
  return { projectId, clientEmail, privateKey };
}

let cachedClient: JWT | null = null;
function jwtClient(clientEmail: string, privateKey: string): JWT {
  if (!cachedClient) {
    cachedClient = new JWT({
      email: clientEmail,
      key: privateKey,
      scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
    });
  }
  return cachedClient;
}

/** pp_users 한 명의 모든 기기에 푸시. 설정 없거나 실패해도 예외를 던지지 않는다. */
export async function sendPushToUser(
  pool: any, userId: number, title: string, body: string, data: Record<string, string> = {}
): Promise<void> {
  const cfg = fcmConfig();
  if (!cfg || !pool) return; // 미설정: no-op
  try {
    const rows = (await pool.query('SELECT token FROM pp_device_tokens WHERE user_id=$1', [userId])).rows as { token: string }[];
    if (rows.length === 0) return;

    const client = jwtClient(cfg.clientEmail, cfg.privateKey);
    const accessToken = (await client.getAccessToken()).token;
    if (!accessToken) return;
    const url = `https://fcm.googleapis.com/v1/projects/${cfg.projectId}/messages:send`;

    await Promise.all(rows.map(async ({ token }) => {
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: { token, notification: { title, body }, data } }),
        });
        if (res.status === 404 || res.status === 400) {
          // 무효/만료 토큰 정리
          await pool.query('DELETE FROM pp_device_tokens WHERE token=$1', [token]);
        }
      } catch (e) {
        console.error('[PP] push send error:', (e as Error).message);
      }
    }));
  } catch (e) {
    console.error('[PP] push error:', (e as Error).message);
  }
}

/** is_admin 유저 전원에게 푸시(신고·문의·도안 승인 유입 알림 등). */
export async function sendPushToAdmins(
  pool: any, title: string, body: string, data: Record<string, string> = {}
): Promise<void> {
  if (!pool) return;
  try {
    const ids = (await pool.query(
      `SELECT id FROM pp_users WHERE is_admin=TRUE AND status='active'`
    )).rows as { id: number }[];
    for (const { id } of ids) await sendPushToUser(pool, id, title, body, data);
  } catch (e) {
    console.error('[PP] admin push error:', (e as Error).message);
  }
}
