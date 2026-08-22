const POLL_INTERVAL_MS = 5000;

const ICON_BE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';
const ICON_BETP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 8l4 4-4 4M3 12h18"/></svg>';
const ICON_CLOSE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6L6 18M6 6l12 12"/></svg>';
const ICON_INFO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/></svg>';

const STATUS_LABELS = {
  PENDING_CONFIRMATION: "Pendiente",
  CONFIRMED: "Confirmada",
  EXECUTED: "Ejecutada",
  PENDING_MANUAL: "Falló — reintentar",
  EXPIRED: "Expirada",
  REJECTED: "Rechazada",
  CANCELLED: "Cancelada",
  FAILED: "Falló",
};

function fmt(value) {
  return value === null || value === undefined ? "-" : value;
}

function fmtDate(value) {
  if (!value) return "-";
  try {
    return new Date(value).toLocaleString();
  } catch (e) {
    return value;
  }
}

// Fecha corta (día/mes) para acompañar la secuencia diaria cuando la
// operación no es de hoy — ej. "3ra del 20 ago".
function fmtShortDay(dateStr) {
  if (!dateStr) return "";
  try {
    return new Date(dateStr + "T00:00:00Z").toLocaleDateString(undefined, {
      day: "numeric",
      month: "short",
      timeZone: "UTC",
    });
  } catch (e) {
    return dateStr;
  }
}

function ordinal(n) {
  return n === 1 ? "1ra" : n === 2 ? "2da" : n === 3 ? "3ra" : `${n}ta`;
}

// Etiqueta amigable ("1ra operación de hoy" / "3ra del 20 ago") a partir
// de daily_seq + daily_seq_date que devuelve el backend — ver
// _attach_daily_seq en main.py. Si el backend no trae secuencia (ej.
// posición sin open_time todavía), cae a un guion en vez de romper.
function dailySeqLabel(seq, seqDate, noun) {
  if (!seq) return "—";
  const todayUTC = new Date().toISOString().slice(0, 10);
  const when = seqDate === todayUTC ? "de hoy" : `del ${fmtShortDay(seqDate)}`;
  return `${ordinal(seq)} ${noun} ${when}`;
}

async function loadPositions() {
  const warningEl = document.getElementById("positions-warning");
  const bodyEl = document.getElementById("positions-body");
  const countEl = document.getElementById("positions-count");
  const liveDot = document.getElementById("live-dot");
  const livePill = document.getElementById("live-pill");

  try {
    const res = await fetch("api/positions");
    const data = await res.json();

    if (data.stale) {
      liveDot.classList.add("off");
      livePill.lastChild.textContent = "Sin datos";
      warningEl.innerHTML =
        '<div class="warning">El EA todavía no reportó posiciones (status.json no existe todavía).</div>';
      bodyEl.innerHTML = "";
      countEl.textContent = "";
      return;
    }

    liveDot.classList.remove("off");
    livePill.lastChild.textContent = "En vivo";
    warningEl.innerHTML = "";

    const positions = data.positions || [];
    countEl.textContent = positions.length ? `${positions.length} activa${positions.length === 1 ? "" : "s"}` : "";

    if (positions.length === 0) {
      bodyEl.innerHTML = '<div class="empty-state">Sin posiciones abiertas.</div>';
      return;
    }

    bodyEl.innerHTML = positions
      .map((p) => {
        const profit = typeof p.profit === "number" ? p.profit : parseFloat(p.profit);
        const isProfit = !isNaN(profit) && profit >= 0;
        const profitClass = isProfit ? "pos" : "neg";
        const cardClass = isNaN(profit) ? "" : isProfit ? "is-profit" : "is-loss";
        const profitText = isNaN(profit) ? fmt(p.profit) : (isProfit ? "+" : "") + profit.toFixed(2);

        const dirUpper = (p.direction || "").toUpperCase();
        const dirClass = dirUpper === "SELL" ? "dir-sell" : "dir-buy";

        // status.json de EAs viejos (sin recompilar) no trae "managed":
        // tratarlo como true para no ocultar acciones que sí funcionaban.
        const managed = p.managed !== false;
        const originBadge = managed
          ? '<span class="badge-auto">Auto</span>'
          : '<span class="badge-manual">Manual</span>';

        const seqLabel = dailySeqLabel(p.daily_seq, p.daily_seq_date, "operación");

        const actions = managed
          ? `<div class="pos-actions">
              <button class="act-btn be" data-ticket="${p.ticket}" data-action="SET_BE">${ICON_BE} BE</button>
              <button class="act-btn betp" data-ticket="${p.ticket}" data-action="SET_TP_BE">${ICON_BETP} BE inverso</button>
              <button class="act-btn close" data-ticket="${p.ticket}" data-action="CLOSE">${ICON_CLOSE} Cerrar</button>
             </div>
             <div class="pos-action-status" data-ticket="${p.ticket}"></div>`
          : `<div class="pos-manual-note">${ICON_INFO} Fuera de la automatización — gestionar desde MT4.</div>`;

        return `<div class="pos-card ${cardClass}">
          <div class="pos-top">
            <div class="pos-instrument">
              <span class="pos-symbol">${fmt(p.symbol)}</span>
              <span class="dir-pill ${dirClass}">${fmt(p.direction)}</span>
              ${originBadge}
            </div>
            <div class="pos-profit-block">
              <div class="pos-profit ${profitClass}">${profitText}</div>
            </div>
          </div>
          <div class="pos-seq">${seqLabel}<span class="pos-ticket">#${fmt(p.ticket)}</span></div>
          <div class="pos-meta">
            <div class="meta-item">
              <span class="meta-label">Lote</span>
              <span class="meta-value">${fmt(p.lot)}</span>
            </div>
            <div class="meta-item">
              <span class="meta-label">Entrada</span>
              <span class="meta-value">${fmt(p.open_price)}</span>
            </div>
            <div class="meta-item">
              <span class="meta-label">SL</span>
              <span class="meta-value sl">${fmt(p.sl)}</span>
            </div>
          </div>
          ${actions}
        </div>`;
      })
      .join("");

    bodyEl.querySelectorAll(".act-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        // CLOSE es irreversible (cierre a mercado) — confirmación extra
        // para evitar un tap accidental desde el celular.
        if (btn.dataset.action === "CLOSE" && !confirm(`¿Cerrar la posición ${btn.dataset.ticket}?`)) {
          return;
        }
        sendPositionAction(btn.dataset.ticket, btn.dataset.action, btn);
      });
    });
  } catch (err) {
    warningEl.innerHTML = '<div class="warning">Error consultando /api/positions.</div>';
  }
}

// Consulta /api/positions/<ticket>/action_result — el resultado REAL
// que escribe el EA tras intentar el comando (éxito con el precio
// resultante, o el error de MT4 tal cual, ej. "Invalid stops" si se
// intenta un BE con la posición todavía en pérdida). El backend borra
// cualquier resultado viejo del mismo ticket+acción al encolar el
// comando nuevo, así que un "found: true" acá siempre corresponde a
// ESTE intento, no a uno anterior. Reintenta cada 1.5s hasta ~10
// veces (~15s); si se agota, deja el aviso de "seguimos esperando".
async function pollActionResult(ticket, action, statusEl) {
  const maxAttempts = 10;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 1500));

    let data;
    try {
      const res = await fetch(`api/positions/${ticket}/action_result?action=${encodeURIComponent(action)}`);
      data = await res.json();
    } catch (err) {
      continue; // error de red puntual, seguimos intentando
    }

    if (!data.found) continue;

    if (data.success) {
      const labels = {
        SET_BE: "SL movido a " + data.result_price,
        SET_TP_BE: "TP movido a " + data.result_price,
        CLOSE: "Cerrada a " + data.result_price,
      };
      statusEl.textContent = labels[action] || "Hecho.";
      statusEl.className = "pos-action-status status-msg ok";
    } else {
      statusEl.textContent = data.error_message || "El bróker rechazó el comando.";
      statusEl.className = "pos-action-status status-msg error";
    }
    loadPositions();
    return;
  }

  statusEl.textContent = "El EA todavía no lo procesó — puede tardar un poco más, revisá en unos segundos.";
  statusEl.className = "pos-action-status status-msg";
  loadPositions();
}

async function sendPositionAction(ticket, action, btn) {
  if (action === "CLOSE") {
    const confirmed = confirm(`¿Cerrar a mercado el ticket ${ticket}? Esto es irreversible.`);
    if (!confirmed) return;
  }

  // Feedback táctil inmediato: el botón se marca "presionado" apenas se
  // toca, sin esperar la respuesta del servidor ni del EA — la ejecución
  // real en MT4 sigue llegando ~1s después por el polling del EA, pero
  // la percepción de respuesta es instantánea.
  btn.classList.add("is-pressed");

  const statusEl = document.querySelector(`.pos-action-status[data-ticket="${ticket}"]`);
  const card = btn.closest(".pos-card");
  card.querySelectorAll(".act-btn").forEach((b) => (b.disabled = true));
  const pendingLabels = {
    SET_BE: "Moviendo a BE...",
    SET_TP_BE: "Moviendo TP a BE...",
    CLOSE: "Cerrando...",
  };
  statusEl.textContent = pendingLabels[action] || "Enviando...";
  statusEl.className = "pos-action-status status-msg";

  try {
    const res = await fetch(`api/positions/${ticket}/action`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action }),
    });
    const data = await res.json();
    btn.classList.remove("is-pressed");
    if (!res.ok) {
      statusEl.textContent = data.error || "Error.";
      statusEl.className = "pos-action-status status-msg error";
      card.querySelectorAll(".act-btn").forEach((b) => (b.disabled = false));
      return;
    }
    statusEl.textContent = "Enviado al EA, esperando confirmación...";
    statusEl.className = "pos-action-status status-msg";
    await pollActionResult(ticket, action, statusEl);
  } catch (err) {
    btn.classList.remove("is-pressed");
    statusEl.textContent = "Error de red.";
    statusEl.className = "pos-action-status status-msg error";
    card.querySelectorAll(".act-btn").forEach((b) => (b.disabled = false));
  }
}

let currentSignalsRange = "all";

async function loadSignals() {
  const bodyEl = document.getElementById("signals-body");
  try {
    const res = await fetch("api/signals?range=" + encodeURIComponent(currentSignalsRange));
    const data = await res.json();
    const signals = data.signals || [];

    if (signals.length === 0) {
      bodyEl.innerHTML = '<div class="empty-state">Sin señales en este período.</div>';
      return;
    }

    bodyEl.innerHTML = signals
      .map((s) => {
        const dirUpper = (s.direction || "").toUpperCase();
        const markClass = dirUpper === "SELL" ? "sell" : "buy";
        const statusKey = (s.status || "").toLowerCase();
        const statusLabel = STATUS_LABELS[s.status] || fmt(s.status);
        const seqLabel = dailySeqLabel(s.daily_seq, s.daily_seq_date, "señal");
        const ticketLine = s.mt4_ticket ? `#${s.mt4_ticket}` : "Sin ticket";

        const retryCol =
          s.status === "PENDING_MANUAL"
            ? `<div class="retry-col">
                 <button class="retry-link" data-id="${s.id}">Reintentar</button>
                 <span class="retry-status" data-id="${s.id}"></span>
               </div>`
            : "";

        return `<div class="signal-row">
          <span class="signal-dir-mark ${markClass}"></span>
          <div class="signal-main">
            <div class="signal-line1">
              ${seqLabel} <span class="dim">· ${fmt(s.instrument)} ${fmt(s.direction)}</span>
            </div>
            <div class="signal-line2">
              <span>${ticketLine}</span><span>${fmt(s.entry_price)} → SL ${fmt(s.sl)} / TP ${fmt(s.tp)}</span><span>${fmtDate(s.created_at)}</span>
            </div>
          </div>
          <span class="status-chip status-${statusKey}">${statusLabel}</span>
          ${retryCol}
        </div>`;
      })
      .join("");

    bodyEl.querySelectorAll(".retry-link").forEach((btn) => {
      btn.addEventListener("click", () => retrySignal(btn.dataset.id, btn));
    });
  } catch (err) {
    bodyEl.innerHTML = '<div class="empty-state">Error consultando el historial de señales.</div>';
  }
}

async function loadSummary() {
  const bodyEl = document.getElementById("summary-body");
  try {
    const res = await fetch("api/signals/summary");
    const data = await res.json();
    const summaries = data.summaries || [];

    if (summaries.length === 0) {
      bodyEl.innerHTML = "";
      return;
    }

    bodyEl.innerHTML = summaries
      .map((s) => {
        const statusCounts = Object.entries(s.status_counts || {})
          .map(([status, count]) => `${STATUS_LABELS[status] || status}: ${count}`)
          .join(" · ");
        const period = `${fmtDate(s.period_start)} — ${fmtDate(s.period_end)}`;
        const pl = s.total_profit_loss;
        const plClass = pl == null ? "" : pl >= 0 ? "profit-pos" : "profit-neg";
        const plText = pl == null ? "-" : (pl >= 0 ? "+" : "") + Number(pl).toFixed(2);
        return `<div class="summary-row">
          <div class="summary-row-top">
            <span>${fmt(s.signal_count)} señales archivadas</span>
            <span class="${plClass}" style="font-family: var(--font-data);">${plText}</span>
          </div>
          <div class="summary-row-period">${period}</div>
          <div class="summary-row-meta">${statusCounts || "-"} · ${fmt(s.instruments)}</div>
        </div>`;
      })
      .join("");
  } catch (err) {
    bodyEl.innerHTML = '<div class="empty-state">Error consultando el resumen archivado.</div>';
  }
}

async function retrySignal(id, btn) {
  const statusEl = document.querySelector(`.retry-status[data-id="${id}"]`);
  btn.disabled = true;
  statusEl.textContent = "Reintentando...";
  statusEl.className = "retry-status";
  try {
    const res = await fetch(`api/signals/${id}/retry`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) {
      statusEl.textContent = data.error || "Error al reintentar.";
      statusEl.className = "retry-status error";
      btn.disabled = false;
      return;
    }
    statusEl.textContent = "Orden reenviada al EA.";
    statusEl.className = "retry-status ok";
    loadSignals();
  } catch (err) {
    statusEl.textContent = "Error de red al reintentar.";
    statusEl.className = "retry-status error";
    btn.disabled = false;
  }
}

function setSignalsRange(range) {
  currentSignalsRange = range;
  document.querySelectorAll("#signals-filter button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.range === range);
  });
  loadSignals();
}

document.querySelectorAll("#signals-filter button").forEach((btn) => {
  btn.addEventListener("click", () => setSignalsRange(btn.dataset.range));
});

function setConfigStatus(message, kind) {
  const el = document.getElementById("config-status");
  el.textContent = message;
  el.className = "config-status" + (kind ? " status-msg " + kind : "");
}

function markActiveButton(profile) {
  document.getElementById("btn-vip").classList.toggle("active", profile === "DEMO_VIP");
  document.getElementById("btn-std").classList.toggle("active", profile === "PROD_STD");
}

async function loadConfig() {
  try {
    const res = await fetch("api/config");
    const data = await res.json();
    if (data.profile) {
      markActiveButton(data.profile);
      setConfigStatus("Perfil actual: " + data.profile, "");
    } else {
      setConfigStatus("Sin configurar todavía.", "");
    }
  } catch (err) {
    setConfigStatus("Error consultando /api/config.", "error");
  }
}

async function setProfile(profile) {
  setConfigStatus("Guardando...", "");
  try {
    const res = await fetch("api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: profile }),
    });
    const data = await res.json();
    if (!res.ok) {
      setConfigStatus(data.error || "Error al guardar.", "error");
      return;
    }
    markActiveButton(data.profile);
    setConfigStatus("Guardado: " + data.profile + ". Se aplica en el próximo ciclo del EA (unos segundos).", "ok");
  } catch (err) {
    setConfigStatus("Error de red al guardar.", "error");
  }
}

document.getElementById("btn-vip").addEventListener("click", () => setProfile("DEMO_VIP"));
document.getElementById("btn-std").addEventListener("click", () => setProfile("PROD_STD"));

loadPositions();
loadSignals();
loadSummary();
loadConfig();
setInterval(loadPositions, POLL_INTERVAL_MS);
setInterval(loadSignals, POLL_INTERVAL_MS);
