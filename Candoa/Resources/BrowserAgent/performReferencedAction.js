return (() => {
  const executed = (message) => JSON.stringify({ ok: true, message });
  const failed = (message) => JSON.stringify({ ok: false, message });
  if (window.__candoaAgentSnapshotID !== snapshotID) {
    return failed("Candoa stopped because the page changed after it was inspected.");
  }
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
  const credentialField = (element) => {
    const autocomplete = clean(element.getAttribute("autocomplete")).toLocaleLowerCase();
    return element.matches("input[type='password']")
      || /(^|\s)(cc-number|cc-csc|cc-exp|cc-exp-month|cc-exp-year|current-password|new-password|one-time-code)(\s|$)/.test(autocomplete);
  };
  const canonicalFor = (element) => (
    element instanceof HTMLLabelElement
      && element.control?.matches("input[type='radio'],input[type='checkbox']")
  ) ? element.control : element;
  const seenElements = new Set();
  const seenLinks = new Set();
  const controls = Array.from(document.querySelectorAll(selectors))
    .filter(visibleInDocument)
    .map((element) => {
      if (credentialField(element)) return null;
      const label = labelFor(element);
      const controlKind = kindFor(element);
      const url = controlKind === "link" ? clean(element.href || element.getAttribute("href")) : "";
      if (!label) return null;
      const canonical = canonicalFor(element);
      if (seenElements.has(canonical)) return null;
      seenElements.add(canonical);
      if (controlKind === "link") {
        const key = `${label.toLocaleLowerCase()}|${url}`;
        if (seenLinks.has(key)) return null;
        seenLinks.add(key);
      }
      return { element, label: label.slice(0, 240), kind: controlKind };
    })
    .filter(Boolean)
    .slice(0, 200);
  const index = Number(String(ref).slice(1));
  const control = /^e\d{1,3}$/.test(ref) ? controls[index] : null;
  if (!control || control.label !== expectedLabel || control.kind !== expectedKind) {
    return failed("Candoa stopped because the referenced control changed.");
  }
  const element = control.element;
  element.scrollIntoView({
    block: "center",
    inline: "nearest",
    behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
  });
  const choiceInput = element instanceof HTMLLabelElement
    ? element.control
    : element instanceof HTMLInputElement
      && (element.type === "radio" || element.type === "checkbox")
      ? element
      : null;
  const activateChoice = () => {
    const activationElement = choiceInput?.id
      ? document.querySelector(`label[for="${CSS.escape(choiceInput.id)}"]`) || element
      : element;
    activationElement.click();
    if (choiceInput && !choiceInput.checked) {
      return failed(`Candoa could not confirm that "${control.label}" was selected.`);
    }
    return executed(`Selected "${control.label}".`);
  };
  if (kind === "click") {
    if (control.kind === "choice") return activateChoice();
    element.click();
    return executed(`Clicked "${control.label}".`);
  }
  if (kind === "select") {
    if (element instanceof HTMLSelectElement) {
      const requested = clean(value).toLocaleLowerCase();
      const option = Array.from(element.options).find((candidate) =>
        clean(candidate.label).toLocaleLowerCase() === requested
          || clean(candidate.value).toLocaleLowerCase() === requested
      );
      if (!option) return failed(`Candoa could not find the requested option in "${control.label}".`);
      element.focus();
      element.value = option.value;
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
      return executed(`Selected "${clean(option.label)}" in "${control.label}".`);
    }
    return activateChoice();
  }
  if (kind === "fill") {
    if (element instanceof HTMLInputElement && element.type === "password") {
      return failed("Candoa does not enter credentials.");
    }
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      element.focus();
      element.value = value;
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    } else {
      element.focus();
      element.textContent = value;
      element.dispatchEvent(new InputEvent("input", {
        bubbles: true,
        inputType: "insertText",
        data: value
      }));
    }
    return executed(`Filled "${control.label}".`);
  }
  return failed("Candoa rejected an unsupported referenced action.");
})();
