/* Persistencia en localStorage + utilidades compartidas (formato, CSV). */
(function () {
  const NS = 'kronos.v1.';

  const Store = {
    get: function (key, fallback) {
      try {
        const raw = localStorage.getItem(NS + key);
        return raw == null ? fallback : JSON.parse(raw);
      } catch (e) {
        console.warn('No se pudo leer', key, e);
        return fallback;
      }
    },
    set: function (key, value) {
      try {
        localStorage.setItem(NS + key, JSON.stringify(value));
        return true;
      } catch (e) {
        console.warn('No se pudo guardar', key, e);
        return false;
      }
    },
    remove: function (key) {
      try { localStorage.removeItem(NS + key); } catch (e) { /* ignorado */ }
    },
    clearAll: function () {
      try {
        Object.keys(localStorage)
          .filter(function (k) { return k.indexOf(NS) === 0; })
          .forEach(function (k) { localStorage.removeItem(k); });
      } catch (e) { /* ignorado */ }
    },
    exportBackup: function () {
      const data = {};
      try {
        Object.keys(localStorage)
          .filter(function (k) { return k.indexOf(NS) === 0; })
          .forEach(function (k) {
            const key = k.replace(NS, '');
            data[key] = JSON.parse(localStorage.getItem(k));
          });
      } catch (e) { console.warn('Error al exportar datos', e); }
      return data;
    },
    importBackup: function (data) {
      if (!data || typeof data !== 'object') return false;
      try {
        Object.keys(data).forEach(function (key) {
          Store.set(key, data[key]);
        });
        return true;
      } catch (e) {
        console.warn('Error al importar datos', e);
        return false;
      }
    }
  };

  const SYMBOLS = { EUR: '€', USD: '$', COP: '$', GBP: '£', JPY: '¥', MXN: '$', ARS: '$', BRL: 'R$', CHF: 'Fr', CAD: '$' };

  const Fmt = {
    money: function (v, cur) {
      if (v == null || !isFinite(v)) return '—';
      cur = cur || 'EUR';
      try {
        return new Intl.NumberFormat('es-ES', {
          style: 'currency', currency: cur,
          minimumFractionDigits: 2, maximumFractionDigits: 2
        }).format(v);
      } catch (e) {
        return (SYMBOLS[cur] || '') + v.toFixed(2) + ' ' + cur;
      }
    },
    num: function (v, dec) {
      if (v == null || !isFinite(v)) return '—';
      return new Intl.NumberFormat('es-ES', {
        minimumFractionDigits: dec == null ? 2 : dec,
        maximumFractionDigits: dec == null ? 2 : dec
      }).format(v);
    },
    pct: function (v, dec) {
      if (v == null || !isFinite(v)) return '—';
      const s = v > 0 ? '+' : '';
      return s + Fmt.num(v, dec == null ? 2 : dec) + '%';
    },
    fecha: function (iso) {
      if (!iso) return '—';
      const p = String(iso).split('-');
      return p.length === 3 ? p[2] + '/' + p[1] + '/' + p[0] : iso;
    },
    fechaCorta: function (iso) {
      if (!iso) return '';
      const p = String(iso).split('-');
      return p.length === 3 ? p[2] + '/' + p[1] : iso;
    },
    signClass: function (v) { return v > 0 ? 'pos' : v < 0 ? 'neg' : ''; }
  };

  /* Descarga un CSV (separador ';' y BOM para que Excel en español lo abra bien). */
  function exportCSV(filename, headers, rows) {
    const esc = function (v) {
      const s = String(v == null ? '' : v);
      return /[";\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    const lines = [headers.map(esc).join(';')]
      .concat(rows.map(function (r) { return r.map(esc).join(';'); }));
    const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  function hoyISO() {
    const d = new Date();
    const p = function (x) { return String(x).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  /* Mensaje efímero en un <p class="hint"> */
  function flash(el, texto, tipo) {
    if (!el) return;
    el.textContent = texto;
    el.className = 'hint ' + (tipo === 'error' ? 'neg' : tipo === 'ok' ? 'pos' : '');
    clearTimeout(el._t);
    el._t = setTimeout(function () { el.textContent = ''; el.className = 'hint'; }, 4000);
  }

  /* ---- utilidades de calendario ----
     Todas las fechas se manejan como cadenas ISO 'YYYY-MM-DD' y se construyen
     con el constructor local Date(y, m-1, d) para evitar el desfase de zona
     horaria que produce new Date('2026-08-28') (que se interpreta como UTC). */

  function isoADate(iso) {
    const p = String(iso).split('-');
    return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
  }

  function dateAIso(d) {
    const p = function (x) { return String(x).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  function sumarDias(iso, n) {
    const d = isoADate(iso);
    d.setDate(d.getDate() + n);
    return dateAIso(d);
  }

  /* Días calendario completos entre dos fechas ISO (b - a). */
  function diffDias(a, b) {
    const MS = 86400000;
    return Math.round((isoADate(b).getTime() - isoADate(a).getTime()) / MS);
  }

  /* Índice de día de la semana con lunes = 0 … domingo = 6
     (getDay() nativo usa domingo = 0). */
  function diaSemana(iso) {
    return (isoADate(iso).getDay() + 6) % 7;
  }

  const NOMBRES_DIA = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

  window.Cal = {
    isoADate: isoADate,
    dateAIso: dateAIso,
    sumarDias: sumarDias,
    diffDias: diffDias,
    diaSemana: diaSemana,
    NOMBRES_DIA: NOMBRES_DIA
  };

  window.Store = Store;
  window.Fmt = Fmt;
  window.exportCSV = exportCSV;
  window.hoyISO = hoyISO;
  window.flash = flash;
})();
