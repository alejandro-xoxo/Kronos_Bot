/* Panel de control — datos REALES del EA vía dashboard/main.py.
 * Réplica del dashboard operativo original (dashboard/static/app.js,
 * anterior a la integración de PVG_kronos): posiciones abiertas,
 * botones BE/BE inverso/Cerrar, selector de perfil de cuenta.
 */
var ControlPanel = (function () {
  var POLL_INTERVAL_MS = 5000;
  var pollTimer = null;

  var ICON_BE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';
  var ICON_BETP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 8l4 4-4 4M3 12h18"/></svg>';
  var ICON_CLOSE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6L6 18M6 6l12 12"/></svg>';
  var ICON_INFO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/></svg>';

  function fmt(v) { return v === null || v === undefined ? '—' : v; }
  function money(v) {
    var n = typeof v === 'number' ? v : parseFloat(v);
    return isNaN(n) ? '—' : (n >= 0 ? '+' : '') + n.toFixed(2);
  }

  async function loadPositions() {
    var body = document.getElementById('control-positions');
    var empty = document.getElementById('control-empty');
    var count = document.getElementById('control-count');
    if (!body) return;

    try {
      var res = await fetch('api/positions');
      var data = await res.json();

      if (data.stale) {
        empty.style.display = '';
        empty.textContent = 'El EA todavía no reportó posiciones.';
        body.innerHTML = '';
        count.textContent = '';
        document.getElementById('control-balance').textContent = '—';
        document.getElementById('control-equity').textContent = '—';
        document.getElementById('control-floating').textContent = '—';
        return;
      }

      var positions = data.positions || [];
      empty.style.display = positions.length ? 'none' : '';
      empty.textContent = 'No hay posiciones abiertas en este momento.';
      count.textContent = positions.length ? positions.length + (positions.length === 1 ? ' posición' : ' posiciones') : '';
      body.innerHTML = '';

      var floating = 0;

      positions.forEach(function (p) {
        var profit = typeof p.profit === 'number' ? p.profit : parseFloat(p.profit);
        var isProfit = !isNaN(profit) && profit >= 0;
        floating += isNaN(profit) ? 0 : profit;

        var dirUpper = (p.direction || '').toUpperCase();
        var dirClass = dirUpper === 'SELL' ? 'dir-sell' : 'dir-buy';
        var managed = p.managed !== false;

        var actionsHtml = managed
          ? '<div class="ctrl-actions">' +
              '<button class="btn ctrl-act" data-ticket="' + p.ticket + '" data-action="SET_BE">' + ICON_BE + ' BE</button>' +
              '<button class="btn ctrl-act" data-ticket="' + p.ticket + '" data-action="SET_TP_BE">' + ICON_BETP + ' BE inverso</button>' +
              '<button class="btn btn--danger ctrl-act" data-ticket="' + p.ticket + '" data-action="CLOSE">' + ICON_CLOSE + ' Cerrar</button>' +
            '</div>'
          : '<p class="ctrl-status">' + ICON_INFO + ' Fuera de la automatización — gestionar desde MT4.</p>';

        var card = document.createElement('div');
        card.className = 'ctrl-card ' + (isNaN(profit) ? '' : (isProfit ? 'is-profit' : 'is-loss'));
        card.innerHTML =
          '<div class="ctrl-top">' +
            '<div class="ctrl-instrument">' +
              '<span class="ctrl-symbol">' + fmt(p.symbol) + '</span>' +
              '<span class="ctrl-dir ' + dirClass + '">' + fmt(p.direction) + '</span>' +
            '</div>' +
            '<div class="ctrl-profit-block">' +
              '<div class="ctrl-profit ' + (isProfit ? 'pos' : 'neg') + '">' + money(profit) + '</div>' +
              '<div class="ctrl-ticket">#' + fmt(p.ticket) + '</div>' +
            '</div>' +
          '</div>' +
          '<div class="ctrl-meta">' +
            '<div class="ctrl-meta-item"><span>Lote</span><strong>' + fmt(p.lot) + '</strong></div>' +
            '<div class="ctrl-meta-item"><span>Entrada</span><strong>' + fmt(p.open_price) + '</strong></div>' +
            '<div class="ctrl-meta-item"><span>Actual</span><strong>' + fmt(p.current_price) + '</strong></div>' +
            '<div class="ctrl-meta-item"><span>SL</span><strong class="neg">' + fmt(p.sl) + '</strong></div>' +
          '</div>' +
          actionsHtml +
          '<p class="ctrl-status" data-ticket="' + p.ticket + '"></p>';
        body.appendChild(card);
      });

      body.querySelectorAll('.ctrl-act').forEach(function (btn) {
        btn.addEventListener('click', function () {
          if (btn.dataset.action === 'CLOSE' && !confirm('¿Cerrar a mercado el ticket ' + btn.dataset.ticket + '? Esto es irreversible.')) {
            return;
          }
          sendPositionAction(btn.dataset.ticket, btn.dataset.action, btn);
        });
      });

      var account = data.account || {};
      document.getElementById('control-balance').textContent = account.balance != null ? account.balance.toFixed(2) : '—';
      document.getElementById('control-equity').textContent = account.equity != null ? account.equity.toFixed(2) : '—';
      var floatEl = document.getElementById('control-floating');
      floatEl.textContent = money(floating);
      floatEl.className = floating >= 0 ? 'pos' : 'neg';
    } catch (err) {
      empty.style.display = '';
      empty.textContent = 'Error consultando /api/positions.';
      body.innerHTML = '';
    }
  }

  // 30 intentos cada 500ms (~15s) en vez de 10 cada 1.5s — mismo fix
  // real ya aplicado en producción (ver historial de dashboard/main.py
  // y el app.js viejo), mejora la responsividad percibida de BE/Cerrar.
  async function pollActionResult(ticket, action, statusEl) {
    var maxAttempts = 30;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await new Promise(function (resolve) { setTimeout(resolve, 500); });

      var data;
      try {
        var res = await fetch('api/positions/' + ticket + '/action_result?action=' + encodeURIComponent(action));
        data = await res.json();
      } catch (err) {
        continue;
      }

      if (!data.found) continue;

      if (data.success) {
        var labels = {
          SET_BE: 'SL movido a ' + data.result_price,
          SET_TP_BE: 'TP movido a ' + data.result_price,
          CLOSE: 'Cerrada a ' + data.result_price,
        };
        statusEl.textContent = labels[action] || 'Hecho.';
      } else {
        statusEl.textContent = data.error_message || 'El bróker rechazó el comando.';
      }
      loadPositions();
      return;
    }

    statusEl.textContent = 'El EA todavía no lo procesó — revisá en unos segundos.';
    loadPositions();
  }

  async function sendPositionAction(ticket, action, btn) {
    var statusEl = document.querySelector('.ctrl-status[data-ticket="' + ticket + '"]');
    var card = btn.closest('.ctrl-card');
    card.querySelectorAll('.ctrl-act').forEach(function (b) { b.disabled = true; });
    var pendingLabels = { SET_BE: 'Moviendo a BE...', SET_TP_BE: 'Moviendo TP a BE...', CLOSE: 'Cerrando...' };
    statusEl.textContent = pendingLabels[action] || 'Enviando...';

    try {
      var res = await fetch('api/positions/' + ticket + '/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: action }),
      });
      var data = await res.json();
      if (!res.ok) {
        statusEl.textContent = data.error || 'Error.';
        card.querySelectorAll('.ctrl-act').forEach(function (b) { b.disabled = false; });
        return;
      }
      statusEl.textContent = 'Enviado al EA, esperando confirmación...';
      await pollActionResult(ticket, action, statusEl);
    } catch (err) {
      statusEl.textContent = 'Error de red.';
      card.querySelectorAll('.ctrl-act').forEach(function (b) { b.disabled = false; });
    }
  }

  function markActiveProfile(profile) {
    var wrap = document.getElementById('control-segmented');
    if (!wrap) return;
    wrap.querySelectorAll('.segmented__btn').forEach(function (b) {
      b.classList.toggle('is-active', b.dataset.profile === profile);
    });
  }

  async function loadConfig() {
    try {
      var res = await fetch('api/config');
      var data = await res.json();
      markActiveProfile(data.profile);
    } catch (err) { /* silencioso, mismo criterio que el dashboard original */ }
  }

  async function setProfile(profile) {
    try {
      var res = await fetch('api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ profile: profile }),
      });
      var data = await res.json();
      if (res.ok) markActiveProfile(data.profile);
    } catch (err) { /* silencioso */ }
  }

  function initSegmented() {
    var wrap = document.getElementById('control-segmented');
    if (!wrap) return;
    wrap.addEventListener('click', function (e) {
      var btn = e.target.closest('.segmented__btn');
      if (!btn) return;
      setProfile(btn.dataset.profile);
    });
  }

  function startPolling() {
    if (pollTimer) return;
    pollTimer = setInterval(function () {
      var panel = document.getElementById('tab-control');
      if (panel && !panel.classList.contains('hidden')) loadPositions();
    }, POLL_INTERVAL_MS);
  }

  function init() {
    initSegmented();
    loadConfig();
    loadPositions();
    startPolling();
  }

  return { init: init, render: loadPositions };
})();
