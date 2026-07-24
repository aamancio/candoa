return (() => {
  window.__candoaAgentSnapshotID = snapshotID;
  const selectors = [
    "a[href]", "button", "label[for]", "input:not([type='hidden'])", "textarea", "select",
    "[contenteditable='true']", "[role='button']", "[role='link']",
    "[role='searchbox']", "[role='textbox']", "[role='combobox']",
    "[role='radio']", "[role='option']", "[role='checkbox']"
  ].join(",");
  const clean = (value) => String(value || "").replace(/[\s\n\r\t]+/g, " ").trim();
  const visibleInDocument = (element) => {
    if (!(element instanceof HTMLElement) || element.closest("[aria-hidden='true'],[hidden]")) return false;
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 2 && rect.height > 2 && style.display !== "none"
      && style.visibility !== "hidden" && Number(style.opacity || "1") > 0.05;
  };
  const labelFor = (element) => {
    const labelledBy = clean(element.getAttribute("aria-labelledby"))
      .split(" ")
      .map((id) => clean(document.getElementById(id)?.innerText || document.getElementById(id)?.textContent))
      .filter(Boolean)
      .join(" ");
    const explicitLabel = element.id
      ? clean(document.querySelector(`label[for="${CSS.escape(element.id)}"]`)?.innerText)
      : "";
    const imageText = Array.from(element.querySelectorAll("img"))
      .map((image) => clean(image.alt || image.title || image.getAttribute("aria-label")))
      .filter(Boolean)
      .join(" ");
    return clean([
      element.getAttribute("aria-label"), labelledBy, explicitLabel,
      element.closest("label")?.innerText, element.placeholder, element.title,
      element.alt, imageText, element.innerText, element.textContent, element.value
    ].find((candidate) => clean(candidate)));
  };
  const kindFor = (element) => {
    if (element instanceof HTMLLabelElement && element.control?.matches("input[type='radio'],input[type='checkbox']")) return "choice";
    if (element.matches("select,input[type='radio'],input[type='checkbox'],[role='radio'],[role='option'],[role='checkbox']")) return "choice";
    if (element.matches("input,textarea,[contenteditable='true'],[role='searchbox'],[role='textbox'],[role='combobox']")) return "field";
    if (element.matches("a[href],[role='link']")) return "link";
    return "button";
  };
  const seen = new Set();
  const controls = Array.from(document.querySelectorAll(selectors))
    .filter(visibleInDocument)
    .map((element) => {
      const label = labelFor(element);
      const kind = kindFor(element);
      const url = kind === "link" ? clean(element.href || element.getAttribute("href")) : "";
      if (!label) return null;
      const key = `${kind}|${label.toLocaleLowerCase()}|${url}`;
      if (seen.has(key)) return null;
      seen.add(key);
      return {
        kind,
        label: label.slice(0, 240),
        url: url || null,
        disabled: Boolean(
          element.disabled
            || (element instanceof HTMLLabelElement && element.control?.disabled)
            || element.getAttribute("aria-disabled") === "true"
        ),
        selected: Boolean(
          element.checked
            || element.selected
            || (element instanceof HTMLLabelElement && element.control?.checked)
            || element.getAttribute("aria-checked") === "true"
            || element.getAttribute("aria-selected") === "true"
        ),
        options: element instanceof HTMLSelectElement
          ? Array.from(element.options).filter((option) => !option.disabled).map((option) => clean(option.label || option.textContent)).filter(Boolean).slice(0, 80)
          : []
      };
    })
    .filter(Boolean)
    .slice(0, 200)
    .map((control, index) => ({ ref: `e${index}`, ...control }));
  return JSON.stringify(controls);
})();
