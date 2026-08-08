return (() => {
  const executed = (message) => JSON.stringify({ ok: true, message });
  const failed = (message) => JSON.stringify({ ok: false, message });
  if (window.__candoaAgentSnapshotID !== snapshotID) {
    return failed("Candoa stopped because the page changed after it was inspected.");
  }
  const distance = Math.max(300, innerHeight * 0.8);
  window.scrollBy({
    top: direction === "up" ? -distance : distance,
    behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
  });
  return executed(`Scrolled ${direction}.`);
})();
