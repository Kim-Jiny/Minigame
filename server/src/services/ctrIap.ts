// [CTR] CatchTheRule 전용 — 파일 전체가 CTR 소유. 삭제·리팩터링 금지 (리포 루트 CLAUDE.md 참고).
// CatchTheRule 인앱결제 영수증 검증.
//  - iOS  : StoreKit2 의 서명된 트랜잭션(JWS) 서명·인증서 체인 검증 (Apple 자체 서명, 외부 API 불필요)
//  - Android: Play 결제 서명(SHA1withRSA)을 앱 공개키로 검증 (env CTR_PLAY_PUBLIC_KEY)
import jwt from 'jsonwebtoken';
import { X509Certificate, createVerify } from 'crypto';

export const IOS_BUNDLE_ID = 'com.jiny.CatchTheRule';
export const ANDROID_PACKAGE = 'com.jiny.catchtherule';

// 제품 → 지급 종류. iOS/Android 양쪽 제품ID 모두 매핑.
export const CTR_PRODUCTS: Record<string, { kind: 'remove_ads' | 'hints'; hints?: number }> = {
  'com.jiny.catchtherule.remove_ads': { kind: 'remove_ads' },
  'remove_ads': { kind: 'remove_ads' },
  ...Object.fromEntries(
    [5, 10, 20, 50].flatMap((n) => [
      [`com.jiny.catchtherule.hints_${n}`, { kind: 'hints' as const, hints: n }],
      [`hints_${n}`, { kind: 'hints' as const, hints: n }],
    ])
  ),
};

export interface VerifyResult {
  verified: boolean;
  productId?: string;
  transactionId?: string;
  environment?: string;
  reason?: string;
}

/** iOS StoreKit2 JWS(서명된 트랜잭션) 검증. */
export function verifyApple(jws: string): VerifyResult {
  try {
    const decoded = jwt.decode(jws, { complete: true });
    if (!decoded || typeof decoded === 'string') return { verified: false, reason: 'decode_failed' };
    const x5c = (decoded.header as any).x5c as string[] | undefined;
    if (!x5c || x5c.length < 2) return { verified: false, reason: 'no_x5c' };

    const certs = x5c.map((b64) => new X509Certificate(Buffer.from(b64, 'base64')));
    const leaf = certs[0];

    // 1) JWS 서명 검증 (leaf 공개키, ES256)
    const leafPem = leaf.publicKey.export({ type: 'spki', format: 'pem' }) as string;
    const payload = jwt.verify(jws, leafPem, { algorithms: ['ES256'] }) as any;

    // 2) 인증서 체인 검증 (leaf ← intermediate ← root)
    for (let i = 0; i < certs.length - 1; i++) {
      if (!certs[i].verify(certs[i + 1].publicKey)) {
        return { verified: false, reason: `chain_break_${i}` };
      }
    }
    const root = certs[certs.length - 1];
    if (!root.verify(root.publicKey)) return { verified: false, reason: 'root_not_self_signed' };

    // 3) 루트가 Apple Root CA 인지 확인 (+ 선택적 지문 핀닝: env CTR_APPLE_ROOT_SHA256)
    const pin = process.env.CTR_APPLE_ROOT_SHA256;
    if (pin) {
      if (root.fingerprint256.replace(/:/g, '').toUpperCase() !== pin.replace(/:/g, '').toUpperCase()) {
        return { verified: false, reason: 'root_fingerprint_mismatch' };
      }
    } else if (!/Apple Root CA/i.test(root.subject)) {
      return { verified: false, reason: 'root_not_apple' };
    }

    // 4) 번들ID 확인
    if (payload.bundleId && payload.bundleId !== IOS_BUNDLE_ID) {
      return { verified: false, reason: 'bundle_mismatch' };
    }

    return {
      verified: true,
      productId: payload.productId,
      transactionId: String(payload.transactionId ?? payload.originalTransactionId ?? ''),
      environment: payload.environment,
    };
  } catch (e: any) {
    return { verified: false, reason: 'apple_verify_error:' + (e?.message || 'unknown') };
  }
}

/** Android Play 결제 서명 검증 (originalJson + signature, 앱 공개키). */
export function verifyAndroid(originalJson: string, signature: string): VerifyResult {
  try {
    const keyB64 = process.env.CTR_PLAY_PUBLIC_KEY;
    if (!keyB64) return { verified: false, reason: 'no_public_key_configured' };
    const pem =
      '-----BEGIN PUBLIC KEY-----\n' +
      (keyB64.match(/.{1,64}/g) || []).join('\n') +
      '\n-----END PUBLIC KEY-----\n';
    const v = createVerify('RSA-SHA1');
    v.update(originalJson, 'utf8');
    const ok = v.verify(pem, Buffer.from(signature, 'base64'));
    if (!ok) return { verified: false, reason: 'bad_signature' };

    const data = JSON.parse(originalJson);
    if (data.packageName && data.packageName !== ANDROID_PACKAGE) {
      return { verified: false, reason: 'package_mismatch' };
    }
    return {
      verified: true,
      productId: data.productId,
      transactionId: String(data.orderId || data.purchaseToken || ''),
      environment: data.purchaseState === 0 ? 'Production' : 'Pending',
    };
  } catch (e: any) {
    return { verified: false, reason: 'android_verify_error:' + (e?.message || 'unknown') };
  }
}
