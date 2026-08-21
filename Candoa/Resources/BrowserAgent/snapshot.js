// Builds the page snapshot Eli reasons over: an accessibility tree in the
// Playwright ariaSnapshot shape, plus the flat controls list Candoa Cloud
// grounds actions against. Both come out of one walk, so a ref means the
// same element in both.
//
// Arguments: snapshotID (string), budget (number of characters for the tree).
return (() => {
  const A = CandoaAgent;
  // Lines get 88% of the budget; the header and the "more lines" markers
  // that replace dropped runs take the rest.
  const TREE_BUDGET = Math.max(4000, Number(budget) || 24000) - 400;

  // MARK: - Tree construction

  let nodesVisited = 0;
  const entries = [];
  const INTERACTIVE_SELECTOR = "a[href],button,input,select,textarea,summary,[role='button'],[role='link'],[role='checkbox'],[role='radio'],[role='tab'],[role='menuitem'],[role='option'],[role='switch'],[role='combobox'],[role='textbox'],[contenteditable='true'],[onclick],[tabindex]";

  function makeNode(role, name) {
    return { role, name, children: [], attrs: {}, placement: "in", essential: false, element: null };
  }

  function textRect(textNode, frameOffset) {
    const range = textNode.ownerDocument.createRange();
    range.selectNodeContents(textNode);
    const rect = range.getBoundingClientRect();
    return {
      top: rect.top + frameOffset.y, bottom: rect.bottom + frameOffset.y,
      left: rect.left + frameOffset.x, right: rect.right + frameOffset.x,
      width: rect.width, height: rect.height
    };
  }

  function appendText(parent, text, placement) {
    const cleaned = A.clean(text);
    if (!cleaned) return;
    const last = parent.children[parent.children.length - 1];
    if (last && last.role === "text") {
      last.text = A.truncate(`${last.text} ${cleaned}`, A.MAX_TEXT);
      if (last.placement !== "in" && placement === "in") last.placement = "in";
      return;
    }
    const node = makeNode("text", "");
    node.text = A.truncate(cleaned, A.MAX_TEXT);
    node.placement = placement;
    parent.children.push(node);
  }

  function registerRef(node, el, role, style) {
    if (entries.length >= A.MAX_REFS) return;
    const kind = A.controlKind(el, role);
    const hint = node.name ? "" : A.nameHint(el);
    const label = node.name || (hint ? `[unlabeled ${role}: ${hint}]` : `[unlabeled ${role}]`);
    const ref = `e${entries.length}`;
    const sensitive = kind === "field" ? A.isPersonalField(el) : A.submitsSensitiveForm(el);
    entries.push({
      ref, element: el, role, kind, label,
      url: A.linkURL(el) || null,
      disabled: A.isDisabled(el),
      selected: A.isSelected(el),
      sensitive,
      options: A.optionsOf(el)
    });
    node.ref = ref;
    node.kind = kind;
    if (sensitive) node.attrs.sensitive = true;
    if (style.cursor === "pointer" && (role === "generic" || role === "presentation")) node.role = "clickable";
  }

  function walkElement(el, parent, frameOffset, depth) {
    if (++nodesVisited > A.MAX_NODES) return;
    if (A.isHiddenByAttributes(el)) return;
    const tag = el.localName;
    if (tag === "br" || tag === "wbr") return;
    if (!A.isRendered(el)) return;

    let role = A.roleOf(el);
    if (role === "group" && !A.accessibleName(el, "group")) role = "generic";
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    const rect = A.viewportRect(el, frameOffset);
    const placement = A.placementOf(rect);
    // A script-driven clickable is reported only when it is the innermost
    // thing to click: a pointer-cursor card that contains real links or
    // buttons is a container, and those are what get the refs.
    const interactive = A.isInteractive(el, role)
      || ((role === "generic" || role === "presentation")
        && A.looksClickable(el, style)
        && !el.closest("a[href],button,[role='button'],[role='link'],label,select,summary")
        && !el.querySelector(INTERACTIVE_SELECTOR)
        && A.clean(el.textContent).length <= 160);

    // Credential fields are shown but never addressable: Eli does not type
    // passwords or card numbers, and the model should see why a sign-in is
    // in the way.
    if (A.isCredentialField(el)) {
      const node = makeNode("textbox", A.accessibleName(el, "textbox"));
      node.attrs.credential = true;
      node.placement = placement;
      node.essential = true;
      parent.children.push(node);
      return;
    }

    if (tag === "iframe" || tag === "frame") {
      const node = makeNode("iframe", A.accessibleName(el, "iframe"));
      node.placement = placement;
      node.essential = true;
      let doc = null;
      try { doc = el.contentDocument; } catch { doc = null; }
      if (doc && doc.documentElement) {
        const inner = {
          x: rect.left - frameOffset.x + el.clientLeft + frameOffset.x,
          y: rect.top - frameOffset.y + el.clientTop + frameOffset.y
        };
        walkChildren(doc.documentElement, node, inner, depth + 1);
      } else {
        node.attrs.crossOrigin = true;
      }
      parent.children.push(node);
      return;
    }

    const structural = role !== "generic" && role !== "presentation";
    let node = parent;
    if (structural || interactive) {
      const effectiveRole = !structural && interactive ? "clickable" : role;
      const name = A.accessibleName(el, effectiveRole);
      node = makeNode(effectiveRole, name);
      node.element = el;
      node.placement = placement;
      if (role === "heading") {
        const level = Number(el.getAttribute("aria-level")) || Number((tag.match(/^h([1-6])$/) || [])[1]) || 2;
        node.attrs.level = level;
        node.essential = true;
      }
      if (A.LANDMARKS.has(role) || role === "dialog" || role === "alertdialog" || role === "article" || role === "table") node.essential = true;
      if (interactive && !A.hasBox(el) && role !== "option") {
        // Zero-size but rendered (visually hidden inputs behind custom
        // controls): keep the node for its label, no ref.
      } else if (interactive) {
        registerRef(node, el, effectiveRole, style);
        node.essential = true;
        if (A.isDisabled(el)) node.attrs.disabled = true;
        const selected = A.isSelected(el);
        if (selected) node.attrs[role === "checkbox" || role === "radio" || role === "switch" || role === "menuitemcheckbox" || role === "menuitemradio" ? "checked" : "selected"] = true;
        if (A.isCurrent(el)) node.attrs.current = true;
        const expanded = A.isExpanded(el);
        if (expanded !== null) node.attrs.expanded = expanded;
        const url = A.linkURL(el);
        if (url) node.attrs.href = A.compactHref(url);
        const options = A.optionsOf(el);
        if (options.length > 0) node.attrs.options = options;
        const value = A.valueOf(el, role);
        if (node.kind === "field" || tag === "select") {
          if (node.attrs.sensitive) node.attrs.filled = Boolean(value);
          else if (value) node.value = A.truncate(value, A.MAX_VALUE);
        }
        if (el.hasAttribute("placeholder") && !value && !node.attrs.sensitive) node.attrs.placeholder = A.truncate(A.clean(el.getAttribute("placeholder")), 60);
        if (el.required || el.getAttribute("aria-required") === "true") node.attrs.required = true;
        if (!node.name) { const hint = A.nameHint(el); if (hint) node.attrs.hint = hint; }
        if (placement === "in" && A.isOccluded(el, A.boundingBox(el))) node.attrs.occluded = true;
      }
      if (role === "img" || role === "presentation" && tag === "img") {
        if (!node.name) return; // decorative
        parent.children.push(node);
        return;
      }
      if (role === "progressbar" || role === "meter" || role === "slider" || role === "spinbutton") {
        const value = A.valueOf(el, role);
        if (value) node.value = value;
      }
      parent.children.push(node);
      // Controls whose name came from their content have nothing left to
      // list underneath; their children would repeat the name.
      if (interactive && (effectiveRole === "button" || effectiveRole === "link" || effectiveRole === "option" || effectiveRole === "tab" || effectiveRole === "menuitem" || effectiveRole === "checkbox" || effectiveRole === "radio" || effectiveRole === "switch" || effectiveRole === "summary" || effectiveRole === "clickable" || tag === "select" || tag === "input" || tag === "textarea")) {
        return;
      }
      // A caption, legend, or figcaption already named its parent.
      if ((role === "caption" || role === "legend") && parent.name) { parent.children.pop(); return; }
      if (role === "heading") {
        // A heading that wraps a control (FAQ accordions, card titles) keeps
        // the control underneath; otherwise its name is its content.
        if (!el.querySelector("a[href],button,[role='button'],[role='link'],input,select,textarea,summary")) return;
        node.name = "";
      }
    }

    if (tag === "select" || tag === "textarea" || tag === "input" || tag === "svg" || tag === "canvas" || tag === "video" || tag === "audio" || tag === "object" || tag === "embed") return;
    // A field's content is its value (shown on its own line, truncated);
    // walking into a rich editor would print the whole document.
    if (node !== parent && node.kind === "field") return;
    if (tag === "figcaption" && parent.name) return;
    walkChildren(el, node, frameOffset, depth + 1);
  }

  function walkChildren(el, node, frameOffset, depth) {
    for (const child of A.composedChildren(el)) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (!A.clean(child.data)) continue;
        const parentEl = child.parentElement || el;
        // Text inside a label names its control; the control's line shows it.
        const label = parentEl.closest("label");
        if (label && label.control && A.isRendered(label.control)) continue;
        const rect = textRect(child, frameOffset);
        appendText(node, child.data, rect.width === 0 && rect.height === 0 ? A.placementOf(A.viewportRect(parentEl, frameOffset)) : A.placementOf(rect));
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        walkElement(child, node, frameOffset, depth);
      }
    }
  }

  // MARK: - Root selection

  function modalRoot() {
    const candidates = Array.from(document.querySelectorAll("dialog[open],[role='dialog'][aria-modal='true'],[role='alertdialog'][aria-modal='true'],[role='alertdialog']"))
      .filter((el) => !A.isHiddenByAttributes(el) && A.isRendered(el) && A.hasBox(el));
    // The last one in document order is the one on top.
    return candidates.length > 0 ? candidates[candidates.length - 1] : null;
  }

  const root = makeNode("document", A.clean(document.title));
  const modal = modalRoot();
  const origin = { x: 0, y: 0 };
  if (modal) {
    const dialog = makeNode(A.roleOf(modal) === "alertdialog" ? "alertdialog" : "dialog", A.accessibleName(modal, "dialog"));
    dialog.attrs.modal = true;
    dialog.essential = true;
    dialog.element = modal;
    root.children.push(dialog);
    walkChildren(modal, dialog, origin, 1);
  } else {
    walkChildren(document.body || document.documentElement, root, origin, 0);
  }

  // MARK: - Simplification

  function simplify(node) {
    node.children.forEach(simplify);
    // A container with a single text child collapses into one line.
    // Paragraphs, list items, cells, and generic wrappers all do this.
    node.children = node.children.flatMap((child) => {
      if (child.role === "listitem" || child.role === "paragraph" || child.role === "cell" || child.role === "gridcell" || child.role === "columnheader" || child.role === "rowheader" || child.role === "term" || child.role === "definition" || child.role === "caption") {
        if (child.children.length === 0 && !child.text && !child.name) return [];
      }
      return [child];
    });
    // Empty containers (popover shells, collapsed sublists, unnamed groups)
    // say nothing; an element that is only its own line keeps it when it
    // carries a name, a ref, a value, or a flag worth seeing.
    node.children = node.children.filter((child) => (
      child.role === "text" || child.children.length > 0 || child.ref || child.text || child.value
        || child.attrs.credential || child.attrs.crossOrigin
        || (child.name && (child.role === "heading" || child.role === "img" || child.role === "iframe" || child.role === "dialog" || child.role === "alertdialog"))
    ));
    // A card's image link and title link say the same thing twice.
    node.children = node.children.filter((child, index, siblings) => {
      const previous = siblings[index - 1];
      return !(previous && child.ref && previous.ref && child.role === previous.role && child.name === previous.name && child.attrs.href === previous.attrs.href && child.children.length === 0 && previous.children.length === 0);
    });
    // A list item wrapping exactly one node (a nav link, a card) is the node.
    node.children = node.children.flatMap((child) => (
      child.role === "listitem" && !child.name && child.children.length === 1 && child.children[0].role !== "text"
        ? [child.children[0]]
        : [child]
    ));
    // Rows of plain text cells become one line: `row: a | b | c`.
    if (node.role === "row" && node.children.length > 0 && node.children.every((cell) => (cell.role === "cell" || cell.role === "columnheader" || cell.role === "rowheader") && cell.children.every((grandchild) => grandchild.role === "text"))) {
      node.text = node.children.map((cell) => cell.name || cell.children.map((grandchild) => grandchild.text).join(" ")).join(" | ");
      node.placement = node.children.some((cell) => cell.placement === "in") ? "in" : node.children[0].placement;
      node.children = [];
    }
  }
  simplify(root);

  // MARK: - Rendering

  function quote(value) {
    return `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
  }

  function attrsText(node) {
    const parts = [];
    const attrs = node.attrs;
    if (node.ref) parts.push(`[ref=${node.ref}]`);
    if (attrs.level) parts.push(`[level=${attrs.level}]`);
    if (attrs.href) parts.push(`[href=${attrs.href}]`);
    if (attrs.checked) parts.push("[checked]");
    if (attrs.selected) parts.push("[selected]");
    if (attrs.current) parts.push("[current]");
    if (attrs.expanded === true) parts.push("[expanded]");
    if (attrs.expanded === false) parts.push("[collapsed]");
    if (attrs.disabled) parts.push("[disabled]");
    if (attrs.required) parts.push("[required]");
    if (attrs.sensitive) parts.push("[sensitive]");
    if (attrs.filled === true) parts.push("[filled]");
    if (attrs.filled === false) parts.push("[empty]");
    if (attrs.credential) parts.push("[credential: not available to Eli]");
    if (attrs.occluded) parts.push("[covered by another element]");
    if (attrs.modal) parts.push("[modal: content behind it is inert]");
    if (attrs.crossOrigin) parts.push("[cross-origin: contents not inspectable]");
    if (attrs.placeholder) parts.push(`[placeholder=${quote(attrs.placeholder)}]`);
    if (attrs.hint) parts.push(`[hint=${quote(attrs.hint)}]`);
    if (attrs.options) parts.push(`[options: ${attrs.options.map((option) => quote(option)).join(" | ")}]`);
    return parts.join(" ");
  }

  const lines = [];
  function render(node, depth) {
    if (node.role === "text") {
      lines.push({ depth, text: `- text: ${node.text}`, placement: node.placement, essential: false, container: false, node });
      return;
    }
    const head = [node.role, node.name ? quote(node.name) : "", attrsText(node)].filter(Boolean).join(" ");
    const onlyText = node.children.length === 1 && node.children[0].role === "text";
    const inlineText = node.text || (onlyText ? node.children[0].text : "") || node.value;
    if (node.children.length === 0 || onlyText) {
      const suffix = inlineText ? `: ${inlineText}` : "";
      lines.push({ depth, text: `- ${head}${suffix}`, placement: node.placement, essential: node.essential || Boolean(node.ref), container: false, node });
      return;
    }
    lines.push({ depth, text: `- ${head}${node.value ? `: ${node.value}` : ""}:`, placement: node.placement, essential: node.essential || Boolean(node.ref), container: true, node });
    for (const child of node.children) render(child, depth + 1);
  }
  for (const child of root.children) render(child, 0);

  // MARK: - Budget
  //
  // Everything in the viewport is kept. Off-screen lines compete for the
  // remainder by distance from the viewport, with controls and structure
  // counted as four times nearer than prose; what is dropped leaves a marker
  // so the model knows there is more. The assembled text — header and
  // markers included — has to fit, so selection shrinks until it does.

  const indent = (line) => `${"  ".repeat(line.depth)}${line.text}`;
  const firstIn = lines.findIndex((line) => line.placement === "in");
  const lastIn = lines.length - 1 - [...lines].reverse().findIndex((line) => line.placement === "in");
  const above = lines.slice(0, Math.max(firstIn, 0)).filter((line) => line.placement === "above").length;
  const below = lastIn >= 0 ? lines.slice(lastIn + 1).filter((line) => line.placement === "below").length : 0;

  function select(lineBudget) {
    let total = lines.reduce((sum, line) => sum + indent(line).length + 1, 0);
    if (total <= lineBudget) return lines.map(() => true);
    let kept = lines.map((line) => line.placement === "in");
    total = lines.reduce((sum, line, index) => sum + (kept[index] ? indent(line).length + 1 : 0), 0);
    if (total > lineBudget) {
      // A viewport alone past the budget (a dense table) is trimmed from the
      // bottom; the model can scroll for the rest.
      let running = 0;
      kept = lines.map((line, index) => {
        if (!kept[index]) return false;
        running += indent(line).length + 1;
        return running <= lineBudget;
      });
      total = Math.min(total, lineBudget);
    }
    const candidates = lines
      .map((line, index) => {
        const distance = firstIn < 0 ? index : index < firstIn ? firstIn - index : index > lastIn ? index - lastIn : 0;
        return { index, rank: (line.essential || line.container) ? distance / 4 : distance };
      })
      .filter(({ index }) => !kept[index])
      .sort((left, right) => left.rank - right.rank || left.index - right.index);
    for (const { index } of candidates) {
      const cost = indent(lines[index]).length + 1;
      if (total + cost > lineBudget) continue;
      kept[index] = true;
      total += cost;
    }
    // A container whose descendants were all dropped is dropped too.
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      if (!lines[index].container) continue;
      const depth = lines[index].depth;
      let hasKeptChild = false;
      for (let next = index + 1; next < lines.length && lines[next].depth > depth; next += 1) {
        if (kept[next]) { hasKeptChild = true; break; }
      }
      if (!hasKeptChild) kept[index] = false;
    }
    return kept;
  }

  function assemble(kept) {
    const output = [];
    let dropped = 0;
    const flushDropped = (depth) => {
      if (dropped > 0) output.push(`${"  ".repeat(depth)}- … ${dropped} more line${dropped === 1 ? "" : "s"} not shown (scroll to bring them into view)`);
      dropped = 0;
    };
    lines.forEach((line, index) => {
      if (index === firstIn && above > 0) { flushDropped(line.depth); output.push(`- [viewport starts here — ${above} lines above; scroll up to see them]`); }
      if (!kept[index]) { dropped += 1; return; }
      flushDropped(line.depth);
      output.push(indent(line));
      if (index === lastIn && below > 0) output.push(`- [viewport ends here — ${below} lines below; scroll down to see them]`);
    });
    flushDropped(0);
    return output.join("\n");
  }

  let lineBudget = TREE_BUDGET;
  let body = assemble(select(lineBudget));
  for (let attempt = 0; attempt < 4 && body.length > TREE_BUDGET; attempt += 1) {
    lineBudget -= body.length - TREE_BUDGET + 200;
    body = assemble(select(lineBudget));
  }

  const scroller = document.scrollingElement || document.documentElement;
  const header = [
    `page: ${quote(A.truncate(A.clean(document.title), 120))}`,
    `url: ${location.href.length > 200 ? `${location.href.slice(0, 199)}…` : location.href}`,
    `viewport: ${innerWidth}x${innerHeight}, scrolled ${Math.round(scroller.scrollTop)}px of ${Math.max(scroller.scrollHeight - innerHeight, 0)}px${modal ? ", a modal dialog is open" : ""}`
  ];

  A.setRegistry(snapshotID, entries.map((entry) => ({ element: entry.element, label: entry.label, kind: entry.kind, role: entry.role })));

  const controls = entries.map((entry) => ({
    ref: entry.ref,
    kind: entry.kind,
    role: entry.role,
    label: entry.label,
    url: entry.url,
    disabled: entry.disabled,
    selected: entry.selected,
    sensitive: entry.sensitive,
    options: entry.options
  }));

  return JSON.stringify({
    tree: `${header.join("\n")}\n\n${body}`,
    controls,
    viewport: {
      width: innerWidth,
      height: innerHeight,
      scrollTop: Math.round(scroller.scrollTop),
      scrollHeight: scroller.scrollHeight,
      linesAbove: above,
      linesBelow: below,
      modal: Boolean(modal)
    }
  });
})();
