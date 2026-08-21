// Waits for the page to go quiet after an action: no DOM mutations for
// `quietMilliseconds`, or `timeoutMilliseconds` at most. Client-rendered
// pages change long after a click returns; observing the page instead of
// sleeping a fixed beat makes the next snapshot land after the change.
//
// Arguments: quietMilliseconds, timeoutMilliseconds.
// Returns `{ mutations, settled, elapsed }`.
return new Promise((resolve) => {
  const quiet = Math.max(100, Number(quietMilliseconds) || 400);
  const timeout = Math.max(quiet, Number(timeoutMilliseconds) || 3000);
  const started = performance.now();
  let mutations = 0;
  let timer = null;
  let done = false;

  const finish = (settled) => {
    if (done) return;
    done = true;
    observer.disconnect();
    clearTimeout(timer);
    clearTimeout(hardStop);
    resolve(JSON.stringify({ mutations, settled, elapsed: Math.round(performance.now() - started) }));
  };

  const observer = new MutationObserver((records) => {
    // Attribute churn from animations and carousels never settles; only
    // structural and text changes restart the quiet window.
    const meaningful = records.some((record) => record.type !== "attributes"
      || ["hidden", "aria-expanded", "aria-hidden", "open", "disabled", "aria-selected", "aria-checked", "class", "style"].includes(record.attributeName));
    if (!meaningful) return;
    mutations += records.length;
    clearTimeout(timer);
    timer = setTimeout(() => finish(true), quiet);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
  timer = setTimeout(() => finish(true), quiet);
  const hardStop = setTimeout(() => finish(false), timeout);
});
