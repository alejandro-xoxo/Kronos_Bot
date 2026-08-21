const POLL_INTERVAL_MS = 5000;

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

async function loadPositions() {
  const warningEl = document.getElementById("positions-warning");
  const bodyEl = document.getElementById("positions-body");

  try {
    const res = await fetch("api/positions");
    const data = await res.json();

    if (data.stale) {
      warningEl.innerHTML =
        '<div class="warning">El EA todavía no reportó posiciones (status.json no existe todavía).</div>';
      bodyEl.innerHTML = "";
      return;
    }

    warningEl.innerHTML = "";

    const positions = data.positions || [];
    if (positions.length === 0) {
      bodyEl.innerHTML = '<tr><td colspan="10" class="empty-msg">Sin posiciones abiertas.</td></tr>';
      return;
    }

    bodyEl.innerHTML = positions
      .map((p) => {
        const profitClass = p.profit >= 0 ? "profit-pos" : "profit-neg";
        // status.json de EAs viejos (sin recompilar) no trae "managed":
        // tratarlo como true para no ocultar acciones que sí funcionaban.
        const managed = p.managed !== false;
        const originBadge = managed
          ? '<span class="badge-auto">Auto</span>'
          : '<span class="badge-manual">Manual</span>';
        const actions = managed
          ? `<button class="btn-be" data-ticket="${p.ticket}" data-action="SET_BE">BE</button>
             <button class="btn-be-tp" data-ticket="${p.ticket}" data-action="SET_TP_BE">BE inverso</button>
             <button class="btn-close" data-ticket="${p.ticket}" data-action="CLOSE">Cerrar</button>
             <span class="position-action-status" data-ticket="${p.ticket}"></span>`
          : '<span class="position-action-status">Fuera de la automatización — gestionar desde MT4.</span>';
        return `<tr>
          <td data-label="Ticket">${fmt(p.ticket)}</td>
          <td data-label="Origen">${originBadge}</td>
          <td data-label="Símbolo">${fmt(p.symbol)}</td>
          <td data-label="Dirección">${fmt(p.direction)}</td>
          <td data-label="Lote">${fmt(p.lot)}</td>
          <td data-label="Precio apertura">${fmt(p.open_price)}</td>
          <td data-label="SL">${fmt(p.sl)}</td>
          <td data-label="TP">${fmt(p.tp)}</td>
          <td data-label="Profit" class="${profitClass}">${fmt(p.profit)}</td>
          <td data-label="Acciones">
            <div class="position-actions">
              ${actions}
            </div>
          </td>
        </tr>`;
      })
      .join("");

    bodyEl.querySelectorAll(".btn-be, .btn-be-tp, .btn-close").forEach((btn) => {
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
      statusEl.className = "position-action-status status-msg ok";
    } else {
      statusEl.textContent = data.error_message || "El bróker rechazó el comando.";
      statusEl.className = "position-action-status status-msg error";
    }
    loadPositions();
    return;
  }

  statusEl.textContent = "El EA todavía no lo procesó — puede tardar un poco más, revisá la tabla en unos segundos.";
  statusEl.className = "position-action-status status-msg";
  loadPositions();
}

async function sendPositionAction(ticket, action, btn) {
  if (action === "CLOSE") {
    const confirmed = confirm(`¿Cerrar a mercado el ticket ${ticket}? Esto es irreversible.`);
    if (!confirmed) return;
  }

  const statusEl = document.querySelector(`.position-action-status[data-ticket="${ticket}"]`);
  const row = btn.closest("tr");
  row.querySelectorAll(".btn-be, .btn-be-tp, .btn-close").forEach((b) => (b.disabled = true));
  const pendingLabels = {
    SET_BE: "Moviendo a BE...",
    SET_TP_BE: "Moviendo TP a BE...",
    CLOSE: "Cerrando...",
  };
  statusEl.textContent = pendingLabels[action] || "Enviando...";
  statusEl.className = "position-action-status status-msg";

  try {
    const res = await fetch(`api/positions/${ticket}/action`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action }),
    });
    const data = await res.json();
    if (!res.ok) {
      statusEl.textContent = data.error || "Error.";
      statusEl.className = "position-action-status status-msg error";
      row.querySelectorAll(".btn-be, .btn-be-tp, .btn-close").forEach((b) => (b.disabled = false));
      return;
    }
    statusEl.textContent = "Enviado al EA, esperando confirmación...";
    statusEl.className = "position-action-status status-msg";
    await pollActionResult(ticket, action, statusEl);
  } catch (err) {
    statusEl.textContent = "Error de red.";
    statusEl.className = "position-action-status status-msg error";
    row.querySelectorAll(".btn-be, .btn-be-tp, .btn-close").forEach((b) => (b.disabled = false));
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
      bodyEl.innerHTML = '<tr><td colspan="9" class="empty-msg">Sin señales en este período.</td></tr>';
      return;
    }

    bodyEl.innerHTML = signals
      .map((s) => {
        const retryBtn =
          s.status === "PENDING_MANUAL"
            ? `<button class="btn-retry" data-id="${s.id}">Reintentar</button>`
            : "";
        return `<tr>
          <td data-label="Instrumento">${fmt(s.instrument)}</td>
          <td data-label="Dirección">${fmt(s.direction)}</td>
          <td data-label="Estado">${fmt(s.status)}</td>
          <td data-label="Ticket">${fmt(s.mt4_ticket)}</td>
          <td data-label="Entrada">${fmt(s.entry_price)}</td>
          <td data-label="SL">${fmt(s.sl)}</td>
          <td data-label="TP">${fmt(s.tp)}</td>
          <td data-label="Fecha">${fmtDate(s.created_at)}</td>
          <td data-label="Acciones">${retryBtn}<span class="retry-status" data-id="${s.id}"></span></td>
        </tr>`;
      })
      .join("");

    bodyEl.querySelectorAll(".btn-retry").forEach((btn) => {
      btn.addEventListener("click", () => retrySignal(btn.dataset.id, btn));
    });
  } catch (err) {
    bodyEl.innerHTML = '<tr><td colspan="9" class="empty-msg">Sin señales en este período.</td></tr>';
  }
}

async function loadSummary() {
  const bodyEl = document.getElementById("summary-body");
  try {
    const res = await fetch("api/signals/summary");
    const data = await res.json();
    const summaries = data.summaries || [];

    if (summaries.length === 0) {
      bodyEl.innerHTML =
        '<tr><td colspan="6" class="empty-msg">Todavía no se archivó ninguna tanda (menos de 20 señales acumuladas).</td></tr>';
      return;
    }

    bodyEl.innerHTML = summaries
      .map((s) => {
        const statusCounts = Object.entries(s.status_counts || {})
          .map(([status, count]) => `${status}: ${count}`)
          .join(", ");
        const period = `${fmtDate(s.period_start)} — ${fmtDate(s.period_end)}`;
        const plClass = s.total_profit_loss == null ? "" : s.total_profit_loss >= 0 ? "profit-pos" : "profit-neg";
        return `<tr>
          <td>#0</td>
          <td>${period}</td>
          <td>${fmt(s.signal_count)}</td>
          <td>${statusCounts || "-"}</td>
          <td>${fmt(s.instruments)}</td>
          <td class="${plClass}">${fmt(s.total_profit_loss)}</td>
        </tr>`;
      })
      .join("");
  } catch (err) {
    bodyEl.innerHTML = '<tr><td colspan="6" class="empty-msg">Error consultando /api/signals/summary.</td></tr>';
  }
}

async function retrySignal(id, btn) {
  const statusEl = document.querySelector(`.retry-status[data-id="${id}"]`);
  btn.disabled = true;
  statusEl.textContent = "Reintentando...";
  statusEl.className = "retry-status status-msg";
  try {
    const res = await fetch(`api/signals/${id}/retry`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) {
      statusEl.textContent = data.error || "Error al reintentar.";
      statusEl.className = "retry-status status-msg error";
      btn.disabled = false;
      return;
    }
    statusEl.textContent = "Orden reenviada al EA.";
    statusEl.className = "retry-status status-msg ok";
    loadSignals();
  } catch (err) {
    statusEl.textContent = "Error de red al reintentar.";
    statusEl.className = "retry-status status-msg error";
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
  el.className = "status-msg" + (kind ? " " + kind : "");
}

function markActiveButton(suffix) {
  document.getElementById("btn-vip").classList.toggle("active", suffix === "-VIP");
  document.getElementById("btn-std").classList.toggle("active", suffix === "-STD");
}

async function loadConfig() {
  try {
    const res = await fetch("api/config");
    const data = await res.json();
    if (data.symbol_suffix) {
      markActiveButton(data.symbol_suffix);
      setConfigStatus("Sufijo actual: " + data.symbol_suffix, "");
    } else {
      setConfigStatus("Sin configurar todavía.", "");
    }
  } catch (err) {
    setConfigStatus("Error consultando /api/config.", "error");
  }
}

async function setSuffix(suffix) {
  setConfigStatus("Guardando...", "");
  try {
    const res = await fetch("api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ symbol_suffix: suffix }),
    });
    const data = await res.json();
    if (!res.ok) {
      setConfigStatus(data.error || "Error al guardar.", "error");
      return;
    }
    markActiveButton(data.symbol_suffix);
    setConfigStatus("Guardado: " + data.symbol_suffix, "ok");
  } catch (err) {
    setConfigStatus("Error de red al guardar.", "error");
  }
}

document.getElementById("btn-vip").addEventListener("click", () => setSuffix("-VIP"));
document.getElementById("btn-std").addEventListener("click", () => setSuffix("-STD"));

loadPositions();
loadSignals();
loadConfig();
setInterval(loadPositions, POLL_INTERVAL_MS);
setInterval(loadSignals, POLL_INTERVAL_MS);
