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
      bodyEl.innerHTML = '<tr><td colspan="11" class="empty-msg">Sin posiciones abiertas.</td></tr>';
      return;
    }

    bodyEl.innerHTML = positions
      .map((p) => {
        const profitClass = p.profit >= 0 ? "profit-pos" : "profit-neg";
        return `<tr>
          <td>${fmt(p.ticket)}</td>
          <td>${fmt(p.signal_uid)}</td>
          <td>${fmt(p.symbol)}</td>
          <td>${fmt(p.direction)}</td>
          <td>${fmt(p.lot)}</td>
          <td>${fmt(p.open_price)}</td>
          <td>${fmt(p.current_price)}</td>
          <td>${fmt(p.sl)}</td>
          <td>${fmt(p.tp)}</td>
          <td class="${profitClass}">${fmt(p.profit)}</td>
          <td>${fmtDate(p.open_time)}</td>
        </tr>`;
      })
      .join("");
  } catch (err) {
    warningEl.innerHTML = '<div class="warning">Error consultando /api/positions.</div>';
  }
}

async function loadSignals() {
  const bodyEl = document.getElementById("signals-body");
  try {
    const res = await fetch("api/signals");
    const data = await res.json();
    const signals = data.signals || [];

    if (signals.length === 0) {
      bodyEl.innerHTML = '<tr><td colspan="8" class="empty-msg">Sin señales todavía.</td></tr>';
      return;
    }

    bodyEl.innerHTML = signals
      .map(
        (s) => `<tr>
          <td>${fmt(s.instrument)}</td>
          <td>${fmt(s.direction)}</td>
          <td>${fmt(s.status)}</td>
          <td>${fmt(s.mt4_ticket)}</td>
          <td>${fmt(s.entry_price)}</td>
          <td>${fmt(s.sl)}</td>
          <td>${fmt(s.tp)}</td>
          <td>${fmtDate(s.created_at)}</td>
        </tr>`
      )
      .join("");
  } catch (err) {
    bodyEl.innerHTML = '<tr><td colspan="8" class="empty-msg">Error consultando /api/signals.</td></tr>';
  }
}

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
