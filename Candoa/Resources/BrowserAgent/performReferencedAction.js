// Performs one action on a control addressed by ref from the last snapshot.
//
// Arguments: snapshotID, ref, expectedLabel, expectedKind, kind, value.
// kind ∈ click | select | fill | press. Reports `{ ok, message }` — the
// message is what the model reads as the step's result, so it says what
// happened in plain terms.
return (async () => {
  const A = CandoaAgent;
  const executed = (message) => JSON.stringify({ ok: true, message });
  const failed = (message) => JSON.stringify({ ok: false, message });

  const found = A.lookup(snapshotID, ref);
  if (found.error) return failed(found.error);
  const { element, label, kind: controlKind, role } = found.entry;

  // The page may have relabeled the control since the snapshot (a button
  // that became "Adding…"); the action was chosen by the old label, so stop
  // and let a fresh snapshot show what is there now.
  const currentLabel = A.accessibleName(element, role) || `[unlabeled ${role}]`;
  if (currentLabel !== expectedLabel || controlKind !== expectedKind) {
    return failed(`Candoa stopped because the referenced control changed (it now reads "${currentLabel}").`);
  }
  if (A.isDisabled(element)) return failed(`"${label}" is disabled.`);
  if (A.isHiddenByAttributes(element) || !A.isRendered(element)) {
    return failed(`"${label}" is no longer visible.`);
  }

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  element.scrollIntoView({ block: "center", inline: "nearest", behavior: reducedMotion ? "auto" : "smooth" });

  const describe = (message) => message;

  // MARK: - Choice controls

  const choiceInput = element instanceof HTMLInputElement && (element.type === "radio" || element.type === "checkbox")
    ? element
    : null;

  const activateChoice = () => {
    const wasSelected = A.isSelected(element);
    const target = choiceInput?.id
      ? (element.getRootNode().querySelector?.(`label[for="${CSS.escape(choiceInput.id)}"]`) || element)
      : element;
    target.click();
    if (choiceInput && choiceInput.checked === wasSelected && choiceInput.type === "radio") {
      return failed(`Candoa could not confirm that "${label}" was selected.`);
    }
    const nowSelected = A.isSelected(element);
    if (choiceInput?.type === "checkbox" || role === "switch" || role === "checkbox") {
      return executed(`${nowSelected ? "Checked" : "Unchecked"} "${label}".`);
    }
    return executed(`Selected "${label}".`);
  };

  // MARK: - Click

  if (kind === "click") {
    if (controlKind === "choice" && element.localName !== "select") return activateChoice();
    if (element instanceof HTMLSelectElement) {
      element.focus();
      return executed(`Focused "${label}"; choose an option with select.`);
    }
    // A link that would open a new tab opens here instead: the run lives in
    // this tab, and a page that appears elsewhere is a page Eli cannot see.
    let restoreTarget = null;
    if (element instanceof HTMLAnchorElement && element.target && element.target !== "_self") {
      restoreTarget = element.target;
      element.target = "_self";
    }
    const before = location.href;
    element.click();
    if (restoreTarget !== null) {
      // Restore after the click has been dispatched; the navigation, if any,
      // already read the target.
      setTimeout(() => { element.target = restoreTarget; }, 0);
    }
    // What the click did is reported from the settled page afterwards (the
    // outcome's before/after summary), not read back here: frameworks apply
    // the change after the event returns.
    if (location.href !== before) return executed(`Clicked "${label}"; the page is navigating.`);
    return executed(describe(`Clicked "${label}".`));
  }

  // MARK: - Select

  if (kind === "select") {
    if (element instanceof HTMLSelectElement) {
      const requested = A.clean(value).toLocaleLowerCase();
      const option = Array.from(element.options).find((candidate) =>
        A.clean(candidate.label).toLocaleLowerCase() === requested
          || A.clean(candidate.value).toLocaleLowerCase() === requested
          || A.clean(candidate.textContent).toLocaleLowerCase() === requested
      );
      if (!option) return failed(`Candoa could not find "${value}" among the options of "${label}".`);
      if (option.disabled) return failed(`"${A.clean(option.label)}" is not available in "${label}".`);
      element.focus();
      A.setNativeValue(element, option.value);
      A.fire(element, "input");
      A.fire(element, "change");
      return executed(`Selected "${A.clean(option.label)}" in "${label}".`);
    }
    return activateChoice();
  }

  // MARK: - Fill

  if (kind === "fill") {
    if (A.isCredentialField(element)) return failed("Candoa does not enter credentials.");
    if (element.readOnly) return failed(`"${label}" is read-only.`);
    element.focus();
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      // Select-all then the new value, the way typing over a field does, so
      // frameworks that watch keystrokes see a change they recognize.
      A.fire(element, "keydown", A.keyInit("a"));
      A.setNativeValue(element, "");
      A.fire(element, "input", { inputType: "deleteContentBackward" });
      A.setNativeValue(element, value);
      A.fire(element, "input", { inputType: "insertText", data: value });
      A.fire(element, "change");
      A.fire(element, "keyup", A.keyInit("a"));
      if (A.clean(element.value) !== A.clean(value)) {
        return executed(`Typed into "${label}"; the field now reads "${A.truncate(A.clean(element.value), 80)}".`);
      }
      return executed(`Typed "${A.truncate(A.clean(value), 80)}" into "${label}".`);
    }
    // contenteditable: insertText goes through the editing pipeline the
    // page's editor listens to; fall back to replacing the text.
    const selection = element.ownerDocument.getSelection();
    const range = element.ownerDocument.createRange();
    range.selectNodeContents(element);
    selection.removeAllRanges();
    selection.addRange(range);
    let inserted = false;
    try { inserted = element.ownerDocument.execCommand("insertText", false, value); } catch { inserted = false; }
    if (!inserted) {
      element.textContent = value;
      A.fire(element, "input", { inputType: "insertText", data: value });
    }
    return executed(`Typed "${A.truncate(A.clean(value), 80)}" into "${label}".`);
  }

  // MARK: - Press

  if (kind === "press") {
    const key = String(value || "Enter");
    if (!["Enter", "Escape", "Tab", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "Backspace", "Space"].includes(key)) {
      return failed(`Candoa does not press "${key}".`);
    }
    element.focus();
    const init = A.keyInit(key);
    const before = location.href;
    const keydownAllowed = A.fire(element, "keydown", init);
    if (keydownAllowed && key === "Enter") {
      // Implicit submission, as the browser would do it for a real Enter.
      const form = A.formOf(element);
      if (element instanceof HTMLInputElement && form) {
        A.fire(element, "keypress", init);
        if (typeof form.requestSubmit === "function") {
          const submitter = form.querySelector("button[type='submit'],input[type='submit'],button:not([type])");
          try { form.requestSubmit(submitter || undefined); } catch { form.requestSubmit(); }
        } else {
          form.submit();
        }
      } else if (element.localName !== "textarea" && (element instanceof HTMLAnchorElement || element instanceof HTMLButtonElement || role === "button" || role === "link" || role === "option" || role === "menuitem")) {
        element.click();
      }
    }
    if (keydownAllowed && key === "Space" && (element instanceof HTMLButtonElement || role === "button" || role === "checkbox" || role === "switch")) {
      element.click();
    }
    A.fire(element, "keyup", init);
    if (location.href !== before) return executed(`Pressed ${key} in "${label}"; the page is navigating.`);
    return executed(`Pressed ${key} in "${label}".`);
  }

  return failed("Candoa rejected an unsupported referenced action.");
})();
