/* Mini librería de gráficos de línea sobre canvas (sin dependencias).
   Uso:
     const c = new LineChart(canvasEl);
     c.render({ labels:[...], series:[{name, color, values:[...], fill:true}] });
   Redibuja sólo cuando se le pide o cuando cambia el tamaño. */
(function () {
  const CSS = getComputedStyle(document.documentElement);
  const col = function (n, fb) { return (CSS.getPropertyValue(n) || '').trim() || fb; };

  const GRID = 'rgba(196,205,224,0.075)';
  const AXIS = 'rgba(152,161,179,0.85)';
  const FONT = '11px "Inter", ui-sans-serif, system-ui, sans-serif';

  function niceTicks(min, max, count) {
    if (min === max) { min -= 1; max += 1; }
    const raw = (max - min) / count;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const norm = raw / mag;
    const stepN = norm >= 5 ? 10 : norm >= 2 ? 5 : norm >= 1 ? 2 : 1;
    const step = stepN * mag;
    const start = Math.floor(min / step) * step;
    const end = Math.ceil(max / step) * step;
    const ticks = [];
    for (let v = start; v <= end + step * 0.5; v += step) ticks.push(v);
    return ticks;
  }

  function fmtNum(v) {
    const a = Math.abs(v);
    if (a >= 1e9) return (v / 1e9).toFixed(1) + 'B';
    if (a >= 1e6) return (v / 1e6).toFixed(1) + 'M';
    if (a >= 1e4) return (v / 1e3).toFixed(0) + 'k';
    if (a >= 100) return v.toFixed(0);
    return v.toFixed(2);
  }

  function LineChart(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.data = null;
    this.hover = -1;
    const self = this;

    // Redimensionado observado sobre el contenedor
    if (window.ResizeObserver) {
      this._ro = new ResizeObserver(function () { self.draw(); });
      this._ro.observe(canvas.parentElement || canvas);
    } else {
      window.addEventListener('resize', function () { self.draw(); });
    }

    canvas.addEventListener('mousemove', function (e) {
      if (!self.data || !self._geom) return;
      const rect = canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const g = self._geom;
      const n = self.data.labels.length;
      if (n < 1) return;
      let i = Math.round((x - g.left) / (g.w / Math.max(n - 1, 1)));
      i = Math.max(0, Math.min(n - 1, i));
      if (i !== self.hover) { self.hover = i; self.draw(); }
    });
    canvas.addEventListener('mouseleave', function () {
      if (self.hover !== -1) { self.hover = -1; self.draw(); }
    });
  }

  LineChart.prototype.render = function (data) {
    this.data = data;
    this.hover = -1;
    this.draw();
  };

  LineChart.prototype.draw = function () {
    const cv = this.canvas, ctx = this.ctx;
    const box = (cv.parentElement || cv).getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = Math.max(box.width, 1), H = Math.max(box.height, 1);
    cv.width = Math.round(W * dpr);
    cv.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);

    const d = this.data;
    if (!d || !d.series || !d.series.length || !d.labels.length) {
      ctx.fillStyle = AXIS; ctx.font = FONT; ctx.textAlign = 'center';
      ctx.fillText('Sin datos para mostrar', W / 2, H / 2);
      return;
    }

    const pad = { t: 16, r: 14, b: 30, l: 58 };
    const left = pad.l, top = pad.t;
    const w = W - pad.l - pad.r, h = H - pad.t - pad.b;
    if (w <= 10 || h <= 10) return;

    // rango Y
    let min = Infinity, max = -Infinity;
    d.series.forEach(function (s) {
      s.values.forEach(function (v) {
        if (v == null || !isFinite(v)) return;
        if (v < min) min = v;
        if (v > max) max = v;
      });
    });
    if (!isFinite(min)) { min = 0; max = 1; }
    const padY = (max - min) * 0.08 || Math.abs(max || 1) * 0.08;
    const ticks = niceTicks(min - padY, max + padY, 4);
    const yMin = ticks[0], yMax = ticks[ticks.length - 1];

    const n = d.labels.length;
    const dx = n > 1 ? w / (n - 1) : 0;
    const X = function (i) { return left + i * dx; };
    const Y = function (v) { return top + h - ((v - yMin) / (yMax - yMin)) * h; };
    this._geom = { left: left, top: top, w: w, h: h };

    // grilla + eje Y
    ctx.font = FONT; ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    ticks.forEach(function (t) {
      const y = Y(t);
      ctx.strokeStyle = GRID; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(left, Math.round(y) + .5); ctx.lineTo(left + w, Math.round(y) + .5); ctx.stroke();
      ctx.fillStyle = AXIS;
      ctx.fillText(fmtNum(t), left - 8, y);
    });

    // etiquetas X (máx 6, sin solaparse)
    ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = AXIS;
    const stepX = Math.max(1, Math.ceil(n / 6));
    for (let i = 0; i < n; i += stepX) ctx.fillText(String(d.labels[i]), X(i), top + h + 8);
    if ((n - 1) % stepX !== 0 && n > 1) ctx.fillText(String(d.labels[n - 1]), X(n - 1), top + h + 8);

    // series
    const self = this;
    d.series.forEach(function (s) {
      const color = s.color || col('--azul', '#6f8fac');

      if (s.fill) {
        const baseV = Math.min(Math.max(s.baseline != null ? s.baseline : yMin, yMin), yMax);
        const grad = ctx.createLinearGradient(0, top, 0, top + h);
        grad.addColorStop(0, hexA(color, .28));
        grad.addColorStop(1, hexA(color, 0));
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.moveTo(X(0), Y(baseV));
        s.values.forEach(function (v, i) { ctx.lineTo(X(i), Y(v)); });
        ctx.lineTo(X(n - 1), Y(baseV));
        ctx.closePath(); ctx.fill();
      }

      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.lineJoin = 'round'; ctx.lineCap = 'round';
      if (s.dashed) ctx.setLineDash([5, 5]); else ctx.setLineDash([]);
      ctx.shadowColor = hexA(color, .22); ctx.shadowBlur = 5;
      ctx.beginPath();
      s.values.forEach(function (v, i) { i ? ctx.lineTo(X(i), Y(v)) : ctx.moveTo(X(i), Y(v)); });
      ctx.stroke();
      ctx.shadowBlur = 0; ctx.setLineDash([]);

      // Puntos. Con pointColors se pinta un color por punto (null = sin punto),
      // que es como se distinguen los días operables de los no operables.
      if (s.pointColors) {
        if (n <= 400) {
          s.pointColors.forEach(function (pc, i) {
            if (!pc) return;
            ctx.fillStyle = pc;
            ctx.beginPath(); ctx.arc(X(i), Y(s.values[i]), 3, 0, Math.PI * 2); ctx.fill();
          });
        }
      } else if (n <= 40) {
        ctx.fillStyle = color;
        s.values.forEach(function (v, i) {
          ctx.beginPath(); ctx.arc(X(i), Y(v), 2.6, 0, Math.PI * 2); ctx.fill();
        });
      }
    });

    // tooltip
    const hi = this.hover;
    if (hi >= 0 && hi < n) {
      const x = X(hi);
      ctx.strokeStyle = 'rgba(196,205,224,.28)';
      ctx.setLineDash([3, 3]); ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, top + h); ctx.stroke();
      ctx.setLineDash([]);

      let lines = [String(d.labels[hi])].concat(d.series.map(function (s) {
        return s.name + ': ' + (d.format ? d.format(s.values[hi]) : fmtNum(s.values[hi]));
      }));
      if (d.extra) {
        const ex = d.extra(hi);
        if (ex) lines = lines.concat([ex]);
      }
      ctx.font = FONT;
      let bw = 0;
      lines.forEach(function (t) { bw = Math.max(bw, ctx.measureText(t).width); });
      bw += 18;
      const bh = 8 + lines.length * 16;
      let bx = x + 12; if (bx + bw > left + w) bx = x - bw - 12;
      const by = top + 8;

      ctx.fillStyle = 'rgba(12,16,25,.95)';
      ctx.strokeStyle = 'rgba(196,205,224,.16)';
      roundRect(ctx, bx, by, bw, bh, 8); ctx.fill(); ctx.stroke();

      ctx.textAlign = 'left'; ctx.textBaseline = 'top';
      lines.forEach(function (t, i) {
        const s = d.series[i - 1];
        ctx.fillStyle = (i === 0 || !s) ? col('--txt-mute', '#6d768a') : (s.color || '#6f8fac');
        ctx.fillText(t, bx + 9, by + 6 + i * 16);
      });

      d.series.forEach(function (s) {
        ctx.fillStyle = s.color || '#6f8fac';
        ctx.beginPath(); ctx.arc(x, Y(s.values[hi]), 4, 0, Math.PI * 2); ctx.fill();
        ctx.strokeStyle = '#05070c'; ctx.lineWidth = 1.5; ctx.stroke();
      });
    }
  };

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // convierte #rrggbb o rgb() a rgba con alfa
  function hexA(c, a) {
    if (c.charAt(0) === '#') {
      const s = c.length === 4
        ? c.slice(1).split('').map(function (x) { return x + x; }).join('')
        : c.slice(1);
      const num = parseInt(s, 16);
      return 'rgba(' + ((num >> 16) & 255) + ',' + ((num >> 8) & 255) + ',' + (num & 255) + ',' + a + ')';
    }
    return c;
  }

  window.LineChart = LineChart;
  window.chartFmtNum = fmtNum;
})();
