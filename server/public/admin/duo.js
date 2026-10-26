/* 듀오 아레나 관리자 — 운영 개요(실시간·추이·시간대·경제·CS)와 매칭 봇 설정.
   index.html 의 전역 api / escapeHtml 을 쓴다. 전역은 duoOverviewLoad, botLoad, botSave, shopLoad 만 노출. 상점 패널은 #shopPanel(클릭·변경은 data-* 위임). */
(function () {
  const GAME_LABELS = {
    tictactoe: '틱택토', infinite_tictactoe: '무한 틱택토', gomoku: '오목', reaction: '반응속도', rps: '가위바위보',
    speedtap: '스피드탭', sequence: '시퀀스', stroop: '스트룹', hexagon: '헥사곤', pyramid: '수식피라미드',
    hunmin: '훈민정음', numberbattle: '숫자배틀', cardflip: '카드뒤집기', mathrace: '사칙연산', arrowdash: '방향맞추기',
    timing: '타이밍', set: '세트',
  };
  const label = (g) => GAME_LABELS[g] || g;
  const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(String(s)) : String(s));
  const fmt = (n) => Number(n || 0).toLocaleString();

  // 막대+선 추이 차트(SVG). series: [{name,color,values}] — 첫 시리즈는 막대, 나머지는 선.
  function trendChart(days, series) {
    const W = 560, H = 190, L = 34, B = 24, T = 10, R = 8;
    const n = days.length;
    const max = Math.max(1, ...series.flatMap((s) => s.values));
    const x = (i) => L + ((W - L - R) / n) * (i + 0.5);
    const y = (v) => T + (H - T - B) * (1 - v / max);
    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img">`;
    for (let g = 0; g <= 4; g++) {
      const gy = T + ((H - T - B) * g) / 4;
      svg += `<line x1="${L}" x2="${W - R}" y1="${gy}" y2="${gy}" stroke="rgba(0,0,0,.07)"/>`;
      svg += `<text x="${L - 6}" y="${gy + 4}" font-size="10" fill="#aaa" text-anchor="end">${Math.round(max * (1 - g / 4))}</text>`;
    }
    const bw = Math.max(6, ((W - L - R) / n) * 0.55);
    series[0].values.forEach((v, i) => {
      svg += `<rect x="${x(i) - bw / 2}" y="${y(v)}" width="${bw}" height="${H - B - y(v)}" rx="4" fill="${series[0].color}" opacity=".85"><title>${days[i]} ${series[0].name} ${v}</title></rect>`;
    });
    series.slice(1).forEach((s) => {
      const pts = s.values.map((v, i) => `${x(i)},${y(v)}`).join(' ');
      svg += `<polyline points="${pts}" fill="none" stroke="${s.color}" stroke-width="2.5" stroke-linejoin="round"/>`;
      s.values.forEach((v, i) => { svg += `<circle cx="${x(i)}" cy="${y(v)}" r="3" fill="${s.color}"><title>${days[i]} ${s.name} ${v}</title></circle>`; });
    });
    days.forEach((d, i) => {
      if (i % 2 === 0 || n <= 8) svg += `<text x="${x(i)}" y="${H - 7}" font-size="10" fill="#aaa" text-anchor="middle">${d.slice(5)}</text>`;
    });
    return svg + '</svg>';
  }

  function hoursChart(hours) {
    const W = 560, H = 150, L = 8, B = 22, T = 8, R = 8;
    const byHour = Array.from({ length: 24 }, (_, h) => (hours.find((x) => x.hour === h) || { games: 0 }).games);
    const max = Math.max(1, ...byHour);
    const bw = (W - L - R) / 24;
    let svg = `<svg viewBox="0 0 ${W} ${H}" role="img">`;
    byHour.forEach((v, h) => {
      const bh = ((H - T - B) * v) / max;
      const hot = v === max && v > 0;
      svg += `<rect x="${L + h * bw + 2}" y="${H - B - bh}" width="${bw - 4}" height="${bh}" rx="3" fill="${hot ? '#ff8fb1' : '#a99dff'}"><title>${h}시 ${v}판</title></rect>`;
      if (h % 3 === 0) svg += `<text x="${L + h * bw + bw / 2}" y="${H - 6}" font-size="10" fill="#aaa" text-anchor="middle">${h}</text>`;
    });
    return svg + '</svg>';
  }

  async function duoOverviewLoad() {
    const liveEl = document.getElementById('duoLive');
    const ovEl = document.getElementById('duoOverview');
    if (!liveEl || !ovEl) return;
    try {
      const d = await api('/api/admin/duo/overview');
      const l = d.live;
      const queueText = l.queues.length ? l.queues.map((q) => `${label(q.key.split('_')[0])} ${q.waiting}`).join(' · ') : '대기열 없음';
      liveEl.innerHTML = `
        <div class="stat-card success"><h3><span class="live-dot"></span>지금 접속</h3><div class="number">${fmt(l.onlineUsers)}</div><div class="sub">로비·게임 중 유저</div></div>
        <div class="stat-card accent"><h3>진행 중인 대전</h3><div class="number">${fmt(l.playingRooms)}</div><div class="sub">봇 대전 ${l.botRooms}</div></div>
        <div class="stat-card"><h3>매칭 대기</h3><div class="number">${fmt(l.queues.reduce((a, q) => a + q.waiting, 0) + l.rankedWaiting)}</div><div class="sub">${esc(queueText)}${l.rankedWaiting ? ` · 랭크 ${l.rankedWaiting}` : ''}</div></div>
        <div class="stat-card ${d.cs.pending > 0 ? 'warn' : ''}"><h3>미답변 문의</h3><div class="number">${d.cs.pending}</div><div class="sub">${d.cs.pending ? `가장 오래된 건 ${d.cs.oldestHours}시간 경과` : '모두 처리됨'}</div></div>
        <div class="stat-card"><h3>D1 리텐션</h3><div class="number">${d.retentionD1 ? d.retentionD1.rate + '%' : '-'}</div><div class="sub">${d.retentionD1 ? `어제 가입 ${d.retentionD1.cohort}명 중 ${d.retentionD1.returned}명 복귀` : '어제 가입자 없음'}</div></div>
        <div class="stat-card"><h3>오늘 코인 경제</h3><div class="number">${fmt(d.economy.issued)}</div><div class="sub">소비 ${fmt(d.economy.spent)} · 순증 ${fmt(d.economy.issued - d.economy.spent)}</div></div>
        <div class="stat-card ${d.bannedUsers ? 'warn' : ''}"><h3>제재 중 유저</h3><div class="number">${d.bannedUsers}</div></div>`;

      const days = d.trend.map((t) => String(t.day).slice(0, 10));
      const gamesMax = Math.max(1, ...d.games7d.map((g) => g.games));
      ovEl.innerHTML = `
        <div class="duo-row">
          <div class="chart-container">
            <h3>최근 14일 추이</h3>
            <div class="duo-legend"><span><i style="background:#a99dff"></i>대전 수</span><span><i style="background:#34b27f"></i>활성 유저</span><span><i style="background:#ff8fb1"></i>신규 가입</span></div>
            ${trendChart(days, [
              { name: '대전', color: '#a99dff', values: d.trend.map((t) => t.games) },
              { name: '활성 유저', color: '#34b27f', values: d.trend.map((t) => t.activeUsers) },
              { name: '신규 가입', color: '#ff8fb1', values: d.trend.map((t) => t.newUsers) },
            ])}
          </div>
          <div class="chart-container">
            <h3>시간대별 대전 (최근 7일, KST)</h3>
            ${hoursChart(d.hours)}
            <div class="duo-note">분홍 막대가 피크 시간대예요. 공지·이벤트·점검은 이 시간을 피하면 좋아요.</div>
          </div>
        </div>
        <div class="duo-row">
          <div class="chart-container">
            <h3>게임별 이용 (최근 7일, 봇 제외)</h3>
            <div class="bar-chart">${d.games7d.length ? d.games7d.map((g) => `
              <div class="bar-row"><span class="bar-label">${esc(label(g.gameType))}</span>
              <div class="bar-track"><div class="bar-fill" style="width:${(g.games / gamesMax) * 100}%"></div></div>
              <span class="bar-count" title="${g.players}명">${fmt(g.games)}</span></div>`).join('') : '<div class="empty" style="padding:20px">데이터 없음</div>'}</div>
          </div>
          <div class="chart-container">
            <h3>이번 주 열혈 유저 TOP 5</h3>
            <table class="duo-mini-table"><thead><tr><th>#</th><th>닉네임</th><th>대전</th></tr></thead><tbody>
              ${d.topUsers.length ? d.topUsers.map((u, i) => `<tr style="cursor:pointer" onclick="openUserDetail(${u.id})"><td>${i + 1}</td><td>${esc(u.nickname)}</td><td>${fmt(u.games)}</td></tr>`).join('') : '<tr><td colspan="3" class="empty">데이터 없음</td></tr>'}
            </tbody></table>
            <div class="duo-note">행을 누르면 유저 상세(코인·제재·닉네임)로 이동해요.</div>
          </div>
        </div>`;
    } catch (e) {
      console.error('duo overview failed', e);
      liveEl.innerHTML = '<div class="empty">운영 개요를 불러오지 못했어요.</div>';
    }
  }

  async function botLoad() {
    const el = document.getElementById('botPanel');
    if (!el) return;
    try {
      const d = await api('/api/admin/bot');
      const s = d.settings, r = d.runtime;
      el.innerHTML = `
        <div class="stat-card">
          <h3>🤖 매칭 봇</h3>
          <div class="bot-state">
            <label class="toggle-switch"><input type="checkbox" id="botEnabled" ${s.enabled ? 'checked' : ''} onchange="botSave({enabled:this.checked})"><span class="toggle-slider"></span></label>
            <span class="state-text ${s.enabled ? 'on' : 'off'}">${s.enabled ? 'ON — 대기 중인 유저에게 봇이 매칭돼요' : 'OFF — 유저끼리만 매칭돼요'}</span>
          </div>
          <div class="field">
            <label><span>봇 투입까지 대기 시간</span><b id="botWaitVal">${s.waitSeconds}초</b></label>
            <input type="range" min="3" max="30" step="1" value="${s.waitSeconds}" oninput="document.getElementById('botWaitVal').textContent=this.value+'초'" onchange="botSave({waitSeconds:+this.value})">
          </div>
          <div class="field">
            <label><span>봇 실력</span><b id="botSkillVal">${Math.round(s.skill * 100)}%</b></label>
            <input type="range" min="0" max="100" step="5" value="${Math.round(s.skill * 100)}" oninput="document.getElementById('botSkillVal').textContent=this.value+'%'" onchange="botSave({skill:+this.value/100})">
            <div class="duo-note">낮을수록 느리고 실수가 잦아요. 너무 높으면 유저가 계속 져서 이탈할 수 있어요 (추천 40~60%).</div>
          </div>
          <div class="field">
            <label><span>동시에 투입할 수 있는 봇 수</span></label>
            <input type="number" id="botMax" min="1" max="50" value="${s.maxConcurrent}" onchange="botSave({maxConcurrent:+this.value})">
          </div>
        </div>
        <div class="stat-card">
          <h3>봇 현황</h3>
          <div class="stats-grid" style="grid-template-columns:repeat(2,1fr);gap:10px;margin:8px 0 0">
            <div><div class="number" style="font-size:24px">${r.activeBots}</div><div class="sub">지금 대전 중</div></div>
            <div><div class="number" style="font-size:24px">${d.games.today}</div><div class="sub">오늘 봇 대전</div></div>
            <div><div class="number" style="font-size:24px">${d.games.week}</div><div class="sub">최근 7일 봇 대전</div></div>
            <div><div class="number" style="font-size:24px">${d.games.botWinRate === null ? '-' : d.games.botWinRate + '%'}</div><div class="sub">봇 승률 (7일)</div></div>
          </div>
          <div class="duo-note" style="margin-top:14px">서버 시작 이후 — 투입 ${r.spawned} · 매칭 성사 ${r.matched} · 실패 ${r.failed} · 봇 계정 ${d.accounts}개</div>
          <div class="duo-note"><b>봇이 두는 게임:</b><br>${r.supportedGames.map((g) => `<span class="bot-tag">${esc(label(g))}${r.hardcoreGames.includes(g) ? '(하드코어 가능)' : ''}</span>`).join('')}<br>그 외 게임·무한 모드·랭크전은 봇이 붙지 않고 유저끼리만 매칭돼요.</div>
          <div class="duo-note">봇 계정은 유저 목록·랭킹·통계에서 제외되고, 친구 요청을 받을 수 없어요. 봇과 둔 대전은 유저의 전적·코인에 정상 반영돼요.</div>
        </div>`;
    } catch (e) {
      console.error('bot load failed', e);
      el.innerHTML = '<div class="empty">봇 설정을 불러오지 못했어요.</div>';
    }
  }

  async function botSave(patch) {
    try {
      const res = await api('/api/admin/bot', { method: 'PUT', body: JSON.stringify(patch) });
      if (res && res.error) throw new Error(res.error);
    } catch (e) {
      alert('봇 설정 저장에 실패했어요: ' + (e && e.message ? e.message : e));
    }
    botLoad();
  }

  // ============================================================
  // 상점 패널 (#shopPanel) — 매출 통계 + 아이템 운영
  // ============================================================
  const CAT_LABELS = { frame: '프레임', title: '칭호', theme: '테마', avatar: '아바타', mascot: '마스코트', ticket: '티켓' };
  const RARITY_LABELS = { common: '일반', rare: '희귀', epic: '영웅', legendary: '전설' };
  const RARITY_COLORS = { common: '#9aa3b2', rare: '#4d9fff', epic: '#a66cff', legendary: '#ffb020' };
  const BADGE_LABELS = { '': '자동', new: 'NEW', hot: 'HOT', limited: '한정' };
  const catLabel = (c) => CAT_LABELS[c] || c;
  const shopState = { days: 30, stats: null, items: [], cat: '', q: '' };

  // ISO → datetime-local 입력값(브라우저 로컬)
  function toLocalInput(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '';
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  }
  const fromLocalInput = (v) => (v ? new Date(v).toISOString() : null);

  // 점유율 막대(기존 bar-chart 마크업 재사용). rows: [{label,value,color?,sub}]
  function shareBars(rows) {
    const total = rows.reduce((a, r) => a + r.value, 0);
    const max = Math.max(1, ...rows.map((r) => r.value));
    if (!rows.length) return '<div class="empty" style="padding:20px">데이터 없음</div>';
    return `<div class="bar-chart">${rows.map((r) => `
      <div class="bar-row"><span class="bar-label">${esc(r.label)}</span>
      <div class="bar-track"><div class="bar-fill" style="width:${(r.value / max) * 100}%;${r.color ? `background:${r.color}` : ''}"></div></div>
      <span class="bar-count" title="${esc(r.sub)}">${fmt(r.value)} <small class="shop-pct">${total ? Math.round((r.value / total) * 100) : 0}%</small></span></div>`).join('')}</div>`;
  }

  function shopStatsHtml(d) {
    const s = d.summary;
    const days = d.daily.map((x) => x.date);
    const pct = (v) => (v * 100).toFixed(1) + '%';
    return `
      <div class="duo-live shop-kpis">
        <div class="stat-card accent"><h3>오늘 매출</h3><div class="number">${fmt(s.revenueToday)}</div><div class="sub">구매 ${fmt(s.purchasesToday)}건</div></div>
        <div class="stat-card"><h3>최근 7일 매출</h3><div class="number">${fmt(s.revenue7d)}</div><div class="sub">코인 소비 기준</div></div>
        <div class="stat-card"><h3>${d.days}일 매출</h3><div class="number">${fmt(s.revenueRange)}</div><div class="sub">구매 ${fmt(s.purchasesRange)}건</div></div>
        <div class="stat-card"><h3>구매 유저</h3><div class="number">${fmt(s.buyersRange)}</div><div class="sub">결제 전환율 ${pct(s.payersRate)}</div></div>
        <div class="stat-card"><h3>ARPU</h3><div class="number">${fmt(s.arpu)}</div><div class="sub">활성 유저당 소비 코인</div></div>
        <div class="stat-card success"><h3>재구매(연장)율</h3><div class="number">${pct(s.renewalRate)}</div><div class="sub">기간제 연장 / 전체 구매</div></div>
        <div class="stat-card"><h3>이용 중 기간제</h3><div class="number">${fmt(s.activeTimedOwnerships)}</div><div class="sub">3일 내 만료 ${fmt(s.expiringIn3d)}</div></div>
        <div class="stat-card"><h3>유통 코인</h3><div class="number">${fmt(s.coinsInCirculation)}</div><div class="sub">${d.days}일 획득 ${fmt(s.coinsEarnedRange)} · 소비 ${fmt(s.coinsSpentRange)}</div></div>
      </div>
      <div class="duo-row">
        <div class="chart-container" style="grid-column:1/-1">
          <h3>일별 매출 (최근 ${d.days}일)</h3>
          ${trendChart(days, [{ name: '매출', color: '#a99dff', values: d.daily.map((x) => x.revenue) }])}
          <div class="duo-note">막대에 마우스를 올리면 날짜별 매출이 보여요. 구매 ${fmt(s.purchasesRange)}건 · 구매 유저 ${fmt(s.buyersRange)}명</div>
        </div>
      </div>
      <div class="duo-row">
        <div class="chart-container"><h3>카테고리별 매출</h3>${shareBars(d.byCategory.map((r) => ({ label: catLabel(r.category), value: r.revenue, sub: r.purchases + '건' })))}</div>
        <div class="chart-container"><h3>희귀도별 매출</h3>${shareBars(d.byRarity.map((r) => ({ label: RARITY_LABELS[r.rarity] || r.rarity, value: r.revenue, color: RARITY_COLORS[r.rarity], sub: r.purchases + '건' })))}</div>
      </div>
      <div class="duo-row">
        <div class="chart-container">
          <h3>인기 아이템 TOP 15</h3>
          <table class="duo-mini-table"><thead><tr><th>#</th><th>아이템</th><th>구매</th><th>연장</th><th>매출</th></tr></thead><tbody>
            ${d.topItems.length ? d.topItems.map((t, i) => `<tr><td>${i + 1}</td><td>${esc(t.name)} <span class="shop-chip" style="color:${RARITY_COLORS[t.rarity] || '#999'}">${esc(catLabel(t.category))}</span></td><td>${fmt(t.purchases)}</td><td>${fmt(t.renewals)}</td><td>${fmt(t.revenue)}</td></tr>`).join('') : '<tr><td colspan="5" class="empty">데이터 없음</td></tr>'}
          </tbody></table>
        </div>
        <div class="chart-container">
          <h3>기간 내 안 팔린 아이템</h3>
          <table class="duo-mini-table"><thead><tr><th>아이템</th><th>카테고리</th><th>가격</th></tr></thead><tbody>
            ${d.neverSold.length ? d.neverSold.map((t) => `<tr><td>${esc(t.name)}</td><td>${esc(catLabel(t.category))}</td><td>${fmt(t.price)}</td></tr>`).join('') : '<tr><td colspan="3" class="empty">없음</td></tr>'}
          </tbody></table>
          <h3 style="margin-top:18px">할인 성과</h3>
          <table class="duo-mini-table"><thead><tr><th>아이템</th><th>할인</th><th>구매</th></tr></thead><tbody>
            ${d.salePerformance.length ? d.salePerformance.map((t) => `<tr><td>${esc(t.name)}</td><td>${t.discountPercent}%</td><td>${fmt(t.purchasesRange)}</td></tr>`).join('') : '<tr><td colspan="3" class="empty">할인 구매 없음</td></tr>'}
          </tbody></table>
        </div>
      </div>`;
  }

  function shopRowHtml(it) {
    const noDur = it.isDefault || it.category === 'ticket';
    const saleNow = it.saleActive && it.salePercent > 0;
    return `<tr data-id="${it.id}" class="${it.isActive ? '' : 'shop-off'}">
      <td><b>${esc(it.name)}</b><div class="shop-sub">${esc(it.itemKey)}${it.isDefault ? ' · 기본' : ''}</div></td>
      <td>${esc(catLabel(it.category))}<div class="shop-sub" style="color:${RARITY_COLORS[it.rarity] || '#999'}">${esc(RARITY_LABELS[it.rarity] || it.rarity)}</div></td>
      <td><input type="number" class="shop-in w70" data-f="price" min="0" max="100000" value="${it.basePrice}" ${it.isDefault ? 'disabled' : ''}>${saleNow ? `<div class="shop-sub">적용가 ${fmt(it.price)}</div>` : ''}</td>
      <td><input type="number" class="shop-in w56" data-f="durationDays" min="1" max="365" placeholder="영구" value="${it.durationDays || ''}" ${noDur ? 'disabled' : ''}></td>
      <td><label class="toggle-switch"><input type="checkbox" data-f="isActive" ${it.isActive ? 'checked' : ''}><span class="toggle-slider"></span></label></td>
      <td><input type="number" class="shop-in w56" data-f="salePercent" min="0" max="90" value="${it.salePercent}">%<br><input type="datetime-local" class="shop-in" data-f="saleEndsAt" value="${toLocalInput(it.saleEndsAt)}"></td>
      <td><select class="shop-in" data-f="badge">${Object.keys(BADGE_LABELS).map((k) => `<option value="${k}" ${(it.badge || '') === k ? 'selected' : ''}>${BADGE_LABELS[k]}</option>`).join('')}</select></td>
      <td><input type="checkbox" data-f="isFeatured" ${it.isFeatured ? 'checked' : ''}></td>
      <td><input type="datetime-local" class="shop-in" data-f="availableUntil" value="${toLocalInput(it.availableUntil)}"></td>
      <td>${fmt(it.salesRange)} / ${fmt(it.salesTotal)}<div class="shop-sub">30일 / 누적 · 매출 ${fmt(it.revenueTotal)}</div></td>
      <td><button class="shop-save" data-act="save">저장</button><span class="shop-msg"></span></td>
    </tr>`;
  }

  function shopVisibleItems() {
    const q = shopState.q.trim().toLowerCase();
    return shopState.items.filter((it) => (!shopState.cat || it.category === shopState.cat)
      && (!q || it.name.toLowerCase().includes(q) || it.itemKey.toLowerCase().includes(q)));
  }

  function shopRenderItemsTable() {
    const body = document.getElementById('shopItemsBody');
    if (!body) return;
    const rows = shopVisibleItems();
    body.innerHTML = rows.length ? rows.map(shopRowHtml).join('') : '<tr><td colspan="11" class="empty">조건에 맞는 아이템이 없어요</td></tr>';
  }

  function shopFrame() {
    const catOpts = Object.keys(CAT_LABELS).map((c) => `<option value="${c}">${esc(CAT_LABELS[c])}</option>`).join('');
    const rarOpts = Object.keys(RARITY_LABELS).map((c) => `<option value="${c}">${esc(RARITY_LABELS[c])}</option>`).join('');
    return `
      <div class="shop-toolbar">
        <div class="shop-range">${[7, 30, 90].map((n) => `<button data-act="range" data-days="${n}" class="${shopState.days === n ? 'on' : ''}">${n}일</button>`).join('')}</div>
        <button class="shop-save" data-act="refresh">새로고침</button>
      </div>
      <div id="shopStats"><div class="empty">불러오는 중...</div></div>
      <div class="chart-container shop-block">
        <h3>카테고리 일괄 할인</h3>
        <div class="shop-bulk">
          <select id="shopBulkCat" class="shop-in"><option value="">전체 카테고리</option>${catOpts}</select>
          <select id="shopBulkRar" class="shop-in"><option value="">전체 희귀도</option>${rarOpts}</select>
          <label>할인 <input type="number" id="shopBulkPct" class="shop-in w56" min="0" max="90" value="20">%</label>
          <label>종료 <input type="datetime-local" id="shopBulkEnds" class="shop-in"></label>
          <button class="shop-save" data-act="bulk">적용</button>
        </div>
        <div class="duo-note">기본(무료) 아이템과 판매 중이 아닌 아이템은 제외돼요. 할인 0%는 해제예요. 종료일을 비우면 수동으로 끌 때까지 유지돼요.</div>
      </div>
      <div class="chart-container shop-block">
        <h3>아이템 관리</h3>
        <div class="shop-toolbar">
          <select id="shopCat" class="shop-in"><option value="">전체 카테고리</option>${catOpts}</select>
          <input type="search" id="shopQ" class="shop-in" placeholder="이름·키 검색">
        </div>
        <div class="shop-scroll"><table class="duo-mini-table shop-table"><thead><tr>
          <th>아이템</th><th>분류</th><th>정가</th><th>기간(일)</th><th>판매</th><th>할인 · 종료</th><th>배지</th><th>추천</th><th>한정 종료일</th><th>판매량</th><th></th>
        </tr></thead><tbody id="shopItemsBody"></tbody></table></div>
        <div class="duo-note">기간(일)을 비우면 영구 아이템이에요. 이미 보유한 유저의 만료일은 바뀌지 않고, 이후 구매·연장부터 적용돼요. 한정 종료일이 지나면 상점에서 사라지지만 보유자는 계속 쓸 수 있어요.</div>
      </div>`;
  }

  async function shopLoadStats() {
    const el = document.getElementById('shopStats');
    if (!el) return;
    try {
      const d = await api('/api/admin/shop/stats?days=' + shopState.days);
      if (d && d.error) throw new Error(d.error);
      shopState.stats = d;
      el.innerHTML = shopStatsHtml(d);
    } catch (e) {
      console.error('shop stats failed', e);
      el.innerHTML = '<div class="empty">상점 통계를 불러오지 못했어요.</div>';
    }
  }

  async function shopLoadItems() {
    try {
      const d = await api('/api/admin/shop/items');
      if (d && d.error) throw new Error(d.error);
      shopState.items = d.items || [];
    } catch (e) {
      console.error('shop items failed', e);
      shopState.items = [];
    }
    shopRenderItemsTable();
  }

  async function shopSaveRow(tr) {
    const id = tr.getAttribute('data-id');
    const it = shopState.items.find((x) => String(x.id) === id);
    if (!it) return;
    const f = (n) => tr.querySelector(`[data-f="${n}"]`);
    const patch = {
      isActive: f('isActive').checked,
      salePercent: parseInt(f('salePercent').value || '0', 10),
      saleEndsAt: fromLocalInput(f('saleEndsAt').value),
      badge: f('badge').value || null,
      isFeatured: f('isFeatured').checked,
      availableUntil: fromLocalInput(f('availableUntil').value),
    };
    if (!it.isDefault) patch.price = parseInt(f('price').value || '0', 10);
    if (!(it.isDefault || it.category === 'ticket')) {
      const dv = f('durationDays').value;
      patch.durationDays = dv === '' ? null : parseInt(dv, 10);
    }
    const msg = tr.querySelector('.shop-msg');
    try {
      const res = await api('/api/admin/shop/items/' + id, { method: 'PATCH', body: JSON.stringify(patch) });
      if (res && res.error) throw new Error(res.error);
      const i = shopState.items.findIndex((x) => String(x.id) === id);
      if (i >= 0 && res.item) shopState.items[i] = { ...shopState.items[i], ...res.item };
      shopRenderItemsTable();
      const nt = document.querySelector(`#shopItemsBody tr[data-id="${id}"] .shop-msg`);
      if (nt) { nt.textContent = '저장됨'; setTimeout(() => { nt.textContent = ''; }, 2500); }
    } catch (e) {
      if (msg) msg.textContent = '';
      alert('상점 아이템 저장에 실패했어요: ' + (e && e.message ? e.message : e));
    }
  }

  async function shopBulk() {
    const cat = document.getElementById('shopBulkCat').value;
    const rar = document.getElementById('shopBulkRar').value;
    const pct = parseInt(document.getElementById('shopBulkPct').value || '0', 10);
    const ends = fromLocalInput(document.getElementById('shopBulkEnds').value);
    const target = `${cat ? catLabel(cat) : '전체'} / ${rar ? RARITY_LABELS[rar] : '전체 희귀도'}`;
    if (!confirm(pct === 0 ? `${target} 아이템의 할인을 해제할까요?` : `${target} 아이템에 ${pct}% 할인을 적용할까요?`)) return;
    try {
      const body = { salePercent: pct, saleEndsAt: ends };
      if (cat) body.category = cat;
      if (rar) body.rarity = rar;
      const res = await api('/api/admin/shop/bulk-sale', { method: 'POST', body: JSON.stringify(body) });
      if (res && res.error) throw new Error(res.error);
      alert(`${res.updated}개 아이템에 적용했어요.`);
    } catch (e) {
      alert('일괄 할인에 실패했어요: ' + (e && e.message ? e.message : e));
    }
    shopLoadItems();
  }

  async function shopLoad() {
    const el = document.getElementById('shopPanel');
    if (!el) return;
    if (!el.dataset.ready) {
      el.dataset.ready = '1';
      el.addEventListener('click', (ev) => {
        const b = ev.target.closest('[data-act]');
        if (!b) return;
        const act = b.getAttribute('data-act');
        if (act === 'range') { shopState.days = parseInt(b.getAttribute('data-days'), 10) || 30; shopLoad(); }
        else if (act === 'refresh') shopLoad();
        else if (act === 'save') shopSaveRow(b.closest('tr'));
        else if (act === 'bulk') shopBulk();
      });
      el.addEventListener('input', (ev) => {
        if (ev.target.id === 'shopQ') { shopState.q = ev.target.value; shopRenderItemsTable(); }
      });
      el.addEventListener('change', (ev) => {
        if (ev.target.id === 'shopCat') { shopState.cat = ev.target.value; shopRenderItemsTable(); }
      });
    }
    el.innerHTML = shopFrame();
    document.getElementById('shopCat').value = shopState.cat;
    document.getElementById('shopQ').value = shopState.q;
    await Promise.all([shopLoadStats(), shopLoadItems()]);
  }

  window.duoOverviewLoad = duoOverviewLoad;
  window.botLoad = botLoad;
  window.botSave = botSave;
  window.shopLoad = shopLoad;
})();
