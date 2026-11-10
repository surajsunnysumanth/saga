/* No storage of any kind. No network calls or analytics. */
(() => {
  'use strict';
  // Print loads everything: lazy images are skipped by print otherwise.
  window.addEventListener('beforeprint', () => {
    document.querySelectorAll('img[loading="lazy"]').forEach((img) => { img.loading = 'eager'; });
  });

  /* The embedded Wrapped sample is a frame: once focus moves into its document the frame
     element never receives :focus, so mirror focus onto the screen edge to keep a visible
     ring on whatever the keyboard is on. Same-origin frame only (sandbox allow-same-origin)
     and purely cosmetic: without it the sample still reads and scrolls. */
  document.querySelectorAll('iframe.demo-frame').forEach(frame => {
    const screen = frame.closest('.phone-screen');
    if (!screen) return;
    const set = on => () => screen.classList.toggle('is-focused', on);
    frame.addEventListener('focus', set(true));
    frame.addEventListener('blur', set(false));
    const mirror = () => {
      try {
        frame.contentWindow.addEventListener('focus', set(true));
        frame.contentWindow.addEventListener('blur', set(false));
      } catch (_) { /* Not reachable: no ring, nothing else changes. */ }
    };
    frame.addEventListener('load', mirror);
    if (frame.contentDocument && frame.contentDocument.readyState === 'complete') mirror();
  });
})();
