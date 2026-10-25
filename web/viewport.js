(() => {
  // Capture the renderer at construction without editing pinned canvas code.
  // The website centers the first record at startup; a smaller editor tab needs
  // an initial fit. All pan/zoom/drag interactions still belong to the real app.
  let canvas;
  function fit() {
    if (!canvas || canvas.destroyed() || !canvas.nodes().length) return;
    canvas.resize();
    canvas.fit(undefined, 70);
    if (canvas.zoom() > 1) { canvas.zoom(1); canvas.center(); }
  }
  window.cytoscape = new Proxy(window.cytoscape, {
    apply(target, receiver, args) {
      const cy = Reflect.apply(target, receiver, args);
      if (args[0]?.container?.id === 'bulk-canvas-cy') {
        canvas = cy;
        setTimeout(fit, 200);
      }
      return cy;
    },
  });
})();
