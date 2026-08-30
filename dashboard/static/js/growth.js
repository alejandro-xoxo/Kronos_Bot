/* Sección 1 — Crecimiento del capital + contador de días del plan.
   Los registros se guardan como {id, fecha, tipo, valor, operable, nota} y la
   cadena de capitales se recalcula al vuelo, de modo que cambiar el capital
   inicial reajusta correctamente los registros introducidos como porcentaje.

   Días operables: un registro marcado como no operable representa un día en
   que no se operó (fin de semana, feriado, decisión propia). Se mantiene en
   el historial —el capital de ese día sigue siendo el mismo— pero no cuenta
   para la media por día operable ni se dibuja como día operado. */
(function () {
  const $ = function (id) { return document.getElementById(id); };

  const state = {
    inicio: Store.get('inicio', hoyISO()),
    inicial: Store.get('inicial', 1000),
    moneda: Store.get('moneda', 'EUR'),
    registros: Store.get('registros', [])
  };

  let chart = null;
  // true cuando /api/registros respondió con datos reales de Kronos_Bot —
  // a partir de ahí los registros se generan solos (daily_pnl, ver
  // db/schema.sql) y la carga/edición manual queda deshabilitada para no
  // pisar datos que de todas formas se van a sobreescribir en el próximo
  // sync. Si el fetch falla (ej. demo estática en GitHub Pages, sin
  // backend), sigue funcionando 100% en localStorage como siempre.
  let backendConnected = false;
  let lastCapitalReal = null;

  function guardar() {
    Store.set('inicio', state.inicio);
    Store.set('inicial', state.inicial);
    Store.set('moneda', state.moneda);
    Store.set('registros', state.registros);
  }

  /* Ordena por fecha y calcula capital, delta y porcentajes de cada fila. */
  function calcular() {
    const base = Number(state.inicial) || 0;
    const orden = state.registros.slice().sort(function (a, b) {
      if (a.fecha === b.fecha) return a.id - b.id;
      return a.fecha < b.fecha ? -1 : 1;
    });

    let prev = base;
    let nOp = 0;
    return orden.map(function (r) {
      const operable = r.operable !== false;
      // En un día no operable el capital no se mueve, salvo que se haya
      // registrado explícitamente un capital distinto (p. ej. un ingreso).
      const capital = r.tipo === 'pct'
        ? prev * (1 + (Number(r.valor) || 0) / 100)
        : (Number(r.valor) || 0);
      const delta = capital - prev;
      const pctPeriodo = prev !== 0 ? (delta / prev) * 100 : 0;
      const pctAcum = base !== 0 ? ((capital - base) / base) * 100 : 0;
      if (operable) nOp++;
      prev = capital;
      return {
        id: r.id, fecha: r.fecha, nota: r.nota || '', operable: operable,
        diaPlan: Cal.diffDias(state.inicio, r.fecha) + 1,
        capital: capital, delta: delta,
        pctPeriodo: pctPeriodo, pctAcum: pctAcum,
        opAcum: nOp, _fromBackend: !!r._fromBackend
      };
    });
  }

  function pintarContador(filas) {
    const hoy = hoyISO();
    const transcurridos = Cal.diffDias(state.inicio, hoy);   // puede ser negativo
    const diaPlan = transcurridos + 1;

    $('d-dia').textContent = diaPlan >= 1
      ? 'Día ' + diaPlan + ' desde el inicio'
      : 'El plan empieza en ' + Math.abs(transcurridos) + ' día(s)';

    $('d-desde').textContent = 'Inicio: ' + Fmt.fecha(state.inicio) +
      ' · Hoy: ' + Fmt.fecha(hoy);

    const calendario = Math.max(transcurridos, 0);
    const operables = filas.filter(function (f) { return f.operable; }).length;
    const noOperables = filas.length - operables;

    $('d-calendario').textContent = calendario;
    $('d-operables').textContent = operables;
    $('d-no-operables').textContent = noOperables;

    // Días del calendario transcurridos que aún no tienen ningún registro.
    const conRegistro = {};
    filas.forEach(function (f) { conRegistro[f.fecha] = 1; });
    let sin = 0;
    for (let i = 1; i <= calendario; i++) {
      if (!conRegistro[Cal.sumarDias(state.inicio, i)]) sin++;
    }
    $('d-sin-registro').textContent = sin;
  }

  function pintarKPIs(filas) {
    const base = Number(state.inicial) || 0;
    const m = state.moneda;
    const ultimo = filas.length ? filas[filas.length - 1] : null;
    const actual = ultimo ? ultimo.capital : base;
    const ganancia = actual - base;
    const pct = base !== 0 ? (ganancia / base) * 100 : 0;

    $('k-inicial').textContent = Fmt.money(base, m);
    $('k-actual').textContent = Fmt.money(actual, m);

    const g = $('k-ganancia');
    g.textContent = Fmt.money(ganancia, m);
    g.className = Fmt.signClass(ganancia);

    const p = $('k-pct');
    p.textContent = Fmt.pct(pct);
    p.className = Fmt.signClass(pct);

    // Media geométrica: (capital_final / capital_base)^(1/n) - 1
    const media = function (n) {
      if (!n || base <= 0 || actual <= 0) return null;
      return (Math.pow(actual / base, 1 / n) - 1) * 100;
    };
    const setMedia = function (id, v) {
      const el = $(id);
      el.textContent = v == null ? '—' : Fmt.pct(v, 3);
      el.className = v == null ? '' : Fmt.signClass(v);
    };

    const calendario = Math.max(Cal.diffDias(state.inicio, hoyISO()), 0);
    const operables = filas.filter(function (f) { return f.operable; }).length;
    setMedia('k-media-cal', media(calendario));
    setMedia('k-media-op', media(operables));
  }

  function pintarTabla(filas) {
    const tbody = document.querySelector('#tabla-crecimiento tbody');
    const vacio = $('empty-crecimiento');
    tbody.innerHTML = '';
    vacio.style.display = filas.length ? 'none' : 'block';

    const m = state.moneda;
    filas.forEach(function (f) {
      const tr = document.createElement('tr');
      if (!f.operable) tr.className = 'row-noop';

      const c = function (txt, cls) {
        const td = document.createElement('td');
        td.textContent = txt;
        if (cls) td.className = cls;
        tr.appendChild(td);
      };

      c(Fmt.fecha(f.fecha) + ' · ' + Cal.NOMBRES_DIA[Cal.diaSemana(f.fecha)]);
      c(f.diaPlan >= 1 ? 'D' + f.diaPlan : '—');
      c(f.operable ? 'Sí' : 'No', f.operable ? 'pos' : 'dim');
      c(Fmt.money(f.capital, m));
      c(Fmt.money(f.delta, m), Fmt.signClass(f.delta));
      c(Fmt.pct(f.pctPeriodo), Fmt.signClass(f.pctPeriodo));
      c(Fmt.pct(f.pctAcum), Fmt.signClass(f.pctAcum));
      c(f.nota);

      const tdDel = document.createElement('td');
      const btn = document.createElement('button');
      btn.className = 'del';
      btn.type = 'button';
      btn.textContent = '×';
      btn.title = f._fromBackend
        ? 'Registro real (daily_pnl) — no se puede borrar'
        : 'Eliminar registro';
      btn.setAttribute('aria-label', 'Eliminar registro del ' + Fmt.fecha(f.fecha));
      if (f._fromBackend) btn.style.opacity = '0.35';
      btn.addEventListener('click', function () { eliminar(f.id); });
      tdDel.appendChild(btn);
      tr.appendChild(tdDel);

      tbody.appendChild(tr);
    });
  }

  function pintarGrafico(filas) {
    if (!chart) chart = new LineChart($('chart-crecimiento'));
    const base = Number(state.inicial) || 0;
    const m = state.moneda;

    // El punto 0 es el inicio del plan; a partir de ahí, un punto por registro
    // coloreado según si ese día fue operable o no.
    chart.render({
      labels: ['Inicio'].concat(filas.map(function (f) { return Fmt.fechaCorta(f.fecha); })),
      format: function (v) { return Fmt.money(v, m); },
      extra: function (i) {
        if (i === 0) return 'Inicio del plan';
        const f = filas[i - 1];
        return (f.operable ? '● Día operado' : '○ No operable') +
          (f.diaPlan >= 1 ? ' · Día ' + f.diaPlan : '');
      },
      series: [{
        name: 'Capital',
        color: '#6f8fac',
        fill: true,
        baseline: base,
        values: [base].concat(filas.map(function (f) { return f.capital; })),
        pointColors: ['#6f8fac'].concat(filas.map(function (f) {
          return f.operable ? '#6f8fac' : '#7c8698';
        }))
      }]
    });
  }

  function render() {
    const filas = calcular();
    pintarContador(filas);
    pintarKPIs(filas);
    pintarTabla(filas);
    pintarGrafico(filas);
    // pintarKPIs() recién calculó "Capital actual" reconstruido desde
    // el histórico (daily_pnl) — si ya tenemos el balance real en vivo
    // (sync periódico, ver syncFromBackend), lo reaplicamos encima acá
    // mismo. Sin esto, cada vez que se vuelve a esta sección (o
    // cualquier acción dispara render()) el KPI se pisaba con el valor
    // reconstruido y perdía el balance real (bug reportado 2026-08-30:
    // "al cambiar de página se cambia el capital, no refleja el real").
    if (lastCapitalReal != null) pintarCapitalReal(lastCapitalReal);
    // Sincroniza el calendario si existe
    if (window.CalTrader) CalTrader.render();
    return filas;
  }

  function eliminar(id) {
    const registro = state.registros.find(function (r) { return r.id === id; });
    if (registro && registro._fromBackend) {
      flash($('msg-crecimiento'), 'Este registro viene de una señal cerrada real — no se puede borrar (va a volver a aparecer en el próximo sync).', 'error');
      return;
    }
    state.registros = state.registros.filter(function (r) { return r.id !== id; });
    guardar();
    render();
  }

  function agregar() {
    const fecha = $('reg-fecha').value || hoyISO();
    const tipo = $('reg-tipo').value;
    const valorRaw = $('reg-valor').value;
    const msg = $('msg-crecimiento');

    if (valorRaw === '' || !isFinite(Number(valorRaw))) {
      flash(msg, 'Introduce un valor numérico válido.', 'error');
      return;
    }
    const valor = Number(valorRaw);
    if (tipo === 'capital' && valor < 0) {
      flash(msg, 'El capital del día no puede ser negativo.', 'error');
      return;
    }

    state.registros.push({
      id: Date.now() + Math.floor(Math.random() * 1000),
      fecha: fecha,
      tipo: tipo,
      valor: valor,
      operable: $('reg-operable').checked,
      nota: $('reg-nota').value.trim()
    });
    guardar();
    render();

    // Prepara el formulario para el día siguiente.
    $('reg-fecha').value = Cal.sumarDias(fecha, 1);
    autoOperable();
    $('reg-valor').value = '';
    $('reg-nota').value = '';
    flash(msg, 'Registro agregado.', 'ok');
  }

  function exportar() {
    const filas = calcular();
    if (!filas.length) {
      flash($('msg-crecimiento'), 'No hay registros que exportar.', 'error');
      return;
    }
    exportCSV(
      'kronos-crecimiento.csv',
      ['Fecha', 'Dia semana', 'Dia del plan', 'Operable', 'Capital',
       'Delta periodo', '% periodo', '% acumulado', 'Dias operables acum.', 'Nota'],
      filas.map(function (f) {
        return [f.fecha, Cal.NOMBRES_DIA[Cal.diaSemana(f.fecha)], f.diaPlan,
                f.operable ? 'Si' : 'No', f.capital.toFixed(2), f.delta.toFixed(2),
                f.pctPeriodo.toFixed(4), f.pctAcum.toFixed(4), f.opAcum, f.nota];
      })
    );
  }

  function resetear() {
    if (!confirm('¿Borrar la configuración del plan y todos los registros de crecimiento? Esta acción no se puede deshacer.')) return;
    state.registros = [];
    state.inicial = 1000;
    state.inicio = hoyISO();
    Store.remove('registros');
    Store.remove('inicial');
    Store.remove('inicio');
    $('capital-inicial').value = state.inicial;
    $('fecha-inicio').value = state.inicio;
    $('reg-fecha').value = state.inicio;
    autoOperable();
    render();
    flash($('msg-crecimiento'), 'Datos reseteados.', 'ok');
  }

  function actualizarEtiquetaValor() {
    const tipo = $('reg-tipo').value;
    $('reg-valor-label').textContent = tipo === 'pct' ? '% ganancia/pérdida del día' : 'Capital del día';
    $('reg-valor').placeholder = tipo === 'pct' ? '4' : '1040';
  }

  /* Sugiere "no operable" cuando la fecha elegida cae en sábado o domingo. */
  function autoOperable() {
    const f = $('reg-fecha').value;
    if (!f) return;
    $('reg-operable').checked = Cal.diaSemana(f) < 5;
  }

  /* Sobreescribe el KPI "Capital actual" (y ganancia/% derivados de él)
     con el balance real en vivo de la cuenta, en vez del último valor
     reconstruido a partir de señales cerradas — ver nota en
     syncFromBackend(). No toca la tabla/gráfico/calendario, que siguen
     mostrando el histórico día a día tal cual está en daily_pnl. */
  function pintarCapitalReal(actual) {
    lastCapitalReal = actual;
    const base = Number(state.inicial) || 0;
    const m = state.moneda;
    const ganancia = actual - base;
    const pct = base !== 0 ? (ganancia / base) * 100 : 0;

    $('k-actual').textContent = Fmt.money(actual, m);
    const g = $('k-ganancia');
    g.textContent = Fmt.money(ganancia, m);
    g.className = Fmt.signClass(ganancia);
    const p = $('k-pct');
    p.textContent = Fmt.pct(pct);
    p.className = Fmt.signClass(pct);
  }

  /* Avisa que hay backend conectado — ya NO deshabilita nada (decisión
     explícita del usuario, 2026-08-30: quiere poder seguir agregando/
     editando registros a mano incluso con datos reales sincronizados).
     Los registros que vienen de daily_pnl quedan marcados con
     _fromBackend (ver syncFromBackend) para que no se puedan borrar
     desde la UI y para que el próximo sync los pueda refrescar sin
     tocar los que el usuario cargó a mano. */
  function avisarConexionBackend() {
    flash(
      $('msg-crecimiento'),
      'Conectado a Kronos_Bot — las señales cerradas se agregan solas al historial; podés seguir agregando o corrigiendo registros a mano, no se pisan entre sí.',
      'ok'
    );
  }

  /* Intenta traer los registros reales desde el backend de Kronos_Bot
     (GET /api/registros, ver dashboard/main.py). Si el fetch falla (ej.
     demo estática en GitHub Pages, sin backend detrás), no hace nada y
     el módulo sigue funcionando 100% con localStorage como hasta ahora —
     mismo comportamiento híbrido descrito en
     PVG_kronos/docs/INTEGRACION_KRONOS_BOT.md.

     Merge, no reemplazo: los registros manuales que el usuario ya
     cargó (sin _fromBackend) se conservan tal cual; los que vienen del
     backend se refrescan por completo en cada sync (se sacan los
     _fromBackend viejos y se ponen los nuevos), así una señal que
     todavía no había cerrado la vez anterior aparece sin duplicar
     nada. */
  function syncFromBackend() {
    if (typeof fetch !== 'function') return;
    fetch('/api/registros')
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !Array.isArray(data.registros)) return;
        backendConnected = true;
        if (data.capital_inicial_plan != null && Store.get('inicial', null) == null) {
          // Solo la primera vez (si el usuario nunca configuró un
          // capital inicial propio) — no pisar un valor que el
          // usuario ya haya elegido a mano en una sesión anterior.
          state.inicial = Number(data.capital_inicial_plan);
          $('capital-inicial').value = state.inicial;
          Store.set('inicial', state.inicial);
        }
        const manuales = state.registros.filter(function (r) { return !r._fromBackend; });
        const reales = data.registros.map(function (r) {
          return Object.assign({}, r, { _fromBackend: true });
        });
        state.registros = manuales.concat(reales);
        // calendar.js lee 'registros'/'inicial' directo de Store, no del
        // estado en memoria de este módulo — hay que persistirlos acá
        // para que el Calendario también refleje los datos reales.
        Store.set('registros', state.registros);
        avisarConexionBackend();
        render();
        // "Capital actual" con el balance real en vivo (capital_real,
        // sincronizado cada 5s desde el EA — ver
        // n8n-workflows/split-dev/09-sync-capital-real.json), no con el
        // histórico reconstruido de daily_pnl: puede ir un paso adelante
        // si hay operaciones abiertas o cambios de balance que todavía
        // no se reflejaron como señal cerrada.
        if (data.capital_real != null) pintarCapitalReal(Number(data.capital_real));
      })
      .catch(function () { /* sin backend disponible — sigue en localStorage */ });
  }

  function init() {
    // Primera configuración: fecha de inicio por defecto = hoy.
    $('fecha-inicio').value = state.inicio;
    $('capital-inicial').value = state.inicial;
    $('moneda-display').value = state.moneda;

    // El formulario arranca en el primer día sin registrar del plan.
    const ultimo = state.registros.reduce(function (max, r) {
      return !max || r.fecha > max ? r.fecha : max;
    }, null);
    $('reg-fecha').value = ultimo ? Cal.sumarDias(ultimo, 1) : state.inicio;
    autoOperable();
    actualizarEtiquetaValor();

    $('fecha-inicio').addEventListener('change', function () {
      state.inicio = this.value || hoyISO();
      guardar();
      render();
    });
    $('capital-inicial').addEventListener('input', function () {
      state.inicial = Number(this.value) || 0;
      guardar();
      render();
    });
    $('moneda-display').addEventListener('change', function () {
      state.moneda = this.value;
      guardar();
      render();
      Compound.run();   // la simulación usa la misma moneda
    });
    $('reg-tipo').addEventListener('change', actualizarEtiquetaValor);
    $('reg-fecha').addEventListener('change', autoOperable);
    $('reg-valor').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') agregar();
    });
    $('btn-add').addEventListener('click', agregar);
    $('btn-export').addEventListener('click', exportar);
    $('btn-reset').addEventListener('click', resetear);

    // Copia de seguridad JSON para transferir entre dispositivos
    $('btn-backup-export').addEventListener('click', function () {
      const data = Store.exportBackup();
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'kronos-backup-' + hoyISO() + '.json';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      flash($('msg-crecimiento'), 'Copia de seguridad exportada.', 'ok');
    });

    $('btn-backup-import').addEventListener('click', function () {
      $('input-backup-file').click();
    });

    $('input-backup-file').addEventListener('change', function (e) {
      const file = e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = function (evt) {
        try {
          const parsed = JSON.parse(evt.target.result);
          if (Store.importBackup(parsed)) {
            state.inicio = Store.get('inicio', hoyISO());
            state.inicial = Store.get('inicial', 1000);
            state.moneda = Store.get('moneda', 'EUR');
            state.registros = Store.get('registros', []);
            $('fecha-inicio').value = state.inicio;
            $('capital-inicial').value = state.inicial;
            $('moneda-display').value = state.moneda;
            render();
            flash($('msg-crecimiento'), 'Datos importados correctamente.', 'ok');
          } else {
            flash($('msg-crecimiento'), 'Archivo de respaldo no válido.', 'error');
          }
        } catch (err) {
          flash($('msg-crecimiento'), 'Error al leer el archivo JSON.', 'error');
        }
      };
      reader.readAsText(file);
      e.target.value = '';
    });

    render();
    syncFromBackend();
  }

  window.Growth = { init: init, render: render };
})();
