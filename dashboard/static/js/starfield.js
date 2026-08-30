/* Capa de partículas sobre la imagen de fondo.
   Discreta a propósito: la profundidad la aporta la imagen de galaxia, y estas
   estrellas sólo añaden un movimiento lento que da sensación de calma.
   Tres capas a distinta velocidad (parallax) con parpadeo suave.

   Rendimiento: densidad proporcional al área con techo duro, un único
   requestAnimationFrame, DPR limitado, pausa al ocultarse la pestaña y
   pintado estático si el sistema pide menos movimiento. */
(function () {
  const canvas = document.getElementById('starfield');
  if (!canvas) return;
  const ctx = canvas.getContext('2d', { alpha: true });

  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Tonos sobrios: blanco frío, plata y un dorado muy tenue de acento.
  // La capa lejana es diminuta y casi transparente; la cercana, algo más viva.
  const LAYERS = [
    { speed: 0.004, size: [0.4, 0.9], alpha: [0.14, 0.30], density: 1 / 20000, tint: '226,232,242' },
    { speed: 0.010, size: [0.6, 1.2], alpha: [0.20, 0.42], density: 1 / 34000, tint: '182,190,205' },
    { speed: 0.020, size: [0.9, 1.6], alpha: [0.26, 0.52], density: 1 / 72000, tint: '201,168,106' }
  ];
  const MAX_STARS = 260;   // techo duro: la imagen de fondo ya aporta densidad
  let stars = [];
  let w = 0, h = 0, dpr = 1;
  let rafId = null, last = 0, running = false;

  function rand(a, b) { return a + Math.random() * (b - a); }

  function build() {
    const area = w * h;
    stars = [];
    let budget = MAX_STARS;
    LAYERS.forEach(function (L) {
      const n = Math.min(Math.round(area * L.density), budget);
      budget -= n;
      for (let i = 0; i < n; i++) {
        stars.push({
          x: Math.random() * w,
          y: Math.random() * h,
          r: rand(L.size[0], L.size[1]),
          base: rand(L.alpha[0], L.alpha[1]),
          speed: L.speed,
          tint: L.tint,
          // parpadeo lento, con fase y frecuencia propias
          ph: Math.random() * Math.PI * 2,
          fq: rand(0.15, 0.55)
        });
      }
    });
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);   // cap DPR
    w = window.innerWidth;
    h = window.innerHeight;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    build();
    if (reduced) draw(0);   // pintado estático
  }

  function draw(t) {
    ctx.clearRect(0, 0, w, h);
    for (let i = 0; i < stars.length; i++) {
      const s = stars[i];
      // amplitud de parpadeo contenida: nunca desaparece del todo
      const tw = reduced ? 1 : 0.78 + 0.22 * Math.sin(t * 0.001 * s.fq + s.ph);
      ctx.globalAlpha = s.base * tw;
      ctx.fillStyle = 'rgb(' + s.tint + ')';
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  function step(now) {
    const dt = Math.min(now - last, 50);   // evita saltos tras pausas largas
    last = now;
    for (let i = 0; i < stars.length; i++) {
      const s = stars[i];
      s.x -= s.speed * dt;                 // deriva horizontal muy lenta
      if (s.x < -3) { s.x = w + 3; s.y = Math.random() * h; }
    }
    draw(now);
    rafId = requestAnimationFrame(step);
  }

  function start() {
    if (running || reduced) return;
    running = true;
    last = performance.now();
    rafId = requestAnimationFrame(step);
  }
  function stop() {
    running = false;
    if (rafId) cancelAnimationFrame(rafId);
    rafId = null;
  }

  let rt;
  window.addEventListener('resize', function () {
    clearTimeout(rt);
    rt = setTimeout(resize, 180);
  });
  document.addEventListener('visibilitychange', function () {
    document.hidden ? stop() : start();
  });

  resize();
  start();
})();
