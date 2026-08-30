/* Sección — Calendario de Trader
   Muestra un calendario mensual con la ganancia/pérdida de cada día,
   coloreando en verde los días positivos, rojo los negativos y gris
   los no operables. El total del mes aparece arriba a la derecha.
   Consume los mismos registros que Growth (Store 'registros' + 'inicial'). */
(function () {
  const $ = function (id) { return document.getElementById(id); };

  /* Año y mes que se están visualizando — se guarda como dos números
     separados para evitar bugs de clausura al reasignar el objeto. */
  var vYear  = new Date().getFullYear();
  var vMonth = new Date().getMonth() + 1;   // 1-12

  /* Construye un mapa  'YYYY-MM-DD' → {delta, capital, operable, nota, pct}
     a partir de los registros de crecimiento. */
  function buildMap() {
    var registros = Store.get('registros', []);
    var base = Number(Store.get('inicial', 1000)) || 0;

    var orden = registros.slice().sort(function (a, b) {
      if (a.fecha < b.fecha) return -1;
      if (a.fecha > b.fecha) return 1;
      return 0;
    });

    var mapa = {};
    var prev = base;
    orden.forEach(function (r) {
      var capital = r.tipo === 'pct'
        ? prev * (1 + (Number(r.valor) || 0) / 100)
        : (Number(r.valor) || 0);
      var delta = capital - prev;
      mapa[r.fecha] = {
        delta:    delta,
        capital:  capital,
        operable: r.operable !== false,
        nota:     r.nota || '',
        pct:      prev !== 0 ? (delta / prev) * 100 : 0
      };
      prev = capital;
    });
    return mapa;
  }

  /* Días del mes como array de {iso, dow, dia} */
  function diasDelMes(y, m) {
    var dias  = [];
    var total = new Date(y, m, 0).getDate();   // día 0 del mes m+1 = último día del mes m
    var pad   = function (n) { return String(n).padStart(2, '0'); };
    for (var d = 1; d <= total; d++) {
      var iso = y + '-' + pad(m) + '-' + pad(d);
      dias.push({ iso: iso, dow: Cal.diaSemana(iso), dia: d });
    }
    return dias;
  }

  /* Delta monetario compacto para la celda */
  function fmtDelta(v) {
    if (v == null || !isFinite(v)) return '';
    var sign = v >= 0 ? '+' : '';
    var abs  = Math.abs(v);
    if (abs >= 10000) return sign + (v / 1000).toFixed(1) + 'K';
    if (abs >= 1000)  return sign + (v / 1000).toFixed(2) + 'K';
    return sign + v.toFixed(2);
  }

  /* ------------------------------------------------------------------ */
  /*  Render principal                                                    */
  /* ------------------------------------------------------------------ */
  function render() {
    var y      = vYear;
    var m      = vMonth;
    var moneda = Store.get('moneda', 'EUR');
    var mapa   = buildMap();
    var dias   = diasDelMes(y, m);
    var hoy    = hoyISO();   // siempre fresco: YYYY-MM-DD de hoy real

    var NomMes = [
      'Enero','Febrero','Marzo','Abril','Mayo','Junio',
      'Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'
    ];

    /* ── Título ── */
    $('cal-titulo').textContent = NomMes[m - 1] + ' ' + y;

    /* ── KPIs del mes ── */
    var totalDelta = 0, diasOp = 0, mejorDelta = null, peorDelta = null;
    dias.forEach(function (d) {
      var reg = mapa[d.iso];
      if (!reg || !reg.operable) return;
      totalDelta += reg.delta;
      diasOp++;
      if (mejorDelta === null || reg.delta > mejorDelta) mejorDelta = reg.delta;
      if (peorDelta  === null || reg.delta < peorDelta)  peorDelta  = reg.delta;
    });

    var elTotal = $('cal-total');
    elTotal.textContent = Fmt.money(totalDelta, moneda);
    elTotal.className   = 'cal-kpi__val ' + (totalDelta >= 0 ? 'pos' : 'neg');

    $('cal-dias-op').textContent = diasOp || '0';

    var elMejor = $('cal-mejor');
    elMejor.textContent = mejorDelta !== null ? Fmt.money(mejorDelta, moneda) : '—';
    elMejor.className   = mejorDelta !== null ? 'cal-kpi__val pos' : 'cal-kpi__val';

    var elPeor = $('cal-peor');
    elPeor.textContent = peorDelta !== null ? Fmt.money(peorDelta, moneda) : '—';
    elPeor.className   = peorDelta !== null ? 'cal-kpi__val neg' : 'cal-kpi__val';

    /* ── Cuadrícula ── */
    var grid = $('cal-grid');
    grid.innerHTML = '';

    /* Obtener el mes y año de hoy para colorear el botón "Hoy" */
    var hoyParts  = hoy.split('-');
    var hoyMesStr = hoyParts[0] + '-' + hoyParts[1];          // "YYYY-MM"
    var mesMostradoStr = y + '-' + String(m).padStart(2,'0'); // "YYYY-MM"
    $('cal-hoy').classList.toggle('cal-nav__hoy--activo', hoyMesStr === mesMostradoStr);

    /* Celdas vacías de relleno hasta el primer día de la semana (Lun=0) */
    var inicioSemana = dias[0].dow;
    for (var i = 0; i < inicioSemana; i++) {
      var vacio = document.createElement('div');
      vacio.className = 'cal-cell cal-cell--empty';
      grid.appendChild(vacio);
    }

    /* Celdas de días reales */
    dias.forEach(function (d) {
      var reg      = mapa[d.iso];
      var esFuturo = d.iso > hoy;
      var esHoy    = d.iso === hoy;

      var cell = document.createElement('div');
      var cls  = 'cal-cell';

      if (esHoy)    cls += ' cal-cell--hoy';
      if (esFuturo) cls += ' cal-cell--futuro';

      if (reg) {
        if (reg.operable) {
          cls += reg.delta >= 0 ? ' cal-cell--pos' : ' cal-cell--neg';
        } else {
          cls += ' cal-cell--noop';
        }
      } else if (!esFuturo && !esHoy) {
        cls += ' cal-cell--sin-dato';
      }

      cell.className = cls;

      /* Número del día */
      var numEl = document.createElement('span');
      numEl.className   = 'cal-cell__num';
      numEl.textContent = d.dia;
      cell.appendChild(numEl);

      /* Contenido según estado */
      if (reg) {
        if (reg.operable) {
          var deltaEl = document.createElement('span');
          deltaEl.className   = 'cal-cell__delta';
          deltaEl.textContent = fmtDelta(reg.delta);
          cell.appendChild(deltaEl);

          var pctEl = document.createElement('span');
          pctEl.className   = 'cal-cell__pct';
          pctEl.textContent = (reg.pct >= 0 ? '+' : '') + reg.pct.toFixed(2) + '%';
          cell.appendChild(pctEl);

          if (reg.nota) {
            var notaEl = document.createElement('span');
            notaEl.className   = 'cal-cell__nota';
            notaEl.textContent = reg.nota;
            cell.appendChild(notaEl);
          }
        } else {
          var stEl = document.createElement('span');
          stEl.className   = 'cal-cell__noop-label';
          stEl.textContent = 'No operable';
          cell.appendChild(stEl);
        }
      }

      grid.appendChild(cell);
    });
  }

  /* ------------------------------------------------------------------ */
  /*  Navegación                                                          */
  /* ------------------------------------------------------------------ */
  function prevMes() {
    vMonth--;
    if (vMonth < 1) { vMonth = 12; vYear--; }
    render();
  }

  function nextMes() {
    vMonth++;
    if (vMonth > 12) { vMonth = 1; vYear++; }
    render();
  }

  function irHoy() {
    var h = new Date();
    vYear  = h.getFullYear();
    vMonth = h.getMonth() + 1;
    render();
  }

  /* ------------------------------------------------------------------ */
  /*  Teclado: ← → para navegar entre meses                             */
  /* ------------------------------------------------------------------ */
  function onKey(e) {
    /* Solo cuando el foco NO está en un input/select/textarea */
    if (['INPUT','SELECT','TEXTAREA'].indexOf(e.target.tagName) !== -1) return;
    /* Solo cuando la pestaña Calendario es visible */
    var sec = document.getElementById('tab-calendario');
    if (!sec || sec.classList.contains('hidden')) return;

    if (e.key === 'ArrowLeft'  || e.key === 'ArrowUp')   { e.preventDefault(); prevMes(); }
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown')  { e.preventDefault(); nextMes(); }
    if (e.key === 'Home')                                  { e.preventDefault(); irHoy();   }
  }

  function init() {
    $('cal-prev').addEventListener('click', prevMes);
    $('cal-next').addEventListener('click', nextMes);
    $('cal-hoy').addEventListener('click',  irHoy);
    document.addEventListener('keydown', onKey);
    render();
  }

  window.CalTrader = { init: init, render: render };
})();
