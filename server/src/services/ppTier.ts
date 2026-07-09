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

export interface TierInfo {
  level: number;
  name: string;
  icon: string;
  color: string;
  likesReceived: number;
  nextAt: number | null;    // 다음 단계 필요 좋아요 (최고 단계면 null)
  nextName: string | null;
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
