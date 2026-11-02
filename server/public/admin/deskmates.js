/* [MACPET] Deskmates(MacPet) 관리자 화면 — 현황 · 그룹 · 사용자. 삭제·리팩터링 금지 (리포 루트 CLAUDE.md).
   index.html 은 #dmDashboard 껍데기와 이 파일 로드만 맡는다. 데이터는 /api/admin/macpet/* (admin.ts 프록시) → Deskmates 서버의 내부 관리 포트.
   채팅·쪽지는 Deskmates 서버가 내주지 않아서 여기에서도 볼 수 없다. 전역에는 dmEnter 하나만 노출한다. */
(function () {
  'use strict';

  const S = { built: false, tab: 'stats', timer: null, groupQ: '', userQ: '' };
  const TABS = [['stats', '현황'], ['groups', '그룹'], ['users', '사용자']];
  const PROVIDER = { apple: 'Apple', google: 'Google', dev: '개발용' };

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (n) => (Number(n) || 0).toLocaleString('ko-KR');
  const pad = (n) => String(n).padStart(2, '0');
  const fd = (t) => { if (!t) return '-'; const d = new Date(t); return `${d.getFullYear()}.${pad(d.getMonth() + 1)}.${pad(d.getDate())}`; };
  const root = () => document.getElementById('dmDashboard');
  const $ = (sel) => root().querySelector(sel);
  const failed = (r) => !r || r.error;

  // `api` 는 index.html 의 공용 함수 (관리자 토큰을 붙이고, 만료되면 로그인 화면으로 보낸다)
  const get = (path) => api('/api/admin/macpet/' + path);
  const send = (method, path, body) => api('/api/admin/macpet/' + path, { method, body: body === undefined ? undefined : JSON.stringify(body) });

  function toast(msg, bad) {
    let c = document.getElementById('dmToasts');
    if (!c) { c = document.createElement('div'); c.id = 'dmToasts'; document.body.appendChild(c); }
    const t = document.createElement('div');
    t.className = 'dm-toast' + (bad ? ' bad' : '');
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => t.remove(), 3500);
  }
  const errText = (r) => (r && r.error) || '불러오지 못했어요';
  const empty = (msg, retry) => `<div class="dm-empty">${esc(msg)}${retry ? `<br><button class="dm-btn" data-act="${retry}" style="margin-top:12px">다시 시도</button>` : ''}</div>`;
  const kpi = (label, value, sub) => `<div class="dm-kpi"><div class="label">${esc(label)}</div><div class="value">${value}</div><div class="sub">${sub || ''}</div></div>`;
  const badge = (t, cls) => `<span class="dm-badge ${cls || ''}">${esc(t)}</span>`;
  const providerBadge = (p) => badge(PROVIDER[p] || p, p);
  const onlineDot = (on) => `<span class="dm-dot ${on ? 'on' : ''}" title="${on ? '접속 중' : '오프라인'}"></span>`;

  // ───────────── 뼈대 ─────────────
  function build() {
    if (S.built) return;
    S.built = true;
    root().innerHTML =
      `<div class="dm-tabs">${TABS.map(([k, l]) => `<button class="dm-tab" data-act="tab" data-v="${k}" data-tab="${k}">${l}</button>`).join('')}</div>` +
      `<section class="dm-pane" id="dm-pane-stats"></section>` +
      `<section class="dm-pane" id="dm-pane-groups">` +
        `<div class="dm-bar"><input class="dm-input" id="dmGroupQ" placeholder="그룹 이름 · 초대 코드 검색" data-enter="groups-search"><button class="dm-btn primary" data-act="groups-search">검색</button><span class="grow"></span><button class="dm-btn" data-act="groups-reload">새로고침</button></div>` +
        `<div id="dmGroups"></div></section>` +
      `<section class="dm-pane" id="dm-pane-users">` +
        `<div class="dm-bar"><input class="dm-input" id="dmUserQ" placeholder="닉네임 · 로그인 ID 검색" data-enter="users-search"><button class="dm-btn primary" data-act="users-search">검색</button><span class="grow"></span><button class="dm-btn" data-act="users-reload">새로고침</button></div>` +
        `<div id="dmUsers"></div></section>`;
    root().addEventListener('click', (e) => { const t = e.target.closest('[data-act]'); if (t && ACTIONS[t.dataset.act]) ACTIONS[t.dataset.act](t); });
    root().addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      const t = e.target.closest('[data-enter]');
      if (t && ACTIONS[t.dataset.enter]) ACTIONS[t.dataset.enter](t);
    });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(); });
  }

  function showTab(name) {
    S.tab = name;
    try { sessionStorage.setItem('dmTab', name); } catch (_) { /* 저장소가 막혀도 무시 */ }
    root().querySelectorAll('.dm-tab').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
    root().querySelectorAll('.dm-pane').forEach((p) => p.classList.toggle('active', p.id === 'dm-pane-' + name));
    if (name === 'stats') loadStats();
    else if (name === 'groups') loadGroups();
    else loadUsers();
  }

  window.dmEnter = function () {
    build();
    let tab = 'stats';
    try { tab = sessionStorage.getItem('dmTab') || 'stats'; } catch (_) { /* 무시 */ }
    showTab(TABS.some(([k]) => k === tab) ? tab : 'stats');
    // 현황은 접속 중인 사람 수가 바뀌니 화면에 있는 동안 30초마다 새로 고친다
    clearInterval(S.timer);
    S.timer = setInterval(() => {
      if (root().style.display === 'none') { clearInterval(S.timer); return; }
      if (S.tab === 'stats') loadStats(true);
    }, 30000);
  };

  // ───────────── 현황 ─────────────
  async function loadStats(silent) {
    const el = $('#dm-pane-stats');
    if (!silent) el.innerHTML = '<div class="dm-kpis">' + '<div class="dm-skel"></div>'.repeat(6) + '</div>';
    let r;
    try { r = await get('stats'); } catch (_) { return; }
    if (failed(r)) { el.innerHTML = empty(errText(r), 'stats-reload'); return; }
    const prov = Object.entries(r.providers || {}).map(([k, v]) => `${esc(PROVIDER[k] || k)} ${num(v)}`).join(' · ') || '-';
    el.innerHTML =
      `<div class="dm-bar"><span class="dm-note">친구들이 접속해 있는 동안 30초마다 자동으로 새로 고쳐요</span><span class="grow"></span><button class="dm-btn" data-act="stats-reload">새로고침</button></div>` +
      `<div class="dm-kpis">` +
        kpi('가입자', num(r.users), `로그인: ${prov}`) +
        kpi('그룹', num(r.groups), `그룹당 최대 ${num(r.limits && r.limits.maxMembers)}명`) +
        kpi('지금 접속 중', `<span class="dm-live">${num(r.online)}</span>`, `접속 중인 그룹 ${num(r.onlineGroups)}개`) +
        kpi('오늘 가입', num(r.newUsers24h), '최근 24시간') +
        kpi('이번 주 가입', num(r.newUsers7d), '최근 7일') +
        kpi('이번 주 새 그룹', num(r.newGroups7d), '최근 7일') +
      `</div>` +
      `<p class="dm-note" style="margin-top:18px">닉네임, 로그인 종류, 가입일, 그룹 소속, 접속 여부만 볼 수 있어요. 채팅과 쪽지는 서버가 관리자에게도 내주지 않아요.</p>`;
  }

  // ───────────── 그룹 ─────────────
  async function loadGroups() {
    const el = $('#dmGroups');
    el.innerHTML = '<div class="dm-empty">불러오는 중…</div>';
    const q = S.groupQ ? '?q=' + encodeURIComponent(S.groupQ) : '';
    let r;
    try { r = await get('groups' + q); } catch (_) { return; }
    if (failed(r)) { el.innerHTML = empty(errText(r), 'groups-reload'); return; }
    if (!r.groups.length) { el.innerHTML = empty(S.groupQ ? '검색 결과가 없어요' : '아직 그룹이 없어요'); return; }
    el.innerHTML = `<div class="dm-table-wrap"><table class="dm-table"><thead><tr><th>이름</th><th>초대 코드</th><th>그룹장</th><th class="num">인원</th><th>접속</th><th>만든 날</th></tr></thead><tbody>` +
      r.groups.map((g) => `<tr class="click" data-act="group-open" data-code="${esc(g.code)}"><td><b>${esc(g.name)}</b></td><td class="mono">${esc(g.code)}</td><td>${esc(g.ownerName || '-')}</td><td class="num">${num(g.members)}</td><td>${onlineDot(g.online > 0)} ${num(g.online)}명</td><td class="muted">${fd(g.createdAt)}</td></tr>`).join('') +
      `</tbody></table></div><p class="dm-note" style="margin-top:10px">${num(r.groups.length)}개 (최근 300개까지) · 행을 누르면 멤버와 삭제 버튼이 나와요</p>`;
  }

  async function openGroup(code) {
    let r;
    try { r = await get('groups/' + encodeURIComponent(code)); } catch (_) { return; }
    if (failed(r)) { toast(errText(r), true); return; }
    const g = r.group;
    modal(
      `<h3>${esc(g.name)} <span class="mono muted">${esc(g.code)}</span></h3>` +
      `<p class="dm-note">만든 날 ${fd(g.createdAt)} · ${num(g.members)}명 · 접속 중 ${num(g.online)}명</p>` +
      `<table class="dm-table"><thead><tr><th>닉네임</th><th>로그인</th><th>접속</th><th>가입일</th><th></th></tr></thead><tbody>` +
      r.members.map((m) => `<tr><td><b>${esc(m.name)}</b> ${m.owner ? badge('그룹장', 'brand') : ''}</td><td>${providerBadge(m.provider)}</td><td>${onlineDot(m.online)}</td><td class="muted">${fd(m.createdAt)}</td>` +
        `<td class="right"><button class="dm-btn small" data-act="kick" data-code="${esc(g.code)}" data-id="${esc(m.id)}" data-name="${esc(m.name)}">내보내기</button></td></tr>`).join('') +
      `</tbody></table>` +
      `<div class="dm-actions"><button class="dm-btn danger" data-act="group-delete" data-code="${esc(g.code)}" data-name="${esc(g.name)}" data-n="${g.members}">그룹 삭제</button><span class="grow"></span><button class="dm-btn" data-act="modal-close">닫기</button></div>`);
  }

  // ───────────── 사용자 ─────────────
  async function loadUsers() {
    const el = $('#dmUsers');
    el.innerHTML = '<div class="dm-empty">불러오는 중…</div>';
    const q = S.userQ ? '?q=' + encodeURIComponent(S.userQ) : '';
    let r;
    try { r = await get('users' + q); } catch (_) { return; }
    if (failed(r)) { el.innerHTML = empty(errText(r), 'users-reload'); return; }
    if (!r.users.length) { el.innerHTML = empty(S.userQ ? '검색 결과가 없어요' : '아직 가입자가 없어요'); return; }
    el.innerHTML = `<div class="dm-table-wrap"><table class="dm-table"><thead><tr><th>닉네임</th><th>로그인</th><th>그룹</th><th>접속</th><th>가입일</th><th></th></tr></thead><tbody>` +
      r.users.map((u) => `<tr><td><b>${esc(u.name)}</b><div class="muted mono small">${esc(u.id.length > 28 ? u.id.slice(0, 28) + '…' : u.id)}</div></td><td>${providerBadge(u.provider)}</td>` +
        `<td>${u.groups.length ? u.groups.map((g) => `<span class="dm-chip" data-act="group-open" data-code="${esc(g.code)}">${esc(g.name)}${g.owner ? ' ★' : ''}</span>`).join(' ') : '<span class="muted">-</span>'}</td>` +
        `<td>${onlineDot(u.online)}</td><td class="muted">${fd(u.createdAt)}</td>` +
        `<td class="right"><button class="dm-btn small danger" data-act="user-delete" data-id="${esc(u.id)}" data-name="${esc(u.name)}">계정 삭제</button></td></tr>`).join('') +
      `</tbody></table></div><p class="dm-note" style="margin-top:10px">${num(r.users.length)}명 (최근 가입 300명까지) · ★ 는 그룹장</p>`;
  }

  // ───────────── 모달 ─────────────
  function modal(html) {
    closeModal();
    const m = document.createElement('div');
    m.className = 'dm-modal';
    m.innerHTML = `<div class="box">${html}</div>`;
    m.addEventListener('click', (e) => {
      if (e.target === m) { closeModal(); return; }
      const t = e.target.closest('[data-act]');
      if (t && ACTIONS[t.dataset.act]) ACTIONS[t.dataset.act](t);
    });
    document.body.appendChild(m);
  }
  function closeModal() { document.querySelectorAll('.dm-modal').forEach((m) => m.remove()); }

  // ───────────── 동작 ─────────────
  const ACTIONS = {
    tab: (t) => showTab(t.dataset.v),
    'stats-reload': () => loadStats(),
    'groups-search': () => { S.groupQ = ($('#dmGroupQ').value || '').trim(); loadGroups(); },
    'groups-reload': () => loadGroups(),
    'users-search': () => { S.userQ = ($('#dmUserQ').value || '').trim(); loadUsers(); },
    'users-reload': () => loadUsers(),
    'group-open': (t) => openGroup(t.dataset.code),
    'modal-close': closeModal,
    'group-delete': async (t) => {
      const { code, name, n } = t.dataset;
      if (!confirm(`그룹 "${name}" (${n}명)을 삭제할까요?\n\n멤버 모두 이 그룹에서 나가게 되고, 전달 안 된 쪽지도 사라져요. 되돌릴 수 없어요.`)) return;
      const r = await send('DELETE', 'groups/' + encodeURIComponent(code));
      if (failed(r)) { toast(errText(r), true); return; }
      toast(`그룹 "${name}"을 삭제했어요`);
      closeModal();
      if (S.tab === 'groups') loadGroups(); else if (S.tab === 'users') loadUsers(); else loadStats();
    },
    kick: async (t) => {
      const { code, id, name } = t.dataset;
      if (!confirm(`"${name}"님을 이 그룹에서 내보낼까요?\n\n본인은 다시 초대 코드로 들어올 수 있어요.`)) return;
      const r = await send('POST', `groups/${encodeURIComponent(code)}/kick`, { userId: id });
      if (failed(r)) { toast(errText(r), true); return; }
      toast(`"${name}"님을 내보냈어요`);
      openGroup(code);
    },
    'user-delete': async (t) => {
      const { id, name } = t.dataset;
      if (!confirm(`"${name}"님의 계정을 삭제할까요?\n\n프로필과 그룹 참여 정보, 전달 안 된 쪽지가 지워지고 되돌릴 수 없어요. 혼자 남은 그룹은 같이 지워져요.`)) return;
      const r = await send('DELETE', 'users/' + encodeURIComponent(id));
      if (failed(r)) { toast(errText(r), true); return; }
      toast(`"${name}"님의 계정을 삭제했어요`);
      loadUsers();
    },
  };
})();
