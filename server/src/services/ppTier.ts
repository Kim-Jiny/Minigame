// [PP] PerlerPixel 창작자 계급 — 받은 좋아요 총합으로 산정. 별도 리포 소유. 삭제 금지.
//      임계치/이름은 여기 한 곳에서 관리한다(서버가 소스, 앱은 표시만).

export interface PpTier {
  level: number;
  name: string;
  icon: string;
  color: string;   // 닉네임 색 (hex)
  min: number;
}

// 받은 좋아요 총합(모든 공개 도안의 like_count 합) 기준 단계.
export const PP_TIERS: PpTier[] = [
  { level: 1, name: '새싹 비더', icon: '🌱', color: '#7CB342', min: 0 },
  { level: 2, name: '초보 비더', icon: '🧩', color: '#26A69A', min: 10 },
  { level: 3, name: '숙련 비더', icon: '⭐', color: '#42A5F5', min: 50 },
  { level: 4, name: '비즈 아티스트', icon: '🎨', color: '#7E57C2', min: 150 },
  { level: 5, name: '마스터 비더', icon: '🏆', color: '#EC407A', min: 500 },
  { level: 6, name: '픽셀 장인', icon: '💎', color: '#FF7043', min: 1500 },
  { level: 7, name: '레전드', icon: '👑', color: '#FFB300', min: 5000 },
];

// [PP] 업로드 승인 게이팅: 이 레벨 이상(= 마스터 비더, PP_TIERS[4])이면
//      관리자 승인 없이 공개 도안이 즉시 게시된다. 미만이면 status='review' 로 대기.
export const PP_AUTO_APPROVE_MIN_LEVEL = 5;
// 관리자 승인까지 걸릴 수 있는 최대 시간(시간). 앱 안내 문구/약관과 일치시킬 것.
export const PP_REVIEW_SLA_HOURS = 6;

/** 받은 좋아요 총합이 자동 게시 기준(마스터 비더+)을 충족하면 true. */
export function autoApproves(likesReceived: number): boolean {
  return tierFor(likesReceived).level >= PP_AUTO_APPROVE_MIN_LEVEL;
}

export interface TierInfo {
  level: number;
  name: string;
  icon: string;
  color: string;
  likesReceived: number;
  nextAt: number | null;    // 다음 단계 필요 좋아요 (최고 단계면 null)
  nextName: string | null;
}

/** 특정 레벨로 계급을 강제 지정(관리자 오버라이드). 진행도(nextAt/nextName)는 표시하지 않음. */
export function tierByLevel(level: number, likesReceived = 0): TierInfo {
  const t = PP_TIERS.find((x) => x.level === level) ?? PP_TIERS[0];
  return { level: t.level, name: t.name, icon: t.icon, color: t.color, likesReceived, nextAt: null, nextName: null };
}

/** tier_override 가 있으면 그 계급, 없으면 좋아요 기반 자동 계급. */
export function resolveTier(likesReceived: number, override?: number | null): TierInfo {
  return (override != null) ? tierByLevel(override, likesReceived) : tierFor(likesReceived);
}

export function tierFor(likesReceived: number): TierInfo {
  const likes = Math.max(0, likesReceived | 0);
  let current = PP_TIERS[0];
  for (const t of PP_TIERS) if (likes >= t.min) current = t;
  const next = PP_TIERS.find((t) => t.min > likes) ?? null;
  return {
    level: current.level,
    name: current.name,
    icon: current.icon,
    color: current.color,
    likesReceived: likes,
    nextAt: next?.min ?? null,
    nextName: next?.name ?? null,
  };
}
