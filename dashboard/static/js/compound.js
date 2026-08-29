/* Sección 2 — Simulador de interés compuesto con días operables.

   La simulación avanza día por día en el calendario a partir de la fecha de
   inicio. Un día es operable si su día de la semana está activado Y su fecha
   no figura en la lista de fechas no operables. El % sólo se aplica los días
   operables; los no operables dejan el capital exactamente igual. */
(function () {
  const $ = function (id) { return document.getElementById(id); };
  const MAX_DIAS = 1825;         // ~5 años
  const MAX_FILAS_TABLA = 500;   // el CSV sí lleva todas

  let chart = null;
  let ultima = [];   // filas de la última simulación (para CSV)
  let ultimoP = null;

  /* --- días de la semana operables (lunes = 0 … domingo = 6) --- */
  function construirDOW(activos) {
    const cont = $('ci-dow');
    cont.innerHTML = '';
    Cal.NOMBRES_DIA.forEach(function (n, i) {
      const lab = document.createElement('label');
      lab.className = 'dow__item';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.id = 'ci-dow-' + i;
      cb.checked = activos.indexOf(i) !== -1;
      cb.addEventListener('change', correr);
      const sp = document.createElement('span');
      sp.textContent = n;
      lab.appendChild(cb);
      lab.appendChild(sp);
      cont.appendChild(lab);
    });
  }

  function dowActivos() {
    const out = [];
    for (let i = 0; i < 7; i++) {
      const el = $('ci-dow-' + i);
      if (el && el.checked) out.push(i);
    }
    return out;
  }

  /* Acepta fechas separadas por línea, coma, punto y coma o espacio. */
  function parseFeriados(txt) {
    const set = {};
    String(txt || '').split(/[\s,;]+/).forEach(function (t) {
      const s = t.trim();
      if (/^\d{4}-\d{2}-\d{2}$/.test(s)) set[s] = 1;
    });
    return set;
  }

  function leerParams() {
    const dias = Math.min(Math.max(parseInt($('ci-dias').value, 10) || 1, 1), MAX_DIAS);
    $('ci-dias').value = dias;
    return {
      capital: Math.max(Number($('ci-capital').value) || 0, 0),
      pct: Number($('ci-pct').value) || 0,
      dias: dias,
      inicio: $('ci-fecha').value || hoyISO(),
      dow: dowActivos(),
      feriados: parseFeriados($('ci-feriados').value),
      reinvertir: $('ci-reinvertir').checked
    };
  }

  function esOperable(iso, p) {
    if (p.feriados[iso]) return false;
    return p.dow.indexOf(Cal.diaSemana(iso)) !== -1;
  }

  /* Devuelve una fila por día de calendario. La curva "simple" (ganancia
     siempre sobre el capital inicial) se calcula en paralelo para comparar. */
  function simular(p) {
    const filas = [];
    let capital = p.capital;
    let simple = p.capital;
    const gananciaFija = p.capital * (p.pct / 100);
    let nOp = 0;

    for (let i = 0; i < p.dias; i++) {
      const fecha = Cal.sumarDias(p.inicio, i);
      const op = esOperable(fecha, p);
      let ganancia = 0;

      if (op) {
        nOp++;
        ganancia = p.reinvertir ? capital * (p.pct / 100) : gananciaFija;
        capital += ganancia;
        simple += gananciaFija;
      }
      // Si no es operable, capital y simple se quedan igual: tramo plano.

      filas.push({
        i: i + 1,
        fecha: fecha,
        dow: Cal.NOMBRES_DIA[Cal.diaSemana(fecha)],
        operable: op,
        ganancia: ganancia,
        capital: capital,
        simple: simple,
        opAcum: nOp,
        pctAcum: p.capital !== 0 ? ((capital - p.capital) / p.capital) * 100 : 0
      });
    }
    return filas;
  }

  function pintarKPIs(p, filas) {
    const m = Store.get('moneda', 'EUR');
    const final = filas.length ? filas[filas.length - 1].capital : p.capital;
    const nOp = filas.filter(function (f) { return f.operable; }).length;
    const ganancia = final - p.capital;
    const pct = p.capital !== 0 ? (ganancia / p.capital) * 100 : 0;

    $('ci-final').textContent = Fmt.money(final, m);

    const g = $('ci-ganancia');
    g.textContent = Fmt.money(ganancia, m);
    g.className = Fmt.signClass(ganancia);

    const c = $('ci-crecimiento');
    c.textContent = Fmt.pct(pct);
    c.className = Fmt.signClass(pct);

    $('ci-dias-op').textContent = nOp + ' / ' + filas.length;

    const fin = filas.length ? filas[filas.length - 1].fecha : p.inicio;
    $('ci-resumen').textContent =
      'Del ' + Fmt.fecha(p.inicio) + ' al ' + Fmt.fecha(fin) + ': ' +
      filas.length + ' días de calendario, de los cuales ' + nOp +
      ' son operables y ' + (filas.length - nOp) + ' no. El ' +
      Fmt.num(p.pct, 2) + '% se aplica únicamente en los ' + nOp + ' días operables' +
      (p.reinvertir ? ', reinvirtiendo las ganancias.' : ', sin reinvertir (interés simple).');
  }

  function pintarTabla(filas) {
    const tbody = document.querySelector('#tabla-compuesto tbody');
    const m = Store.get('moneda', 'EUR');
    const frag = document.createDocumentFragment();
    const visibles = filas.slice(0, MAX_FILAS_TABLA);

    visibles.forEach(function (f) {
      const tr = document.createElement('tr');
      if (!f.operable) tr.className = 'row-noop';

      [
        [String(f.i), ''],
        [Fmt.fecha(f.fecha), ''],
        [f.dow, 'dim'],
        [f.operable ? 'Sí' : 'No', f.operable ? 'pos' : 'dim'],
        [Fmt.money(f.capital, m), ''],
        [f.operable ? Fmt.money(f.ganancia, m) : '—', f.operable ? Fmt.signClass(f.ganancia) : 'dim'],
        [Fmt.pct(f.pctAcum), Fmt.signClass(f.pctAcum)]
      ].forEach(function (par) {
        const td = document.createElement('td');
        td.textContent = par[0];
        if (par[1]) td.className = par[1];
        tr.appendChild(td);
      });
      frag.appendChild(tr);
    });

    if (filas.length > visibles.length) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.colSpan = 7;
      td.style.textAlign = 'center';
      td.className = 'hint';
      td.textContent = 'Mostrando los primeros ' + MAX_FILAS_TABLA + ' de ' + filas.length +
        ' días. Exporta a CSV para verlos todos.';
      tr.appendChild(td);
      frag.appendChild(tr);
    }

    tbody.innerHTML = '';
    tbody.appendChild(frag);
  }

  function pintarGrafico(p, filas) {
    if (!chart) chart = new LineChart($('chart-compuesto'));
    const m = Store.get('moneda', 'EUR');

    chart.render({
      labels: [Fmt.fechaCorta(p.inicio)].concat(filas.map(function (f) {
        return Fmt.fechaCorta(f.fecha);
      })),
      format: function (v) { return Fmt.money(v, m); },
      extra: function (i) {
        if (i === 0) return 'Inicio de la proyección';
        const f = filas[i - 1];
        return (f.operable ? '● Operable' : '○ No operable') + ' · ' + f.dow +
          ' · día ' + f.i + ' (' + f.opAcum + ' operables acum.)';
      },
      series: [
        {
          name: 'Compuesto', color: '#6f8fac', fill: true, baseline: p.capital,
          values: [p.capital].concat(filas.map(function (f) { return f.capital; })),
          // Sólo se marcan los días NO operables, para que se vean los tramos planos.
          pointColors: [null].concat(filas.map(function (f) {
            return f.operable ? null : '#7c8698';
          }))
        },
        {
          name: 'Simple', color: '#7c8698', dashed: true,
          values: [p.capital].concat(filas.map(function (f) { return f.simple; }))
        }
      ]
    });
  }

  function correr() {
    const p = leerParams();
    const filas = simular(p);
    ultima = filas;
    ultimoP = p;

    Store.set('compuesto', {
      capital: p.capital, pct: p.pct, dias: p.dias, inicio: p.inicio,
      dow: p.dow, feriados: $('ci-feriados').value, reinvertir: p.reinvertir
    });

    pintarKPIs(p, filas);
    pintarTabla(filas);
    pintarGrafico(p, filas);
  }

  function exportar() {
    if (!ultima.length) correr();
    exportCSV(
      'kronos-interes-compuesto.csv',
      ['#', 'Fecha', 'Dia semana', 'Operable', 'Ganancia', 'Capital',
       '% acumulado', 'Dias operables acum.', 'Capital simple'],
      ultima.map(function (f) {
        return [f.i, f.fecha, f.dow, f.operable ? 'Si' : 'No',
                f.ganancia.toFixed(2), f.capital.toFixed(2),
                f.pctAcum.toFixed(4), f.opAcum, f.simple.toFixed(2)];
      })
    );
  }

  function sincronizarPct(desde) {
    const range = $('ci-pct-range'), num = $('ci-pct');
    if (desde === 'range') {
      num.value = range.value;
    } else {
      const v = Number(num.value) || 0;
      // el slider sólo cubre -5..10; fuera de ese rango se queda en el extremo
      range.value = Math.min(Math.max(v, Number(range.min)), Number(range.max));
    }
    $('ci-pct-out').textContent = Fmt.num(Number(num.value) || 0, 2) + '%';
  }

  function init() {
    // Se toleran ajustes guardados por versiones anteriores: cada campo cae a
    // su valor por defecto si falta o no es válido.
    const g = Store.get('compuesto', null) || {};
    const num = function (v, def) { return (v != null && isFinite(Number(v))) ? Number(v) : def; };

    $('ci-capital').value = num(g.capital, Store.get('inicial', 1000));
    $('ci-pct').value = num(g.pct, 4);
    $('ci-dias').value = Math.min(Math.max(num(g.dias, 30), 1), MAX_DIAS);
    $('ci-fecha').value = /^\d{4}-\d{2}-\d{2}$/.test(g.inicio) ? g.inicio : hoyISO();
    $('ci-feriados').value = typeof g.feriados === 'string' ? g.feriados : '';
    $('ci-reinvertir').checked = g.reinvertir !== false;
    construirDOW(Array.isArray(g.dow) && g.dow.length ? g.dow : [0, 1, 2, 3, 4]);
    sincronizarPct('num');

    $('ci-pct-range').addEventListener('input', function () { sincronizarPct('range'); correr(); });
    $('ci-pct').addEventListener('input', function () { sincronizarPct('num'); correr(); });
    ['ci-capital', 'ci-dias', 'ci-feriados'].forEach(function (id) {
      $(id).addEventListener('input', correr);
    });
    $('ci-fecha').addEventListener('change', correr);
    $('ci-reinvertir').addEventListener('change', correr);
    $('ci-simular').addEventListener('click', correr);
    $('ci-export').addEventListener('click', exportar);

    correr();
  }

  window.Compound = { init: init, run: correr };
})();
