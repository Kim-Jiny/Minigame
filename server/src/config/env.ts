// dotenv 로딩을 다른 모든 import보다 먼저 수행하기 위한 side-effect 모듈.
// index.ts에서 이 파일을 가장 먼저 import하면, 나머지 모듈의 top-level에서
// process.env.JWT_SECRET 등을 읽을 때 값이 이미 채워져 있다.
//
// 개발 모드: .env.local 먼저 → .env 로 폴백
// 운영 모드: .env 만 로드 (Render 등은 어차피 프로세스 env로 주입)
import dotenv from 'dotenv';

if (process.env.NODE_ENV === 'development') {
  dotenv.config({ path: '.env.local' });
}
dotenv.config();
