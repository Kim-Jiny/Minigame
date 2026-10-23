/* [MFA] 성인의 수학 관리자 화면 — 통계 · 소코반/광고 · 유저 · 결제 · 문의.
   index.html 은 #mfaDashboard 껍데기와 이 파일 로드만 맡고, 화면과 동작은 전부 여기서 만든다.
   전역에는 mfaEnter 하나만 노출하고, 클릭은 data-act 이벤트 위임으로 처리한다. */
(function () {
  'use strict';

  // ───────────────────────── 상태 ─────────────────────────
  const S = {
    built: false,
    tab: 'stats',
    days: 30, // 통계 탭 기간
    skDays: 30, // 소코반·광고 탭 기간
    users: { page: 1 },
    purchases: { page: 1 },
    inqStatus: 'all',
    inquiries: [],
    inqCounts: null,
    curInq: null,
    curUserId: null,
  };
  const TABS = [
    ['stats', '통계'],
    ['games', '소코반·광고'],
    ['users', '유저'],
    ['purchases', '결제'],
    ['inquiries', '문의'],
  ];

  // ───────────────────────── 유틸 ─────────────────────────
  const esc = (s) =>
    String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (n) => (Number(n) || 0).toLocaleString('ko-KR');
  const pad = (n) => String(n).padStart(2, '0');
  const pct = (a, b) => (b > 0 ? Math.round((a / b) * 1000) / 10 : null);
  const pctTxt = (v) => (v == null ? '-' : v + '%');
  const fd = (s) => {
    if (!s) return '-';
    const d = new Date(s);
    return `${d.getFullYear()}.${pad(d.getMonth() + 1)}.${pad(d.getDate())}`;
  };
  const fdt = (s) => {
    if (!s) return '-';
    const d = new Date(s);
    return `${fd(s)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  };
  const ago = (s) => {
    if (!s) return '';
    const m = Math.max(0, Math.round((Date.now() - new Date(s).getTime()) / 60000));
    if (m < 60) return `${m}분 전`;
    if (m < 1440) return `${Math.floor(m / 60)}시간 전`;
    return `${Math.floor(m / 1440)}일 전`;
  };
  const qs = (o) => {
    const p = new URLSearchParams();
    Object.keys(o).forEach((k) => {
      if (o[k] !== '' && o[k] != null && o[k] !== false) p.set(k, o[k] === true ? '1' : o[k]);
    });
    return p.toString();
  };
  const root = () => document.getElementById('mfaDashboard');
  const $ = (sel, el) => (el || root()).querySelector(sel);
  const val = (sel) => {
    const el = $(sel);
    return el ? el.value.trim() : '';
  };
  const get = (path, params) => api('/api/admin/mfa/' + path + (params ? '?' + qs(params) : ''));
  const failed = (r) => !r || r.error;

  function toast(msg, kind) {
    let c = document.getElementById('mfaToasts');
    if (!c) {
      c = document.createElement('div');
      c.id = 'mfaToasts';
      document.body.appendChild(c);
    }
    const t = document.createElement('div');
    t.className = 't ' + (kind || '');
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => t.remove(), 3200);
  }

  const skeleton = (n) => '<div class="mfa-kpis">' + '<div class="mfa-skel"></div>'.repeat(n || 6) + '</div>';
  const empty = (msg, retry) =>
    `<div class="mfa-empty">${msg}${retry ? `<br><button class="mfa-btn" data-act="${retry}" style="margin-top:12px">다시 시도</button>` : ''}</div>`;

  const kpi = (label, value, sub, cls) =>
    `<div class="mfa-kpi ${cls || ''}"><div class="label">${esc(label)}</div><div class="value">${value}</div><div class="sub">${sub || ''}</div></div>`;

  // 전일/전 기간 대비 증감 표시
  const delta = (cur, prev) => {
    if (prev == null) return '';
    const d = cur - prev;
    if (d === 0) return `어제 ${num(prev)} · 변동 없음`;
    return `어제 ${num(prev)} · <span class="${d > 0 ? 'mfa-up' : 'mfa-down'}">${d > 0 ? '▲' : '▼'} ${num(Math.abs(d))}</span>`;
  };

  const meter = (p, tone) =>
    `<div class="mfa-meter"><div class="track"><div class="fill ${tone || ''}" style="width:${Math.max(0, Math.min(100, p || 0))}%"></div></div><b>${pctTxt(p)}</b></div>`;

  // 비율 → 초록 농도(재방문율 표 색칠)
  const heat = (p, full) => {
    if (p == null) return '<span class="mfa-heat" style="color:#b6bbc9">-</span>';
    const a = Math.min(1, p / (full || 50));
    return `<span class="mfa-heat" style="background:rgba(31,169,113,${(0.08 + a * 0.5).toFixed(2)});color:${a > 0.6 ? '#0b5a3d' : '#1f2330'}">${p}%</span>`;
  };

  // ───────────────────────── SVG 차트 ─────────────────────────
  function niceMax(v) {
    if (v <= 0) return 1;
    const p = Math.pow(10, Math.floor(Math.log10(v)));
    for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
    return 10 * p;
  }

  // o = { labels, series:[{name,color,data}], type:'line'|'bar', height }
  function chartHtml(o) {
    const n = o.labels.length;
    const W = 640;
    const H = o.height || 190;
    const pl = 36;
    const pr = 8;
    const pt = 10;
    const pb = 22;
    const iw = W - pl - pr;
    const ih = H - pt - pb;
    const max = niceMax(Math.max(0, ...o.series.flatMap((s) => s.data)));
    const y = (v) => pt + ih - (v / max) * ih;
    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img">`;
    for (let i = 0; i <= 4; i++) {
      const v = (max / 4) * i;
      svg += `<line class="grid" x1="${pl}" x2="${W - pr}" y1="${y(v)}" y2="${y(v)}"/><text x="${pl - 6}" y="${y(v) + 3}" text-anchor="end">${num(Math.round(v * 10) / 10)}</text>`;
    }
    const step = Math.max(1, Math.ceil(n / 8));
    const bar = o.type === 'bar';
    const gw = iw / Math.max(1, n);
    const cx = (i) => (bar ? pl + gw * i + gw / 2 : pl + (n <= 1 ? iw / 2 : (iw * i) / (n - 1)));
    o.labels.forEach((l, i) => {
      if (i % step === 0 || i === n - 1) svg += `<text x="${cx(i)}" y="${H - 6}" text-anchor="middle">${esc(String(l).slice(5))}</text>`;
    });
    o.series.forEach((s, si) => {
      if (bar) {
        const bw = Math.min(26, (gw * 0.72) / o.series.length);
        s.data.forEach((v, i) => {
          const x = cx(i) - (bw * o.series.length) / 2 + bw * si;
          svg += `<rect x="${x}" y="${y(v)}" width="${bw - 1}" height="${Math.max(0, pt + ih - y(v))}" rx="3" fill="${s.color}"><title>${esc(o.labels[i])} · ${esc(s.name)}: ${num(v)}</title></rect>`;
        });
      } else {
        const pts = s.data.map((v, i) => `${cx(i).toFixed(1)},${y(v).toFixed(1)}`);
        if (si === 0 && n > 1) svg += `<polygon points="${cx(0)},${pt + ih} ${pts.join(' ')} ${cx(n - 1)},${pt + ih}" fill="${s.color}" opacity=".09"/>`;
        svg += `<polyline points="${pts.join(' ')}" fill="none" stroke="${s.color}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>`;
        if (n <= 45) s.data.forEach((v, i) => (svg += `<circle cx="${cx(i)}" cy="${y(v)}" r="2.6" fill="#fff" stroke="${s.color}" stroke-width="1.8"><title>${esc(o.labels[i])} · ${esc(s.name)}: ${num(v)}</title></circle>`));
      }
    });
    svg += '</svg>';
    const legend = o.series.length > 1 || o.legend
      ? `<div class="mfa-legend">${o.series.map((s) => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join('')}</div>`
      : '';
    return legend + `<div class="mfa-chart">${svg}</div>`;
  }

  const seg = (act, cur, opts) =>
    `<div class="mfa-seg">${opts.map(([v, l]) => `<button data-act="${act}" data-v="${v}" class="${String(cur) === String(v) ? 'active' : ''}">${l}</button>`).join('')}</div>`;

  // ───────────────────────── 뼈대 ─────────────────────────
  function build() {
    if (S.built) return;
    S.built = true;
    const el = root();
    el.innerHTML =
      `<div class="mfa-tabs">${TABS.map(([k, l]) => `<button class="mfa-tab" data-act="tab" data-v="${k}" data-tab="${k}">${l}${k === 'inquiries' ? ' <span class="mfa-count" id="mfaInqBadge" style="display:none">0</span>' : ''}</button>`).join('')}</div>` +
      TABS.map(([k]) => `<section class="mfa-pane" id="mfa-pane-${k}"></section>`).join('');
    el.addEventListener('click', onClick);
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      const t = e.target.closest('[data-enter]');
      if (t) ACTIONS[t.dataset.enter] && ACTIONS[t.dataset.enter](t);
    });
    el.addEventListener('change', (e) => {
      const t = e.target.closest('[data-change]');
      if (t) ACTIONS[t.dataset.change] && ACTIONS[t.dataset.change](t);
    });
    buildUsersPane();
    buildPurchasesPane();
    buildInquiriesPane();
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') document.querySelectorAll('.mfa-modal.show').forEach((m) => m.classList.remove('show'));
    });
  }

  function onClick(e) {
    const t = e.target.closest('[data-act]');
    if (!t) return;
    const fn = ACTIONS[t.dataset.act];
    if (fn) fn(t);
  }

  function showTab(name) {
    S.tab = name;
    try { sessionStorage.setItem('mfaTab', name); } catch (_) { /* 저장소 차단돼도 무시 */ }
    root().querySelectorAll('.mfa-tab').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
    root().querySelectorAll('.mfa-pane').forEach((p) => p.classList.toggle('active', p.id === 'mfa-pane-' + name));
    if (name === 'stats') loadStats();
    else if (name === 'games') loadGames();
    else if (name === 'users') loadUsers();
    else if (name === 'purchases') loadPurchases();
    else if (name === 'inquiries') loadInquiries();
  }

  window.mfaEnter = function () {
    build();
    let tab = 'stats';
    try { tab = sessionStorage.getItem('mfaTab') || 'stats'; } catch (_) { /* 무시 */ }
    if (!TABS.some(([k]) => k === tab)) tab = 'stats';
    showTab(tab);
    refreshInquiryBadge();
  };

  // ───────────────────────── 통계 ─────────────────────────
  async function loadStats() {
    const pane = $('#mfa-pane-stats');
    pane.innerHTML = skeleton(8);
    try {
      const [s, d, r] = await Promise.all([get('stats'), get('stats/daily', { days: S.days }), get('stats/retention', { days: 14 })]);
      if (failed(s) || failed(d) || failed(r)) throw new Error('load');
      pane.innerHTML = renderStats(s, d.rows, r.rows);
    } catch (e) {
      pane.innerHTML = empty('통계를 불러오지 못했어요.', 'stats-reload');
    }
  }

  function renderStats(s, rows, ret) {
    const last = rows[rows.length - 1] || {};
    const prev = rows[rows.length - 2] || null;
    const labels = rows.map((r) => r.day);
    const periodPurchases = rows.reduce((a, r) => a + r.purchases, 0);
    const sticky = pct(s.dau, s.mau);
    const matured = ret.filter((c) => c.age >= 1);
    const d1all = pct(matured.reduce((a, c) => a + c.d1, 0), matured.reduce((a, c) => a + c.size, 0));
    const m7 = ret.filter((c) => c.age >= 7);
    const d7all = pct(m7.reduce((a, c) => a + c.d7, 0), m7.reduce((a, c) => a + c.size, 0));

    const kpis = [
      kpi('총 가입자', num(s.signups.total), `오늘 +${num(s.signups.today)} · 7일 +${num(s.signups.week)} · 30일 +${num(s.signups.month)}`, 'accent'),
      kpi('DAU (오늘)', num(s.dau), delta(s.dau, prev && prev.dau), 'accent'),
      kpi('WAU', num(s.wau), '최근 7일 활성 기기'),
      kpi('MAU', num(s.mau), `DAU/MAU ${pctTxt(sticky)}`),
      kpi('신규 기기 (오늘)', num(last.new_devices || 0), delta(last.new_devices || 0, prev && prev.new_devices)),
      kpi('설치 기기 누적', num(s.devices.ios + s.devices.android), `iOS ${num(s.devices.ios)} · Android ${num(s.devices.android)}`),
      kpi('출석 (오늘)', num(s.checkins.today), `최근 7일 ${num(s.checkins.week)}`),
      kpi(`결제 ${S.days}일`, num(periodPurchases), `검증 완료 기준`, 'ok'),
      kpi('D1 재방문', pctTxt(d1all), '최근 14일 신규 기기 평균'),
      kpi('D7 재방문', pctTxt(d7all), '7일 지난 코호트만'),
    ].join('');

    const kinds = {};
    (s.purchases || []).forEach((p) => {
      const key = `${p.kind || '-'} · ${p.platform}`;
      kinds[key] = kinds[key] || { ok: 0, bad: 0 };
      kinds[key][p.verified ? 'ok' : 'bad'] += p.c;
    });
    const kindRows = Object.keys(kinds).map((k) => `<div class="mfa-rowline"><span>${esc(k)}</span><span><b>${num(kinds[k].ok)}</b>${kinds[k].bad ? ` <span class="mfa-badge bad">실패 ${num(kinds[k].bad)}</span>` : ''}</span></div>`).join('') || '<div class="mfa-empty">데이터 없음</div>';
    const totalDev = s.devices.ios + s.devices.android;

    return (
      `<div class="mfa-bar">${seg('stats-days', S.days, [[7, '7일'], [30, '30일'], [90, '90일']])}<span class="grow"></span><span class="mfa-note">DAU·신규 기기는 오늘 값이 집계 중이라 어제보다 작을 수 있어요</span><button class="mfa-btn" data-act="stats-reload">새로고침</button></div>` +
      `<div class="mfa-kpis">${kpis}</div>` +
      `<div class="mfa-grid2">` +
      `<div class="mfa-panel"><h3>일별 활성 기기 · 신규 기기</h3>${chartHtml({ labels, series: [{ name: 'DAU', color: '#7c6cf2', data: rows.map((r) => r.dau) }, { name: '신규 기기', color: '#3ccfae', data: rows.map((r) => r.new_devices) }] })}</div>` +
      `<div class="mfa-panel"><h3>가입 · 출석 · 결제</h3>${chartHtml({ type: 'bar', labels, series: [{ name: '가입', color: '#7c6cf2', data: rows.map((r) => r.signups) }, { name: '출석', color: '#ff8fb1', data: rows.map((r) => r.checkins) }, { name: '결제', color: '#ff9a3d', data: rows.map((r) => r.purchases) }] })}</div>` +
      `</div>` +
      `<div class="mfa-panel"><h3>신규 기기 재방문율 <small>최근 14일 코호트 · 첫 실행 다음날(D1) / 7일째(D7)</small></h3>` +
      (ret.length
        ? `<div class="mfa-table-wrap" style="box-shadow:none"><table class="mfa-table"><thead><tr><th>첫 실행일</th><th class="num">신규 기기</th><th class="num">D1</th><th class="num">D7</th></tr></thead><tbody>${ret.map((c) => `<tr><td>${esc(c.day)}</td><td class="num">${num(c.size)}</td><td class="num">${heat(c.age >= 1 ? pct(c.d1, c.size) : null, 50)}</td><td class="num">${heat(c.age >= 7 ? pct(c.d7, c.size) : null, 30)}</td></tr>`).join('')}</tbody></table></div>`
        : '<div class="mfa-empty">최근 14일 신규 기기가 없어요</div>') +
      `</div>` +
      `<div class="mfa-grid2">` +
      `<div class="mfa-panel"><h3>플랫폼 비중</h3><div class="mfa-rowline"><span>iOS</span><span style="width:60%">${meter(pct(s.devices.ios, totalDev))}</span></div><div class="mfa-rowline"><span>Android</span><span style="width:60%">${meter(pct(s.devices.android, totalDev), 'ok')}</span></div></div>` +
      `<div class="mfa-panel"><h3>결제 (종류 · 플랫폼)</h3>${kindRows}</div>` +
      `<div class="mfa-panel"><h3>힌트쿠폰 경제</h3><div class="mfa-rowline"><span>누적 발급 (출석+구매)</span><b>${num(s.coupons.granted)}</b></div><div class="mfa-rowline"><span>누적 소비</span><b>${num(s.coupons.spent)}</b></div><div class="mfa-rowline"><span>관리자 조정 순증감</span><b>${s.coupons.adminNet > 0 ? '+' : ''}${num(s.coupons.adminNet || 0)}</b></div></div>` +
      `</div>`
    );
  }

  // ───────────────────────── 소코반 · 광고 ─────────────────────────
  const AD_LABEL = { restart: '새로하기 (소코반)', next: '다음 단계 (소코반)', quiz: '문제 풀이' };

  async function loadGames() {
    const pane = $('#mfa-pane-games');
    pane.innerHTML = skeleton(6);
    try {
      const [sk, ad] = await Promise.all([get('stats/sokoban', { days: S.skDays }), get('stats/ads', { days: S.skDays })]);
      if (failed(sk) || failed(ad)) throw new Error('load');
      pane.innerHTML = renderGames(sk, ad);
    } catch (e) {
      pane.innerHTML = empty('지표를 불러오지 못했어요.', 'games-reload');
    }
  }

  function renderGames(sk, ad) {
    const sm = sk.summary;
    const noData = !sm.starts && !sm.players && !ad.summary.shown;
    const clearRate = pct(sm.clears, sm.starts);

    const levels = sk.levels.map((l) => {
      const rate = pct(l.clears, l.starts);
      const restartRate = pct(l.restarts, l.starts);
      const stuck = l.starts >= 3 && rate != null && rate < 40;
      return { ...l, rate, restartRate, stuck };
    });
    const stuckList = levels.filter((l) => l.starts >= 3 && l.rate != null).sort((a, b) => a.rate - b.rate).slice(0, 5);

    const skKpis = [
      kpi('플레이 기기', num(sm.players), `최근 ${sk.days}일`, 'accent'),
      kpi('시작', num(sm.starts), '단계 진입 횟수'),
      kpi('클리어', num(sm.clears), `클리어율 ${pctTxt(clearRate)}`, 'ok'),
      kpi('새로하기', num(sm.restarts), `시작 대비 ${pctTxt(pct(sm.restarts, sm.starts))}`),
      kpi('실패', num(sm.fails), '걸음 초과 · 폭탄'),
      kpi('최고 도달 단계', sm.best_level ? sm.best_level + '단계' : '-', '클리어 기준'),
    ].join('');

    const dailyShown = ad.daily.reduce((a, r) => a + r.shown, 0);
    const dailyDau = ad.daily.reduce((a, r) => a + r.dau, 0);
    const adKpis = [
      kpi('전면 광고 노출', num(ad.summary.shown), `최근 ${ad.days}일`, 'accent'),
      kpi('닫힘 확인', num(ad.summary.dismissed), `노출 대비 ${pctTxt(pct(ad.summary.dismissed, ad.summary.shown))}`),
      kpi('노출 기기', num(ad.summary.devices), '광고를 본 기기 수'),
      kpi('기기당 노출', ad.summary.devices ? (ad.summary.shown / ad.summary.devices).toFixed(1) : '-', '노출 ÷ 노출 기기'),
      kpi('DAU당 노출', dailyDau ? (dailyShown / dailyDau).toFixed(2) : '-', '활성 기기·일 당 평균'),
    ].join('');

    return (
      `<div class="mfa-bar">${seg('games-days', S.skDays, [[7, '7일'], [30, '30일'], [90, '90일']])}<span class="grow"></span><button class="mfa-btn" data-act="games-reload">새로고침</button></div>` +
      (noData ? `<div class="mfa-panel"><div class="mfa-empty">아직 수집된 이벤트가 없어요.<br>이벤트 전송이 들어간 앱 버전이 배포되고 사용자가 쓰기 시작하면 여기에 쌓여요.</div></div>` : '') +
      `<h3 style="margin:6px 2px 12px;font-size:15px">🎁 소코반</h3><div class="mfa-kpis">${skKpis}</div>` +
      `<div class="mfa-panel"><h3>일별 플레이</h3>${chartHtml({ labels: sk.daily.map((r) => r.day), series: [{ name: '플레이 기기', color: '#7c6cf2', data: sk.daily.map((r) => r.players) }, { name: '시작', color: '#ff8fb1', data: sk.daily.map((r) => r.starts) }, { name: '클리어', color: '#3ccfae', data: sk.daily.map((r) => r.clears) }] })}</div>` +
      (stuckList.length
        ? `<div class="mfa-panel"><h3>막히는 단계 <small>시작 3회 이상 · 클리어율 낮은 순</small></h3>${stuckList.map((l) => `<div class="mfa-rowline"><span><b>${l.level}단계</b> · 시작 ${num(l.starts)} / 클리어 ${num(l.clears)}</span><span style="width:50%">${meter(l.rate, l.rate < 40 ? 'bad' : l.rate < 70 ? 'warn' : 'ok')}</span></div>`).join('')}</div>`
        : '') +
      `<div class="mfa-panel"><h3>단계별 지표</h3>${
        levels.length
          ? `<div class="mfa-table-wrap" style="box-shadow:none"><table class="mfa-table"><thead><tr><th>단계</th><th class="num">시작</th><th class="num">시작 기기</th><th class="num">클리어</th><th>클리어율</th><th class="num">실패</th><th class="num">새로하기</th><th class="num">이어하기</th><th class="num">평균 걸음</th><th class="num">평균 별</th></tr></thead><tbody>${levels
              .map((l) => `<tr class="${l.stuck ? 'hot' : ''}"><td><b>${l.level}</b>${l.stuck ? ' <span class="mfa-badge warn">막힘</span>' : ''}</td><td class="num">${num(l.starts)}</td><td class="num">${num(l.start_devices)}</td><td class="num">${num(l.clears)}</td><td>${meter(l.rate, l.rate == null ? '' : l.rate < 40 ? 'bad' : l.rate < 70 ? 'warn' : 'ok')}</td><td class="num">${num(l.fails)}</td><td class="num">${num(l.restarts)}</td><td class="num">${num(l.resumes)}</td><td class="num">${l.avg_moves == null ? '-' : num(l.avg_moves)}</td><td class="num">${l.avg_stars == null ? '-' : l.avg_stars}</td></tr>`)
              .join('')}</tbody></table></div>`
          : '<div class="mfa-empty">단계 데이터가 없어요</div>'
      }</div>` +
      `<h3 style="margin:22px 2px 12px;font-size:15px">📺 전면 광고</h3><div class="mfa-kpis">${adKpis}</div>` +
      `<div class="mfa-grid2">` +
      `<div class="mfa-panel"><h3>일별 노출 · 닫힘</h3>${chartHtml({ type: 'bar', labels: ad.daily.map((r) => r.day), series: [{ name: '노출', color: '#7c6cf2', data: ad.daily.map((r) => r.shown) }, { name: '닫힘', color: '#ff8fb1', data: ad.daily.map((r) => r.dismissed) }] })}</div>` +
      `<div class="mfa-panel"><h3>노출 위치별</h3>${
        ad.byPlacement.length
          ? ad.byPlacement.map((p) => `<div class="mfa-rowline"><span>${esc(AD_LABEL[p.placement] || p.placement)}</span><span><b>${num(p.shown)}</b> <span class="mfa-note">닫힘 ${num(p.dismissed)}</span></span></div>`).join('')
          : '<div class="mfa-empty">노출 데이터 없음</div>'
      }<div class="mfa-note" style="margin-top:10px">노출은 앱이 광고 표시를 요청한 시점 기준이에요. 닫히지 않고 앱이 종료되면 닫힘이 빠질 수 있어요.</div></div>` +
      `</div>`
    );
  }

  // ───────────────────────── 유저 ─────────────────────────
  function buildUsersPane() {
    $('#mfa-pane-users').innerHTML =
      `<div class="mfa-bar">` +
      `<input class="mfa-input search" id="mfaUserQ" placeholder="닉네임 · 이메일 · ID 검색" data-enter="users-search">` +
      `<select class="mfa-select" id="mfaUserProvider" data-change="users-search"><option value="">로그인 방식 전체</option><option value="google">Google</option><option value="apple">Apple</option><option value="kakao">Kakao</option></select>` +
      `<select class="mfa-select" id="mfaUserSort" data-change="users-search"><option value="recent">가입 최신순</option><option value="login">최근 로그인순</option><option value="balance">쿠폰 많은 순</option></select>` +
      `<label class="mfa-check"><input type="checkbox" id="mfaUserBal" data-change="users-search"> 쿠폰 보유</label>` +
      `<label class="mfa-check"><input type="checkbox" id="mfaUserAds" data-change="users-search"> 광고 제거</label>` +
      `<button class="mfa-btn primary" data-act="users-search">검색</button></div>` +
      `<div id="mfaUsersBody">${skeleton(1)}</div><div id="mfaUsersPager" class="mfa-pager"></div>`;
  }

  async function loadUsers() {
    const body = $('#mfaUsersBody');
    try {
      const d = await get('users', {
        q: val('#mfaUserQ'),
        provider: val('#mfaUserProvider'),
        sort: val('#mfaUserSort'),
        hasBalance: $('#mfaUserBal').checked,
        adsRemoved: $('#mfaUserAds').checked,
        page: S.users.page,
        limit: 20,
      });
      if (failed(d)) throw new Error('load');
      if (!d.users.length) {
        body.innerHTML = empty('조건에 맞는 유저가 없어요.');
        $('#mfaUsersPager').innerHTML = '';
        return;
      }
      body.innerHTML = `<div class="mfa-table-wrap"><table class="mfa-table"><thead><tr><th>ID</th><th>닉네임</th><th>이메일</th><th>로그인</th><th class="num">쿠폰</th><th>구매</th><th>가입일</th><th>최근 로그인</th></tr></thead><tbody>${d.users
        .map((u) => `<tr class="click" data-act="user-open" data-id="${u.id}"><td class="muted">${u.id}</td><td><b>${esc(u.nickname || '-')}</b></td><td class="muted">${esc(u.email || '-')}</td><td><span class="mfa-badge">${esc(u.provider)}</span></td><td class="num">${num(u.hint_coupon_balance)}</td><td>${u.ads_removed ? '<span class="mfa-badge ok">광고 제거</span> ' : ''}${u.purchase_count ? `<span class="mfa-badge brand">${u.purchase_count}건</span>` : '<span class="muted">-</span>'}</td><td class="muted">${fd(u.created_at)}</td><td class="muted">${fdt(u.last_login)}</td></tr>`)
        .join('')}</tbody></table></div>`;
      pager('#mfaUsersPager', d, 'users-page');
    } catch (e) {
      body.innerHTML = empty('유저를 불러오지 못했어요.', 'users-search');
    }
  }

  function pager(sel, d, act) {
    const el = $(sel);
    if (!d.totalPages || d.totalPages <= 1) {
      el.innerHTML = d.total ? `<span>총 ${num(d.total)}건</span>` : '';
      return;
    }
    el.innerHTML = `<button class="mfa-btn" data-act="${act}" data-v="-1" ${d.page <= 1 ? 'disabled' : ''}>← 이전</button><span>${d.page} / ${d.totalPages} · 총 ${num(d.total)}건</span><button class="mfa-btn" data-act="${act}" data-v="1" ${d.page >= d.totalPages ? 'disabled' : ''}>다음 →</button>`;
  }

  // ── 유저 상세 모달 ──
  function ensureModal(id, title, extraClass) {
    let m = document.getElementById(id);
    if (!m) {
      m = document.createElement('div');
      m.id = id;
      m.className = 'mfa-modal';
      m.innerHTML = `<div class="box" ${extraClass ? `style="${extraClass}"` : ''}><div class="head"><h2></h2><button class="x" data-close>&times;</button></div><div class="content"></div></div>`;
      m.addEventListener('click', (e) => {
        if (e.target === m || e.target.closest('[data-close]')) m.classList.remove('show');
        const t = e.target.closest('[data-m]');
        if (t && MODAL_ACTIONS[t.dataset.m]) MODAL_ACTIONS[t.dataset.m](t);
      });
      document.body.appendChild(m);
    }
    m.querySelector('h2').textContent = title;
    return m;
  }

  async function openUser(id) {
    S.curUserId = id;
    const m = ensureModal('mfaUserModal', `유저 #${id}`, 'max-width:820px');
    const c = m.querySelector('.content');
    c.innerHTML = '<div class="body"><div class="mfa-skel" style="height:220px"></div></div>';
    m.classList.add('show');
    try {
      const d = await get('users/' + id);
      if (failed(d)) throw new Error('load');
      c.innerHTML = renderUser(d);
    } catch (e) {
      c.innerHTML = '<div class="body"><div class="mfa-empty">유저 정보를 불러오지 못했어요.</div></div>';
    }
  }

  const REASON = { checkin: '출석', purchase: '구매', spend: '소비', admin: '관리자' };

  function renderUser(d) {
    const u = d.user;
    const p = d.progressSummary;
    return (
      `<div class="body">` +
      `<div class="sec"><h4>기본 정보</h4><div class="kv"><div>닉네임</div><div><b>${esc(u.nickname || '-')}</b></div><div>이메일</div><div>${esc(u.email || '-')}</div><div>로그인 방식</div><div>${esc(u.provider)}</div><div>가입일</div><div>${fdt(u.created_at)}</div><div>최근 로그인</div><div>${fdt(u.last_login)} <span class="hint">${ago(u.last_login)}</span></div><div>광고 제거</div><div>${d.adsRemoved ? '<span class="mfa-badge ok">구매함</span>' : '-'}</div><div>힌트쿠폰 잔액</div><div><b style="font-size:16px">${num(u.hint_coupon_balance)}</b>개</div></div></div>` +
      `<div class="sec"><h4>힌트쿠폰 수동 조정 <span class="hint">· CS 보상·오지급 정정용 · 사유가 이력에 남아요</span></h4><div class="adjust">` +
      `<div class="row"><input class="mfa-input" id="mfaAdjAmt" type="number" min="1" max="100" value="1" style="width:90px"><span class="hint">개</span>${[1, 3, 5, 10].map((n) => `<button class="chip" data-m="adj-amt" data-v="${n}">${n}</button>`).join('')}</div>` +
      `<div class="row"><input class="mfa-input" id="mfaAdjNote" maxlength="150" placeholder="사유 (필수) 예: 결제 오류 보상, 문의 #12" style="flex:1;min-width:200px"></div>` +
      `<div class="row"><button class="mfa-btn primary" data-m="adj-plus">+ 지급</button><button class="mfa-btn danger" data-m="adj-minus">− 회수</button></div></div></div>` +
      (p ? `<div class="sec"><h4>학습 진도 요약</h4><div class="kv"><div>총 풀이수</div><div>${num(p.totalSolved)}</div><div>총 정답수</div><div>${num(p.totalCorrect)} <span class="hint">${pctTxt(pct(p.totalCorrect, p.totalSolved))}</span></div><div>연속 출석일</div><div>${num(p.streakDays)}일</div><div>동기화 시각</div><div>${fdt(p.updatedAt)}</div></div></div>` : '') +
      `<div class="sec"><h4>힌트쿠폰 이력 (최근 50건)</h4>${
        d.couponLog.length
          ? `<table class="mini"><thead><tr><th>일시</th><th>사유</th><th>변동</th><th>잔액</th><th>메모</th></tr></thead><tbody>${d.couponLog.map((c) => `<tr><td>${fdt(c.created_at)}</td><td>${esc(REASON[c.reason] || c.reason)}</td><td style="color:${c.delta > 0 ? '#3ccfae' : '#ef6f7b'};font-weight:700">${c.delta > 0 ? '+' : ''}${c.delta}</td><td>${num(c.balance_after)}</td><td class="hint">${esc(c.note || '')}</td></tr>`).join('')}</tbody></table>`
          : '<div class="hint">이력이 없어요</div>'
      }</div>` +
      `<div class="sec"><h4>결제 내역 (${d.purchases.length})</h4>${
        d.purchases.length
          ? `<table class="mini"><thead><tr><th>일시</th><th>플랫폼</th><th>상품</th><th>종류</th><th>검증</th></tr></thead><tbody>${d.purchases.map((x) => `<tr><td>${fdt(x.created_at)}</td><td>${esc(x.platform)}</td><td>${esc(x.product_id)}</td><td>${esc(x.kind || '-')}</td><td>${x.verified ? '<span class="mfa-badge ok">검증됨</span>' : `<span class="mfa-badge bad">${esc(x.status || 'failed')}</span>`}</td></tr>`).join('')}</tbody></table>`
          : '<div class="hint">결제 내역이 없어요</div>'
      }</div></div>`
    );
  }

  async function adjustCoupons(sign) {
    const amt = parseInt(document.getElementById('mfaAdjAmt').value, 10);
    const note = document.getElementById('mfaAdjNote').value.trim();
    if (!Number.isInteger(amt) || amt < 1 || amt > 100) return toast('수량은 1~100 사이로 입력하세요', 'bad');
    if (note.length < 2) {
      document.getElementById('mfaAdjNote').focus();
      return toast('사유를 입력하세요 (2자 이상)', 'bad');
    }
    const delta = sign * amt;
    if (!confirm(`유저 #${S.curUserId}에게 힌트쿠폰 ${delta > 0 ? '+' : ''}${delta}개를 ${delta > 0 ? '지급' : '회수'}할까요?\n사유: ${note}`)) return;
    try {
      const r = await api(`/api/admin/mfa/users/${S.curUserId}/coupons`, { method: 'POST', body: JSON.stringify({ delta, note }) });
      if (r.success) {
        toast(`반영됐어요 · 잔액 ${num(r.balance)}개`, 'ok');
        openUser(S.curUserId);
        loadUsers();
      } else {
        toast(r.error || '처리하지 못했어요', 'bad');
      }
    } catch (e) {
      toast('요청에 실패했어요', 'bad');
    }
  }

  // ───────────────────────── 결제 ─────────────────────────
  function buildPurchasesPane() {
    $('#mfa-pane-purchases').innerHTML =
      `<div id="mfaPurchaseKpis"></div>` +
      `<div class="mfa-bar">` +
      `<input class="mfa-input search" id="mfaPurQ" placeholder="닉네임 · 이메일 검색" data-enter="purchases-search">` +
      `<select class="mfa-select" id="mfaPurStatus" data-change="purchases-search"><option value="all">검증 전체</option><option value="verified">검증됨</option><option value="failed">실패</option></select>` +
      `<select class="mfa-select" id="mfaPurKind" data-change="purchases-search"><option value="">종류 전체</option><option value="hint_coupons">힌트쿠폰</option><option value="remove_ads">광고 제거</option></select>` +
      `<select class="mfa-select" id="mfaPurPlatform" data-change="purchases-search"><option value="">플랫폼 전체</option><option value="ios">iOS</option><option value="android">Android</option></select>` +
      `<input class="mfa-input" id="mfaPurFrom" type="date" data-change="purchases-search" title="시작일"><span class="mfa-note">~</span><input class="mfa-input" id="mfaPurTo" type="date" data-change="purchases-search" title="종료일">` +
      `<button class="mfa-btn primary" data-act="purchases-search">검색</button>` +
      `<span class="grow"></span><button class="mfa-btn" data-act="purchases-csv">CSV 내보내기</button></div>` +
      `<div id="mfaPurchasesBody">${skeleton(1)}</div><div id="mfaPurchasesPager" class="mfa-pager"></div>`;
  }

  const purchaseFilters = () => ({
    q: val('#mfaPurQ'),
    status: val('#mfaPurStatus'),
    kind: val('#mfaPurKind'),
    platform: val('#mfaPurPlatform'),
    from: val('#mfaPurFrom'),
    to: val('#mfaPurTo'),
  });

  async function loadPurchases() {
    const body = $('#mfaPurchasesBody');
    try {
      const d = await get('purchases', { ...purchaseFilters(), page: S.purchases.page, limit: 30 });
      if (failed(d)) throw new Error('load');
      const s = d.summary;
      $('#mfaPurchaseKpis').innerHTML = `<div class="mfa-kpis">${[
        kpi('전체 결제', num(s.total), '시도 포함'),
        kpi('검증 완료', num(s.verified), `최근 30일 ${num(s.verified_30d)}`, 'ok'),
        kpi('검증 실패', num(s.failed), s.total ? `실패율 ${pctTxt(pct(s.failed, s.total))}` : '', s.failed ? 'warn' : ''),
        kpi('힌트쿠폰', num(s.hint_coupons), '검증 완료'),
        kpi('광고 제거', num(s.remove_ads), '검증 완료'),
      ].join('')}</div>`;
      if (!d.purchases.length) {
        body.innerHTML = empty('조건에 맞는 결제 내역이 없어요.');
        $('#mfaPurchasesPager').innerHTML = '';
        return;
      }
      body.innerHTML = `<div class="mfa-table-wrap"><table class="mfa-table"><thead><tr><th>ID</th><th>유저</th><th>플랫폼</th><th>상품</th><th>종류</th><th>검증</th><th>환경</th><th>일시</th></tr></thead><tbody>${d.purchases
        .map((p) => `<tr class="${p.user_id ? 'click' : ''}" ${p.user_id ? `data-act="user-open" data-id="${p.user_id}"` : ''}><td class="muted">${p.id}</td><td>${p.user_id ? `<b>${esc(p.nickname || '-')}</b> <span class="muted">#${p.user_id}</span>` : '<span class="muted">(탈퇴)</span>'}</td><td><span class="mfa-badge">${esc(p.platform)}</span></td><td>${esc(p.product_id)}</td><td>${esc(p.kind || '-')}</td><td>${p.verified ? '<span class="mfa-badge ok">검증됨</span>' : `<span class="mfa-badge bad">${esc(p.status || 'failed')}</span>`}</td><td class="muted">${esc(p.environment || '-')}</td><td class="muted">${fdt(p.created_at)}</td></tr>`)
        .join('')}</tbody></table></div>`;
      pager('#mfaPurchasesPager', d, 'purchases-page');
    } catch (e) {
      body.innerHTML = empty('결제 내역을 불러오지 못했어요.', 'purchases-search');
    }
  }

  async function exportPurchasesCsv() {
    toast('CSV를 만드는 중이에요…');
    try {
      const rows = [];
      for (let page = 1; page <= 25; page++) {
        const d = await get('purchases', { ...purchaseFilters(), page, limit: 200 });
        if (failed(d)) throw new Error('load');
        rows.push(...d.purchases);
        if (page >= d.totalPages) break;
      }
      const cell = (v) => `"${String(v == null ? '' : v).replace(/"/g, '""')}"`;
      const head = ['ID', '유저ID', '닉네임', '이메일', '플랫폼', '상품', '종류', '검증', '상태', '환경', '일시'];
      const lines = [head.map(cell).join(',')].concat(
        rows.map((p) => [p.id, p.user_id, p.nickname, p.email, p.platform, p.product_id, p.kind, p.verified ? 'Y' : 'N', p.status, p.environment, fdt(p.created_at)].map(cell).join(','))
      );
      const blob = new Blob(['﻿' + lines.join('\n')], { type: 'text/csv;charset=utf-8' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `mfa-purchases-${new Date().toISOString().slice(0, 10)}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      toast(`${num(rows.length)}건을 내보냈어요`, 'ok');
    } catch (e) {
      toast('내보내기에 실패했어요', 'bad');
    }
  }

  // ───────────────────────── 문의 ─────────────────────────
  const TEMPLATES = [
    ['감사', '문의해 주셔서 감사해요. '],
    ['확인 중', '말씀해 주신 내용을 확인하고 있어요. 확인되는 대로 다시 안내드릴게요. '],
    ['업데이트 안내', '최신 버전으로 업데이트하신 뒤에도 같은 문제가 있다면 다시 알려 주세요. '],
    ['쿠폰 보상', '불편을 드려 죄송해요. 보상으로 힌트쿠폰을 지급해 드렸어요. '],
    ['재현 요청', '기기 모델과 OS 버전, 문제가 생기는 순서를 알려 주시면 확인에 큰 도움이 돼요. '],
  ];

  function buildInquiriesPane() {
    $('#mfa-pane-inquiries').innerHTML =
      `<div class="mfa-bar" id="mfaInqFilters"></div>` +
      `<div class="mfa-bar"><input class="mfa-input search" id="mfaInqQ" placeholder="닉네임 · 내용 · 기기 ID 검색" data-enter="inq-search"><button class="mfa-btn primary" data-act="inq-search">검색</button></div>` +
      `<div id="mfaInqBody">${skeleton(1)}</div>`;
  }

  function renderInqFilters() {
    const c = S.inqCounts || { total: 0, pending: 0, replied: 0 };
    $('#mfaInqFilters').innerHTML = seg('inq-filter', S.inqStatus, [['all', `전체 ${c.total}`], ['pending', `대기중 ${c.pending}`], ['replied', `답변완료 ${c.replied}`]]);
  }

  function setInqBadge(n) {
    pendingInquiries = n;
    applySidebarBadge();
    const b = document.getElementById('mfaInqBadge');
    if (!b) return;
    b.textContent = n;
    b.style.display = n ? 'inline-block' : 'none';
  }

  // 사이드바의 '성인의 수학' 항목에도 대기 문의 수를 보여준다(화면에 들어가기 전에도 보이게).
  let pendingInquiries = 0;
  function applySidebarBadge() {
    const item = document.querySelector('#sidebar .side-item[data-side="mfa"]');
    if (!item) return;
    let b = item.querySelector('.side-badge');
    if (!pendingInquiries) {
      if (b) b.remove();
      return;
    }
    if (!b) {
      b = document.createElement('span');
      b.className = 'side-badge';
      item.appendChild(b);
    }
    b.textContent = pendingInquiries > 99 ? '99+' : pendingInquiries;
  }
  window.mfaApplySidebarBadge = applySidebarBadge;
  window.mfaLoadSidebarBadge = refreshInquiryBadge;

  async function refreshInquiryBadge() {
    try {
      const d = await get('inquiries', { status: 'pending' });
      if (!failed(d)) setInqBadge(d.pendingCount || 0);
    } catch (e) { /* 배지 갱신 실패는 무시 */ }
  }

  async function loadInquiries() {
    const body = $('#mfaInqBody');
    try {
      const d = await get('inquiries', { status: S.inqStatus, q: val('#mfaInqQ') });
      if (failed(d)) throw new Error('load');
      S.inquiries = d.inquiries;
      S.inqCounts = d.counts;
      setInqBadge(d.pendingCount || 0);
      renderInqFilters();
      if (!d.inquiries.length) {
        body.innerHTML = empty('문의가 없어요.');
        return;
      }
      body.innerHTML = `<div class="mfa-table-wrap"><table class="mfa-table"><thead><tr><th>ID</th><th>닉네임</th><th>내용</th><th>플랫폼</th><th>상태</th><th>등록</th></tr></thead><tbody>${d.inquiries
        .map((i) => {
          const waitMs = Date.now() - new Date(i.created_at).getTime();
          const late = i.status === 'pending' && waitMs > 2 * 86400000;
          return `<tr class="click ${late ? 'hot' : ''}" data-act="inq-open" data-id="${i.id}"><td class="muted">${i.id}</td><td><b>${esc(i.nickname || '익명')}</b></td><td>${esc((i.content || '').slice(0, 60))}${(i.content || '').length > 60 ? '…' : ''}</td><td>${i.device_platform ? `<span class="mfa-badge">${esc(i.device_platform)}</span>` : '<span class="muted">-</span>'}</td><td>${i.status === 'replied' ? '<span class="mfa-badge ok">답변완료</span>' : '<span class="mfa-badge warn">대기중</span>'}${late ? ' <span class="mfa-badge bad">2일↑</span>' : ''}</td><td class="muted">${fdt(i.created_at)} <span class="hint">${ago(i.created_at)}</span></td></tr>`;
        })
        .join('')}</tbody></table></div>`;
    } catch (e) {
      body.innerHTML = empty('문의를 불러오지 못했어요.', 'inq-search');
    }
  }

  function openInquiry(id) {
    const i = S.inquiries.find((x) => String(x.id) === String(id));
    if (!i) return;
    S.curInq = i;
    const m = ensureModal('mfaInqModal', `문의 #${i.id}`, 'max-width:680px');
    const replied = i.status === 'replied';
    const dev = i.device_platform
      ? `${esc(i.device_platform)} · 첫 실행 ${fd(i.device_first_seen)} · 최근 ${fdt(i.device_last_seen)} · 실행 ${num(i.device_launch_count)}회`
      : '<span class="hint">기기 정보 없음</span>';
    m.querySelector('.content').innerHTML =
      `<div class="body">` +
      `<div class="sec"><div class="kv"><div>닉네임</div><div><b>${esc(i.nickname || '익명')}</b></div><div>기기</div><div>${dev}</div><div>기기 ID</div><div class="hint" style="word-break:break-all">${esc(i.device_id || '')}</div><div>등록</div><div>${fdt(i.created_at)} <span class="hint">${ago(i.created_at)}</span></div></div></div>` +
      `<div class="sec"><h4>문의 내용</h4><div class="msg">${esc(i.content || '')}</div></div>` +
      (replied
        ? `<div class="sec"><h4>보낸 답변 <span class="hint">${fdt(i.replied_at)}${i.is_read ? ' · 사용자가 읽음' : ' · 아직 안 읽음'}</span></h4><div class="msg">${esc(i.reply || '')}</div></div>`
        : `<div class="sec"><h4>답변 작성</h4><div class="chips">${TEMPLATES.map((t, n) => `<button class="chip" data-m="inq-tpl" data-v="${n}">${esc(t[0])}</button>`).join('')}</div><textarea class="mfa-textarea" id="mfaReplyText" placeholder="답변을 입력하세요 (Ctrl+Enter로 전송)"></textarea><div class="hint" id="mfaReplyCount" style="text-align:right">0자</div></div>`) +
      `</div><div class="foot"><button class="mfa-btn danger" data-m="inq-del">삭제</button>${replied ? '' : '<button class="mfa-btn primary" data-m="inq-send">답변 전송</button>'}</div>`;
    const ta = document.getElementById('mfaReplyText');
    if (ta) {
      ta.addEventListener('input', () => (document.getElementById('mfaReplyCount').textContent = ta.value.length + '자'));
      ta.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) sendReply();
      });
    }
    m.classList.add('show');
    if (ta) ta.focus();
  }

  async function sendReply() {
    const i = S.curInq;
    const reply = (document.getElementById('mfaReplyText') || {}).value;
    if (!i || !reply || !reply.trim()) return toast('답변 내용을 입력하세요', 'bad');
    try {
      const r = await api(`/api/admin/mfa/inquiries/${i.id}/reply`, { method: 'PUT', body: JSON.stringify({ reply: reply.trim() }) });
      if (r.success) {
        toast('답변을 보냈어요', 'ok');
        document.getElementById('mfaInqModal').classList.remove('show');
        loadInquiries();
      } else {
        toast(r.error || '답변을 보내지 못했어요', 'bad');
      }
    } catch (e) {
      toast('요청에 실패했어요', 'bad');
    }
  }

  async function deleteInquiry() {
    const i = S.curInq;
    if (!i || !confirm(`문의 #${i.id}를 삭제할까요? 되돌릴 수 없어요.`)) return;
    try {
      await api(`/api/admin/mfa/inquiries/${i.id}`, { method: 'DELETE' });
      toast('삭제했어요', 'ok');
      document.getElementById('mfaInqModal').classList.remove('show');
      loadInquiries();
    } catch (e) {
      toast('삭제하지 못했어요', 'bad');
    }
  }

  // ───────────────────────── 액션 표 ─────────────────────────
  const ACTIONS = {
    tab: (t) => showTab(t.dataset.v),
    'stats-days': (t) => { S.days = +t.dataset.v; loadStats(); },
    'stats-reload': () => loadStats(),
    'games-days': (t) => { S.skDays = +t.dataset.v; loadGames(); },
    'games-reload': () => loadGames(),
    'users-search': () => { S.users.page = 1; loadUsers(); },
    'users-page': (t) => { S.users.page = Math.max(1, S.users.page + +t.dataset.v); loadUsers(); },
    'user-open': (t) => openUser(t.dataset.id),
    'purchases-search': () => { S.purchases.page = 1; loadPurchases(); },
    'purchases-page': (t) => { S.purchases.page = Math.max(1, S.purchases.page + +t.dataset.v); loadPurchases(); },
    'purchases-csv': () => exportPurchasesCsv(),
    'inq-filter': (t) => { S.inqStatus = t.dataset.v; loadInquiries(); },
    'inq-search': () => loadInquiries(),
    'inq-open': (t) => openInquiry(t.dataset.id),
  };

  const MODAL_ACTIONS = {
    'adj-amt': (t) => { document.getElementById('mfaAdjAmt').value = t.dataset.v; },
    'adj-plus': () => adjustCoupons(1),
    'adj-minus': () => adjustCoupons(-1),
    'inq-tpl': (t) => {
      const ta = document.getElementById('mfaReplyText');
      ta.value += TEMPLATES[+t.dataset.v][1];
      ta.dispatchEvent(new Event('input'));
      ta.focus();
    },
    'inq-send': () => sendReply(),
    'inq-del': () => deleteInquiry(),
  };
})();
