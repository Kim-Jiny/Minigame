/* 듀오 아레나 관리자 — 운영 개요(실시간·추이·시간대·경제·CS)와 매칭 봇 설정.
   index.html 의 전역 api / escapeHtml 을 쓴다. 전역은 duoOverviewLoad, botLoad, botSave 만 노출. */
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

  window.duoOverviewLoad = duoOverviewLoad;
  window.botLoad = botLoad;
  window.botSave = botSave;
})();
