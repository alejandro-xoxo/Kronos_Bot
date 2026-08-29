/* Sección 3 — Conversor de monedas a EUR.
   Tasas expresadas siempre como "unidades de X por 1 EUR".
   Fuentes, por prioridad: tasa manual > caché de la API > API en vivo. */
(function () {
  const $ = function (id) { return document.getElementById(id); };

  // Monedas que se ofrecen aunque la API no haya respondido todavía.
  const FAVORITAS = ['COP', 'USD', 'GBP', 'MXN', 'ARS', 'BRL', 'CHF', 'CAD', 'JPY'];

  const state = {
    endpoint: Store.get('fx.endpoint', 'https://open.er-api.com/v6/latest/EUR'),
    key: Store.get('fx.key', ''),
    api: Store.get('fx.api', null),        // {rates:{}, ts:Number}
    manual: Store.get('fx.manual', {}),    // {COP: 4300, ...}
    moneda: Store.get('fx.moneda', 'COP'),
    invertido: false
  };

  function tasa(cod) {
    if (cod === 'EUR') return 1;
    if (state.manual[cod] != null) return Number(state.manual[cod]);
    if (state.api && state.api.rates && state.api.rates[cod] != null) return Number(state.api.rates[cod]);
    return null;
  }

  function origen(cod) {
    if (cod === 'EUR') return 'base';
    if (state.manual[cod] != null) return 'manual';
    if (state.api && state.api.rates && state.api.rates[cod] != null) return 'API';
    return '—';
  }

  function codigos() {
    const set = {};
    FAVORITAS.forEach(function (c) { set[c] = 1; });
    Object.keys(state.manual).forEach(function (c) { set[c] = 1; });
    if (state.api && state.api.rates) Object.keys(state.api.rates).forEach(function (c) { set[c] = 1; });
    delete set.EUR;
    return Object.keys(set).sort(function (a, b) {
      const fa = FAVORITAS.indexOf(a), fb = FAVORITAS.indexOf(b);
      if (fa !== -1 || fb !== -1) return (fa === -1 ? 999 : fa) - (fb === -1 ? 999 : fb);
      return a < b ? -1 : 1;
    });
  }

  function pintarSelect() {
    const sel = $('fx-moneda');
    const actual = state.moneda;
    sel.innerHTML = '';
    codigos().forEach(function (c) {
      const o = document.createElement('option');
      o.value = c;
      o.textContent = c + (tasa(c) == null ? ' (sin tasa)' : '');
      sel.appendChild(o);
    });
    sel.value = actual;
    if (sel.value !== actual && sel.options.length) {
      state.moneda = sel.value;
    }
  }

  function pintarTablaTasas() {
    const tbody = document.querySelector('#tabla-fx tbody');
    tbody.innerHTML = '';
    codigos().forEach(function (c) {
      const t = tasa(c);
      if (t == null) return;
      const tr = document.createElement('tr');

      const td1 = document.createElement('td'); td1.textContent = c;
      const td2 = document.createElement('td'); td2.textContent = Fmt.num(t, t < 10 ? 4 : 2);
      const td3 = document.createElement('td'); td3.textContent = origen(c);
      const td4 = document.createElement('td');

      if (state.manual[c] != null) {
        const b = document.createElement('button');
        b.className = 'del'; b.type = 'button'; b.textContent = '×';
        b.title = 'Quitar tasa manual de ' + c;
        b.addEventListener('click', function () {
          delete state.manual[c];
          Store.set('fx.manual', state.manual);
          refrescar();
        });
        td4.appendChild(b);
      }
      [td1, td2, td3, td4].forEach(function (td) { tr.appendChild(td); });
      tbody.appendChild(tr);
    });
  }

  function convertir() {
    const cantidad = Number($('fx-cantidad').value);
    const cod = state.moneda;
    const t = tasa(cod);
    const out = $('fx-resultado');
    const det = $('fx-detalle');

    if (!isFinite(cantidad)) { out.textContent = '—'; det.textContent = 'Introduce una cantidad.'; return; }
    if (t == null || t === 0) {
      out.textContent = '—';
      det.textContent = 'No hay tasa para ' + cod + '. Actualiza las tasas o introdúcela manualmente.';
      return;
    }

    if (state.invertido) {
      // EUR → moneda
      const r = cantidad * t;
      out.textContent = Fmt.money(r, cod);
      det.textContent = Fmt.money(cantidad, 'EUR') + ' · 1 EUR = ' + Fmt.num(t, t < 10 ? 4 : 2) + ' ' + cod;
    } else {
      const r = cantidad / t;
      out.textContent = Fmt.money(r, 'EUR');
      det.textContent = Fmt.num(cantidad, 2) + ' ' + cod + ' · 1 EUR = ' + Fmt.num(t, t < 10 ? 4 : 2) + ' ' + cod;
    }
  }

  function estadoTexto() {
    const el = $('fx-estado');
    if (state.api && state.api.ts) {
      const d = new Date(state.api.ts);
      el.textContent = 'Tasas de la API actualizadas el ' + d.toLocaleString('es-ES') +
        '. Las tasas manuales tienen prioridad sobre la API.';
    } else {
      el.textContent = 'Sin datos de la API. Usa "Actualizar tasas" o introduce las tasas manualmente.';
    }
    el.className = 'hint';
  }

  function refrescar() {
    pintarSelect();
    pintarTablaTasas();
    convertir();
    estadoTexto();
  }

  function urlFinal() {
    let u = state.endpoint.trim();
    if (state.key) {
      u = u.indexOf('{key}') !== -1
        ? u.replace('{key}', encodeURIComponent(state.key))
        : u + (u.indexOf('?') === -1 ? '?' : '&') + 'apikey=' + encodeURIComponent(state.key);
    }
    return u;
  }

  function actualizarTasas() {
    const el = $('fx-estado');
    el.textContent = 'Consultando tasas…';
    el.className = 'hint';

    fetch(urlFinal(), { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (j) {
        // Distintos proveedores usan nombres distintos para el mismo mapa.
        const rates = j.rates || j.conversion_rates || j.data || null;
        if (!rates || typeof rates !== 'object') throw new Error('Respuesta sin tasas reconocibles');

        // Si la base no es EUR, reconvertimos todo a base EUR.
        const base = j.base || j.base_code || 'EUR';
        let mapa = rates;
        if (base !== 'EUR') {
          const eur = Number(rates.EUR);
          if (!eur) throw new Error('La API no devuelve EUR y su base no es EUR');
          mapa = {};
          Object.keys(rates).forEach(function (k) { mapa[k] = Number(rates[k]) / eur; });
        }

        state.api = { rates: mapa, ts: Date.now() };
        Store.set('fx.api', state.api);
        refrescar();
        flash(el, 'Tasas actualizadas correctamente.', 'ok');
        setTimeout(estadoTexto, 3000);
      })
      .catch(function (e) {
        el.className = 'hint neg';
        el.textContent = 'No se pudieron obtener las tasas (' + e.message +
          '). Se siguen usando las tasas guardadas o las manuales.';
      });
  }

  function guardarManual() {
    const cod = ($('fx-man-cod').value || '').trim().toUpperCase();
    const val = Number($('fx-man-val').value);
    const el = $('fx-estado');

    if (!/^[A-Z]{2,6}$/.test(cod)) { flash(el, 'Código de moneda inválido (ej.: COP).', 'error'); return; }
    if (!isFinite(val) || val <= 0) { flash(el, 'La tasa debe ser un número mayor que 0.', 'error'); return; }

    state.manual[cod] = val;
    Store.set('fx.manual', state.manual);
    state.moneda = cod;
    Store.set('fx.moneda', cod);
    $('fx-man-cod').value = '';
    $('fx-man-val').value = '';
    refrescar();
    flash(el, 'Tasa manual guardada para ' + cod + '.', 'ok');
  }

  function init() {
    $('fx-endpoint').value = state.endpoint;
    $('fx-key').value = state.key;
    $('fx-cantidad').value = Store.get('fx.cantidad', 100000);

    pintarSelect();
    $('fx-moneda').value = state.moneda;

    $('fx-cantidad').addEventListener('input', function () {
      Store.set('fx.cantidad', Number(this.value) || 0);
      convertir();
    });
    $('fx-moneda').addEventListener('change', function () {
      state.moneda = this.value;
      Store.set('fx.moneda', state.moneda);
      convertir();
    });
    $('fx-endpoint').addEventListener('change', function () {
      state.endpoint = this.value.trim();
      Store.set('fx.endpoint', state.endpoint);
    });
    $('fx-key').addEventListener('change', function () {
      state.key = this.value.trim();
      Store.set('fx.key', state.key);
    });
    $('fx-actualizar').addEventListener('click', actualizarTasas);
    $('fx-invertir').addEventListener('click', function () {
      state.invertido = !state.invertido;
      this.textContent = state.invertido ? 'Invertir (moneda → EUR)' : 'Invertir (EUR → moneda)';
      document.querySelector('#tab-conversor h2').textContent =
        state.invertido ? 'Convertir desde EUR' : 'Convertir a EUR';
      convertir();
    });
    $('fx-man-guardar').addEventListener('click', guardarManual);
    $('fx-man-borrar').addEventListener('click', function () {
      if (!confirm('¿Borrar todas las tasas manuales guardadas?')) return;
      state.manual = {};
      Store.set('fx.manual', state.manual);
      refrescar();
    });

    refrescar();

    // Refresca automáticamente si la caché tiene más de 12 h (o no existe).
    const doceHoras = 12 * 60 * 60 * 1000;
    if (!state.api || (Date.now() - state.api.ts) > doceHoras) actualizarTasas();
  }

  window.FX = { init: init };
})();
