/* Arranque y navegación por pestañas. */
(function () {
  const tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
  const paneles = {
    crecimiento: document.getElementById('tab-crecimiento'),
    compuesto: document.getElementById('tab-compuesto'),
    calendario: document.getElementById('tab-calendario'),
    control: document.getElementById('tab-control'),
    conversor: document.getElementById('tab-conversor')
  };

  function mostrar(nombre) {
    Object.keys(paneles).forEach(function (k) {
      paneles[k].classList.toggle('hidden', k !== nombre);
    });
    tabs.forEach(function (t) {
      const activo = t.dataset.tab === nombre;
      t.classList.toggle('is-active', activo);
      t.setAttribute('aria-selected', activo ? 'true' : 'false');
    });
    Store.set('tab', nombre);
    if (location.hash.slice(1) !== nombre) history.replaceState(null, '', '#' + nombre);

    // Los canvas ocultos miden 0 px: hay que redibujar al mostrarlos.
    if (nombre === 'crecimiento') Growth.render();
    if (nombre === 'compuesto') Compound.run();
    if (nombre === 'calendario') CalTrader.render();
    if (nombre === 'control') ControlPanel.render();
  }

  tabs.forEach(function (t) {
    t.addEventListener('click', function () { mostrar(t.dataset.tab); });
  });

  Growth.init();
  Compound.init();
  FX.init();
  CalTrader.init();
  ControlPanel.init();

  const inicial = location.hash.slice(1) || Store.get('tab', 'crecimiento');
  mostrar(paneles[inicial] ? inicial : 'crecimiento');
})();
