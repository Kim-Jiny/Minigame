// CatchTheRule 추가 스테이지(서버 제공) 검증. 번들 puzzles.json 과 동일 스키마.
const LANGS = ['en', 'ko', 'ja', 'zh', 'es', 'fr', 'de'];

export interface PuzzleValidation {
  ok: boolean;
  errors: string[];
}

export function validateCtrPuzzle(p: any): PuzzleValidation {
  const e: string[] = [];
  const id = p?.id;
  const tag = typeof id === 'string' && id ? id : '(no id)';
  if (!p || typeof p !== 'object') return { ok: false, errors: ['퍼즐이 객체가 아님'] };

  if (typeof p.id !== 'string' || !p.id.trim()) e.push(`[${tag}] id 필요(문자열)`);
  if (!Number.isInteger(p.chapter)) e.push(`[${tag}] chapter 필요(정수)`);
  if (!Number.isInteger(p.order)) e.push(`[${tag}] order 필요(정수)`);

  const hasTokens = Array.isArray(p.tokens);
  const hasGrid = Array.isArray(p.grid);
  if (!hasTokens && !hasGrid) e.push(`[${tag}] tokens 또는 grid 필요(배열)`);

  if (typeof p.answer !== 'string' || !p.answer) e.push(`[${tag}] answer 필요(문자열)`);
  if (p.inputType !== 'keypad' && p.inputType !== 'choices') e.push(`[${tag}] inputType 은 keypad|choices`);
  if (p.inputType === 'choices' && !Array.isArray(p.choices)) e.push(`[${tag}] choices 필요(inputType=choices)`);

  // hints: 로케일별 정확히 3개 비어있지 않은 문자열
  if (!p.hints || typeof p.hints !== 'object') {
    e.push(`[${tag}] hints 필요(7개국어 객체)`);
  } else {
    for (const l of LANGS) {
      const arr = p.hints[l];
      if (!Array.isArray(arr) || arr.length !== 3 || arr.some((x: any) => typeof x !== 'string' || !x.trim())) {
        e.push(`[${tag}] hints.${l} 는 비어있지 않은 문자열 3개`);
      }
    }
  }
  // explanation: 로케일별 비어있지 않은 문자열
  if (!p.explanation || typeof p.explanation !== 'object') {
    e.push(`[${tag}] explanation 필요(7개국어 객체)`);
  } else {
    for (const l of LANGS) {
      if (typeof p.explanation[l] !== 'string' || !p.explanation[l].trim()) {
        e.push(`[${tag}] explanation.${l} 필요`);
      }
    }
  }
  return { ok: e.length === 0, errors: e };
}

/** 붙여넣은 텍스트(단일 객체 또는 배열) → 검증된 퍼즐 배열. */
export function parseAndValidate(text: string): { ok: boolean; puzzles: any[]; errors: string[] } {
  let parsed: any;
  try {
    parsed = JSON.parse(text);
  } catch (err: any) {
    return { ok: false, puzzles: [], errors: ['JSON 파싱 실패: ' + (err?.message || 'syntax error')] };
  }
  const list = Array.isArray(parsed) ? parsed : [parsed];
  if (list.length === 0) return { ok: false, puzzles: [], errors: ['퍼즐이 없음'] };
  const errors: string[] = [];
  for (const p of list) {
    const v = validateCtrPuzzle(p);
    if (!v.ok) errors.push(...v.errors);
  }
  // id 중복 체크
  const ids = list.map((p) => p?.id).filter(Boolean);
  const dup = ids.filter((x, i) => ids.indexOf(x) !== i);
  if (dup.length) errors.push('중복 id: ' + [...new Set(dup)].join(', '));
  return { ok: errors.length === 0, puzzles: list, errors };
}
