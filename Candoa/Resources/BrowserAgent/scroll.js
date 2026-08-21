// Scrolls the page — or, when the page itself does not scroll, its main
// scrolling region — by most of a viewport, or brings a referenced control
// into view.
//
// Arguments: snapshotID, direction ("up" | "down" | a ref such as e12).
return (async () => {
  const A = CandoaAgent;
  const executed = (message) => JSON.stringify({ ok: true, message });
  const failed = (message) => JSON.stringify({ ok: false, message });
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const behavior = reducedMotion ? "auto" : "smooth";

  if (/^e\d{1,3}$/.test(String(direction))) {
    const found = A.lookup(snapshotID, direction);
    if (found.error) return failed(found.error);
    found.entry.element.scrollIntoView({ block: "center", inline: "nearest", behavior });
    return executed(`Scrolled "${found.entry.label}" into view.`);
  }

  if (window.__candoaAgentSnapshotID !== snapshotID) {
    return failed("Candoa stopped because the page changed after it was inspected.");
  }
  if (direction !== "up" && direction !== "down") return failed("Candoa can scroll up or down.");

  // App shells keep the document fixed and scroll an inner region; when the
  // document cannot move in the requested direction, the largest scrollable
  // region under the viewport takes the scroll instead.
  const scroller = document.scrollingElement || document.documentElement;
  const canScrollDocument = direction === "down"
    ? scroller.scrollTop + innerHeight < scroller.scrollHeight - 1
    : scroller.scrollTop > 0;

  let target = canScrollDocument ? null : largestScrollableRegion();
  const distance = Math.max(300, (target ? target.clientHeight : innerHeight) * 0.8);
  const before = target ? target.scrollTop : scroller.scrollTop;
  if (target) {
    target.scrollBy({ top: direction === "up" ? -distance : distance, behavior });
  } else {
    window.scrollBy({ top: direction === "up" ? -distance : distance, behavior });
  }
  // Smooth scrolling settles later; report what the scroll position allows.
  const maximum = target ? target.scrollHeight - target.clientHeight : scroller.scrollHeight - innerHeight;
  const atEdge = direction === "down" ? before >= maximum - 1 : before <= 0;
  if (atEdge) return executed(`Already at the ${direction === "down" ? "bottom" : "top"}; nothing more to scroll ${direction}.`);
  return executed(`Scrolled ${direction}.`);

  function largestScrollableRegion() {
    let best = null;
    let bestArea = 0;
    const all = document.querySelectorAll("*");
    const limit = Math.min(all.length, 5000);
    for (let index = 0; index < limit; index += 1) {
      const el = all[index];
      if (el.scrollHeight <= el.clientHeight + 20) continue;
      const style = getComputedStyle(el);
      if (!/(auto|scroll)/.test(style.overflowY)) continue;
      const rect = el.getBoundingClientRect();
      const visibleHeight = Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0);
      const visibleWidth = Math.min(rect.right, innerWidth) - Math.max(rect.left, 0);
      if (visibleHeight <= 0 || visibleWidth <= 0) continue;
      const area = visibleHeight * visibleWidth;
      const canMove = direction === "down"
        ? el.scrollTop + el.clientHeight < el.scrollHeight - 1
        : el.scrollTop > 0;
      if (canMove && area > bestArea) { best = el; bestArea = area; }
    }
    return best;
  }
})();
