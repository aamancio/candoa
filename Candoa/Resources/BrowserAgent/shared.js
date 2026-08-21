// Shared page-perception library for Eli's browser agent.
//
// BrowserAgentDriver prepends this file to every agent script before handing
// it to callAsyncJavaScript, so each script sees one `CandoaAgent` object and
// none of them carries its own copy of the DOM walk. Everything here runs in
// the page, inside Candoa's isolated content world: page scripts cannot see
// the registry, and nothing here is visible to them.
//
// The model reads one artifact: an accessibility-tree snapshot in the
// Playwright `ariaSnapshot` shape — one node per line, `role "name"`,
// interactive nodes tagged with a stable `[ref=eN]`. Every ref maps back to a
// live element through the registry below, which is what lets an action be
// addressed by ref instead of by re-deriving a selector.
const CandoaAgent = (() => {
  const MAX_NODES = 40000;
  const MAX_REFS = 400;
  const MAX_NAME = 240;
  const MAX_TEXT = 400;
  const MAX_VALUE = 120;

  const clean = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
  const truncate = (value, limit) => (value.length > limit ? `${value.slice(0, limit - 1)}…` : value);

  // MARK: - Roles
  //
  // Implicit roles per HTML-AAM, reduced to what the model needs to tell
  // elements apart. `generic` containers are flattened out of the tree.

  const LANDMARKS = new Set([
    "banner", "navigation", "main", "complementary", "contentinfo", "region", "form", "search"
  ]);
  // Roles named by their content. Text containers (paragraph, listitem,
  // cell, row…) are deliberately not here: their text renders as children,
  // and naming them from it would print everything twice.
  const NAME_FROM_CONTENT = new Set([
    "button", "checkbox", "heading", "link", "menuitem", "menuitemcheckbox", "menuitemradio",
    "option", "radio", "switch", "tab", "tooltip", "treeitem", "summary", "clickable"
  ]);
  const INTERACTIVE_ROLES = new Set([
    "button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "option", "combobox", "listbox", "textbox", "searchbox", "spinbutton",
    "slider", "treeitem", "summary"
  ]);
  const CHOICE_ROLES = new Set([
    "checkbox", "radio", "switch", "option", "menuitemcheckbox", "menuitemradio", "tab"
  ]);
  const FIELD_ROLES = new Set(["textbox", "searchbox", "spinbutton", "slider"]);

  const INPUT_ROLES = {
    button: "button", submit: "button", reset: "button", image: "button",
    checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton",
    search: "searchbox", email: "textbox", tel: "textbox", url: "textbox", text: "textbox",
    password: "textbox", date: "textbox", "datetime-local": "textbox", month: "textbox",
    week: "textbox", time: "textbox", color: "button", file: "button"
  };

  const TAG_ROLES = {
    a: (el) => (el.hasAttribute("href") ? "link" : "generic"),
    area: (el) => (el.hasAttribute("href") ? "link" : "generic"),
    article: () => "article",
    aside: () => "complementary",
    button: () => "button",
    caption: () => "caption",
    dd: () => "definition",
    details: () => "group",
    dialog: (el) => (el.open || isRendered(el) ? "dialog" : "generic"),
    dt: () => "term",
    fieldset: (el) => (nativeName(el) ? "group" : "generic"),
    figure: () => "figure",
    footer: (el) => (el.closest("article,aside,main,nav,section") ? "generic" : "contentinfo"),
    form: (el) => (hasAccessibleName(el) ? "form" : "generic"),
    h1: () => "heading", h2: () => "heading", h3: () => "heading",
    h4: () => "heading", h5: () => "heading", h6: () => "heading",
    header: (el) => (el.closest("article,aside,main,nav,section") ? "generic" : "banner"),
    hr: () => "separator",
    html: () => "document",
    iframe: () => "iframe",
    img: (el) => (el.getAttribute("alt") === "" ? "presentation" : "img"),
    input: (el) => {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if ((type === "text" || type === "search" || type === "email" || type === "url" || type === "tel") && el.hasAttribute("list")) return "combobox";
      return INPUT_ROLES[type] || "textbox";
    },
    legend: () => "legend",
    li: () => "listitem",
    main: () => "main",
    math: () => "math",
    menu: () => "list",
    meter: () => "meter",
    nav: () => "navigation",
    ol: () => "list",
    optgroup: () => "group",
    option: () => "option",
    output: () => "status",
    p: () => "paragraph",
    progress: () => "progressbar",
    search: () => "search",
    section: (el) => (hasAccessibleName(el) ? "region" : "generic"),
    select: (el) => (el.multiple || el.size > 1 ? "listbox" : "combobox"),
    summary: () => "summary",
    svg: () => "img",
    table: () => "table",
    tbody: () => "rowgroup", thead: () => "rowgroup", tfoot: () => "rowgroup",
    td: () => "cell",
    textarea: () => "textbox",
    th: (el) => (el.scope === "row" ? "rowheader" : "columnheader"),
    tr: () => "row",
    ul: () => "list",
    video: () => "video",
    audio: () => "audio"
  };

  function hasAccessibleName(el) {
    return Boolean(clean(el.getAttribute("aria-label")) || clean(el.getAttribute("aria-labelledby")) || clean(el.getAttribute("title")));
  }

  function explicitRole(el) {
    const tokens = clean(el.getAttribute("role")).toLowerCase().split(" ").filter(Boolean);
    // "none"/"presentation" are honored only on elements that are not focusable.
    for (const token of tokens) {
      if ((token === "none" || token === "presentation") && isFocusable(el)) continue;
      return token;
    }
    return null;
  }

  function roleOf(el) {
    const explicit = explicitRole(el);
    if (explicit) return explicit === "none" ? "presentation" : explicit;
    const tag = el.localName;
    const implicit = TAG_ROLES[tag];
    if (implicit) return implicit(el);
    if (el.isContentEditable && el.contentEditable !== "inherit") return "textbox";
    return "generic";
  }

  function isFocusable(el) {
    if (el.matches("a[href],button,input,select,textarea,summary,[contenteditable='true'],[contenteditable='']")) return true;
    const tabIndex = el.getAttribute("tabindex");
    return tabIndex !== null && Number(tabIndex) >= 0;
  }

  // MARK: - Visibility

  function isHiddenByAttributes(el) {
    return el.hasAttribute("hidden")
      || el.getAttribute("aria-hidden") === "true"
      || el.hasAttribute("inert")
      || el.localName === "script" || el.localName === "style" || el.localName === "noscript"
      || el.localName === "template" || el.localName === "head" || el.localName === "meta"
      || el.localName === "link";
  }

  function isRendered(el) {
    if (typeof el.checkVisibility === "function") {
      // `contentVisibilityAuto` keeps content-visibility:auto sections, which
      // browsers still lay out for accessibility.
      return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true, contentVisibilityAuto: true });
    }
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity || "1") < 0.05) return false;
    return el.getClientRects().length > 0;
  }

  // An inline element wrapping block content (a card's outer link) reports
  // an empty bounding box; its client rects, or its children's, carry the
  // real size.
  function boundingBox(el) {
    const rect = el.getBoundingClientRect();
    if (rect.width > 1 && rect.height > 1) return rect;
    let top = Infinity, left = Infinity, bottom = -Infinity, right = -Infinity;
    const include = (candidate) => {
      if (candidate.width <= 0 && candidate.height <= 0) return;
      top = Math.min(top, candidate.top); left = Math.min(left, candidate.left);
      bottom = Math.max(bottom, candidate.bottom); right = Math.max(right, candidate.right);
    };
    for (const candidate of el.getClientRects()) include(candidate);
    for (const child of el.children) include(child.getBoundingClientRect());
    if (top === Infinity) return rect;
    return new DOMRect(left, top, right - left, bottom - top);
  }

  function hasBox(el) {
    const rect = boundingBox(el);
    return rect.width > 1 && rect.height > 1;
  }

  // Where the element sits relative to the top window's viewport, in top-window
  // coordinates (frames add their own offset).
  function viewportRect(el, frameOffset) {
    const rect = boundingBox(el);
    return {
      top: rect.top + frameOffset.y,
      bottom: rect.bottom + frameOffset.y,
      left: rect.left + frameOffset.x,
      right: rect.right + frameOffset.x,
      width: rect.width,
      height: rect.height
    };
  }

  function placementOf(rect) {
    if (rect.bottom <= 0) return "above";
    if (rect.top >= innerHeight) return "below";
    return "in";
  }

  // An interactive control covered by something else (a modal scrim, a sticky
  // header, a cookie banner) is still in the tree — the model should know it
  // exists — but it is flagged so it is not chosen over the thing covering it.
  function isOccluded(el, rect) {
    if (rect.width <= 0 || rect.height <= 0) return false;
    const root = el.getRootNode();
    const doc = el.ownerDocument;
    const x = Math.min(Math.max(rect.left + rect.width / 2, 0), doc.defaultView.innerWidth - 1);
    const y = Math.min(Math.max(rect.top + rect.height / 2, 0), doc.defaultView.innerHeight - 1);
    // rect here is frame-local for the hit test.
    const hit = (root instanceof ShadowRoot ? root : doc).elementFromPoint(x, y);
    if (!hit) return false;
    if (hit === el || el.contains(hit) || hit.contains(el)) return false;
    // A label and its control cover each other legitimately.
    if (hit instanceof HTMLLabelElement && hit.control === el) return false;
    if (el instanceof HTMLLabelElement && el.control === hit) return false;
    // Shadow hosts: the hit may be the host of the element's tree.
    const hostOfHit = hit.shadowRoot;
    if (hostOfHit && hostOfHit.contains(el)) return false;
    return true;
  }

  // MARK: - Accessible name (accname 1.2, reduced)

  function textOfReferenced(el, attribute) {
    const ids = clean(el.getAttribute(attribute)).split(" ").filter(Boolean);
    if (ids.length === 0) return "";
    const root = el.getRootNode();
    return clean(ids.map((id) => {
      const target = root.getElementById ? root.getElementById(id) : el.ownerDocument.getElementById(id);
      return target ? nameFromContent(target, new Set(), true) : "";
    }).filter(Boolean).join(" "));
  }

  function nativeName(el) {
    const tag = el.localName;
    if (tag === "input") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (type === "submit" || type === "reset" || type === "button") {
        return clean(el.value) || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : "");
      }
      if (type === "image") return clean(el.getAttribute("alt")) || clean(el.getAttribute("title"));
    }
    if (tag === "img" || tag === "area") return clean(el.getAttribute("alt"));
    if (tag === "input" || tag === "textarea" || tag === "select" || tag === "meter" || tag === "progress" || tag === "output") {
      const labels = el.labels ? Array.from(el.labels) : [];
      const fromLabels = clean(labels.map((label) => nameFromContent(label, new Set([el]), false)).filter(Boolean).join(" "));
      if (fromLabels) return fromLabels;
    }
    if (tag === "fieldset") {
      const legend = Array.from(el.children).find((child) => child.localName === "legend");
      if (legend) return nameFromContent(legend, new Set(), false);
    }
    if (tag === "table") {
      const caption = Array.from(el.children).find((child) => child.localName === "caption");
      if (caption) return nameFromContent(caption, new Set(), false);
    }
    if (tag === "figure") {
      const figcaption = Array.from(el.children).find((child) => child.localName === "figcaption");
      if (figcaption) return nameFromContent(figcaption, new Set(), false);
    }
    if (tag === "details") {
      const summary = Array.from(el.children).find((child) => child.localName === "summary");
      if (summary) return nameFromContent(summary, new Set(), false);
    }
    if (tag === "svg") {
      const title = el.querySelector(":scope > title");
      if (title) return clean(title.textContent);
    }
    if (tag === "iframe" || tag === "frame") return clean(el.getAttribute("title")) || clean(el.getAttribute("name"));
    return "";
  }

  // Walks composed children (shadow roots and slots included) collecting text.
  function nameFromContent(el, visited, allowHidden) {
    if (visited.has(el)) return "";
    visited.add(el);
    if (!allowHidden && (isHiddenByAttributes(el) || !isRendered(el))) return "";
    const labelled = el.getAttribute("aria-label");
    if (clean(labelled)) return clean(labelled);
    const parts = [];
    for (const child of composedChildren(el)) {
      if (child.nodeType === Node.TEXT_NODE) {
        parts.push(clean(child.data));
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        if (visited.has(child)) continue;
        if (child.localName === "br") { parts.push(" "); continue; }
        if (!allowHidden && (isHiddenByAttributes(child) || !isRendered(child))) continue;
        const childRole = roleOf(child);
        // Embedded controls contribute their value, not their own label.
        if (childRole === "textbox" || childRole === "searchbox" || childRole === "spinbutton") {
          parts.push(clean(child.value));
        } else if (childRole === "combobox" && child.localName === "select") {
          parts.push(clean(child.selectedOptions?.[0]?.label));
        } else {
          const own = clean(child.getAttribute("aria-label")) || (childRole === "img" ? nativeName(child) : "");
          parts.push(own || nameFromContent(child, visited, allowHidden));
        }
      }
    }
    const joined = clean(parts.join(" "));
    if (joined) return joined;
    return clean(el.getAttribute("title"));
  }

  function accessibleName(el, role) {
    const labelledBy = textOfReferenced(el, "aria-labelledby");
    if (labelledBy) return truncate(labelledBy, MAX_NAME);
    const ariaLabel = clean(el.getAttribute("aria-label"));
    if (ariaLabel) return truncate(ariaLabel, MAX_NAME);
    const native = nativeName(el);
    if (native) return truncate(native, MAX_NAME);
    if (NAME_FROM_CONTENT.has(role) || (role === "generic" && el.localName === "label")) {
      const content = nameFromContent(el, new Set(), false);
      if (content) return truncate(content, MAX_NAME);
    }
    const title = clean(el.getAttribute("title"));
    if (title) return truncate(title, MAX_NAME);
    const placeholder = clean(el.getAttribute("placeholder"));
    if (placeholder) return truncate(placeholder, MAX_NAME);
    const placeholderLike = clean(el.getAttribute("aria-placeholder"));
    if (placeholderLike) return truncate(placeholderLike, MAX_NAME);
    if (el.getAttribute("aria-describedby")) {
      const description = textOfReferenced(el, "aria-describedby");
      if (description) return truncate(description, MAX_NAME);
    }
    const tooltip = clean(el.getAttribute("data-tooltip")) || clean(el.getAttribute("data-title")) || clean(el.getAttribute("data-tooltip-text"));
    if (tooltip) return truncate(tooltip, MAX_NAME);
    return "";
  }

  // For a control with no accessible name at all, the page's own attribute
  // vocabulary often says what it is (name="search_query",
  // class="ytSearchboxComponentClearButton"). Rendered as a hint, never as
  // the name: the model should know it is guessing.
  const HINT_WORDS = /(search|clear|close|dismiss|submit|send|menu|next|prev|previous|back|forward|play|pause|mute|volume|settings|like|share|save|cart|checkout|login|signin|sign-in|logout|signup|add|remove|delete|edit|more|expand|collapse|toggle|filter|sort|upload|download|copy|refresh|reload|home|profile|account|help|info|notification|bell|chat|comment|reply|zoom|fullscreen|skip|cancel|confirm|ok|accept|decline|continue|apply|reset|select|open|query|email|password|username|phone|name|address|zip|postal|city|state|country|card|date|time|quantity|qty|price|amount)/i;
  function nameHint(el) {
    const candidates = [el.getAttribute("name"), el.getAttribute("id"), el.getAttribute("data-testid"), el.getAttribute("data-test"), el.getAttribute("data-qa"), el.getAttribute("data-a-target"), el.getAttribute("class")];
    for (const candidate of candidates) {
      const value = clean(candidate);
      if (!value) continue;
      // Split camelCase, kebab-case, snake_case; keep the tokens that say something.
      const words = value.replace(/([a-z])([A-Z])/g, "$1 $2").split(/[^A-Za-z]+/).filter((word) => word.length > 2 && HINT_WORDS.test(word));
      if (words.length > 0) return truncate(words.slice(0, 4).join(" ").toLowerCase(), 60);
    }
    return "";
  }

  // MARK: - Composed tree

  function composedChildren(el) {
    if (el.localName === "slot") {
      const assigned = el.assignedNodes({ flatten: true });
      if (assigned.length > 0) return assigned;
      return Array.from(el.childNodes);
    }
    if (el.shadowRoot) return Array.from(el.shadowRoot.childNodes);
    return Array.from(el.childNodes);
  }

  // MARK: - Sensitivity

  const CREDENTIAL_AUTOCOMPLETE = /(^|\s)(cc-number|cc-csc|cc-exp|cc-exp-month|cc-exp-year|current-password|new-password|one-time-code)(\s|$)/;
  const PERSONAL_AUTOCOMPLETE = /(^|\s)(name|given-name|family-name|username|email|tel|street-address|address-line1|address-line2|address-line3|postal-code|bday|organization|country|country-name|cc-name)(\s|$)/;

  function isCredentialField(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    const autocomplete = clean(el.getAttribute("autocomplete")).toLowerCase();
    return el.type === "password" || CREDENTIAL_AUTOCOMPLETE.test(autocomplete);
  }

  function isPersonalField(el) {
    if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) return false;
    const autocomplete = clean(el.getAttribute("autocomplete")).toLowerCase();
    return (el instanceof HTMLInputElement && (el.type === "email" || el.type === "tel"))
      || PERSONAL_AUTOCOMPLETE.test(autocomplete);
  }

  function formOf(el) {
    return el.form || el.closest("form");
  }

  function submitsSensitiveForm(el) {
    const form = formOf(el);
    if (!form) return false;
    const submits = el.matches("input[type='submit'],input[type='image']")
      || (el instanceof HTMLButtonElement && el.type === "submit");
    if (!submits) return false;
    return Array.from(form.elements || []).some((field) => isPersonalField(field) || isCredentialField(field));
  }

  // MARK: - Control kinds (the grounding vocabulary Candoa Cloud validates against)

  function controlKind(el, role) {
    if (role === "link") return "link";
    if (el.localName === "select") return "choice";
    if (CHOICE_ROLES.has(role)) return "choice";
    if (FIELD_ROLES.has(role) || role === "combobox") return "field";
    if (el.isContentEditable && el.contentEditable !== "inherit") return "field";
    return "button";
  }

  function isInteractive(el, role) {
    if (INTERACTIVE_ROLES.has(role)) return true;
    if (el.localName === "select" || el.localName === "textarea" || el.localName === "input") return true;
    if (el.isContentEditable && el.contentEditable !== "inherit") return true;
    if (role === "generic" || role === "presentation") {
      // Script-driven clickables: an onclick handler or a pointer cursor on
      // something that is not inside another control.
      if (el.hasAttribute("onclick")) return true;
      const tabIndex = el.getAttribute("tabindex");
      if (tabIndex !== null && Number(tabIndex) >= 0) return true;
    }
    return false;
  }

  function looksClickable(el, style) {
    return style.cursor === "pointer";
  }

  function isDisabled(el) {
    if (el.disabled === true) return true;
    if (el.getAttribute("aria-disabled") === "true") return true;
    const fieldset = el.closest("fieldset[disabled]");
    if (fieldset && !fieldset.querySelector(":scope > legend")?.contains(el)) return true;
    return false;
  }

  function isSelected(el) {
    if (el.checked === true) return true;
    if (el.selected === true) return true;
    if (el.getAttribute("aria-checked") === "true") return true;
    if (el.getAttribute("aria-selected") === "true") return true;
    if (el.getAttribute("aria-pressed") === "true") return true;
    return false;
  }

  function isCurrent(el) {
    const value = el.getAttribute("aria-current");
    return Boolean(value) && value !== "false";
  }

  function isExpanded(el) {
    const value = el.getAttribute("aria-expanded");
    if (value === "true") return true;
    if (value === "false") return false;
    if (el.localName === "details") return el.open;
    if (el.localName === "summary" && el.parentElement?.localName === "details") return el.parentElement.open;
    return null;
  }

  function optionsOf(el) {
    if (!(el instanceof HTMLSelectElement)) return [];
    return Array.from(el.options)
      .filter((option) => !option.disabled)
      .map((option) => clean(option.label || option.textContent))
      .filter(Boolean)
      .slice(0, 80);
  }

  function valueOf(el, role) {
    if (el instanceof HTMLSelectElement) return clean(el.selectedOptions?.[0]?.label);
    if (el instanceof HTMLInputElement) {
      if (el.type === "checkbox" || el.type === "radio" || el.type === "button" || el.type === "submit" || el.type === "reset" || el.type === "image" || el.type === "file") return "";
      return clean(el.value);
    }
    if (el instanceof HTMLTextAreaElement) return clean(el.value);
    if (role === "textbox" || role === "searchbox" || role === "combobox") {
      if (el.isContentEditable) return clean(el.innerText);
      return clean(el.getAttribute("aria-valuetext")) || clean(el.getAttribute("value"));
    }
    if (role === "slider" || role === "spinbutton" || role === "progressbar" || role === "meter") {
      return clean(el.getAttribute("aria-valuetext")) || clean(el.getAttribute("aria-valuenow")) || clean(el.value);
    }
    return "";
  }

  function linkURL(el) {
    if (el.localName !== "a" && el.localName !== "area") return "";
    const raw = clean(el.href || el.getAttribute("href"));
    return /^https?:\/\//i.test(raw) && raw.length <= 2000 ? raw : "";
  }

  // The compact form the tree prints: same-site links keep path and query,
  // other sites keep their host and path. The full URL still travels in the
  // controls list for grounding.
  function compactHref(url) {
    try {
      const parsed = new URL(url);
      const sameSite = parsed.host === location.host;
      const path = `${parsed.pathname}${parsed.search}`;
      const shown = sameSite ? path : `${parsed.host}${path}`;
      return truncate(shown === "" ? "/" : shown, 80);
    } catch {
      return "";
    }
  }

  // MARK: - Registry

  // Refs index into `elements`; the snapshot ID ties an action to the walk
  // that produced the ref. Kept on the content-world window, invisible to
  // the page.
  function registry() {
    return window.__candoaAgentRegistry || null;
  }

  function setRegistry(id, entries) {
    window.__candoaAgentSnapshotID = id;
    window.__candoaAgentRegistry = { id, entries };
  }

  function lookup(snapshotID, ref) {
    const current = registry();
    if (!current || current.id !== snapshotID) return { error: "Candoa stopped because the page changed after it was inspected." };
    const match = /^e(\d{1,3})$/.exec(String(ref));
    if (!match) return { error: "Candoa rejected an unknown control reference." };
    const entry = current.entries[Number(match[1])];
    if (!entry || !entry.element.isConnected) return { error: "Candoa stopped because the referenced control is no longer on the page." };
    return { entry };
  }

  // MARK: - Events

  // Frameworks that own an input's value (React) track it through the
  // prototype setter; assigning `.value` directly leaves their tracker stale
  // and the change is ignored. Going through the prototype keeps them in sync.
  function setNativeValue(el, value) {
    const prototype = el instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : el instanceof HTMLSelectElement
        ? HTMLSelectElement.prototype
        : HTMLInputElement.prototype;
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
    if (descriptor && descriptor.set) descriptor.set.call(el, value);
    else el.value = value;
  }

  function fire(el, type, init = {}) {
    const EventClass = type.startsWith("key") ? KeyboardEvent : type === "input" ? InputEvent : Event;
    return el.dispatchEvent(new EventClass(type, { bubbles: true, cancelable: true, composed: true, ...init }));
  }

  const KEY_CODES = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Backspace: 8, " ": 32, Space: 32 };

  function keyInit(key) {
    const normalized = key === "Space" ? " " : key;
    return { key: normalized, code: key === " " ? "Space" : key, keyCode: KEY_CODES[key] || 0, which: KEY_CODES[key] || 0 };
  }

  return {
    MAX_NODES, MAX_REFS, MAX_NAME, MAX_TEXT, MAX_VALUE,
    LANDMARKS, INTERACTIVE_ROLES, CHOICE_ROLES, FIELD_ROLES,
    clean, truncate,
    roleOf, isFocusable,
    isHiddenByAttributes, isRendered, hasBox, boundingBox, viewportRect, placementOf, isOccluded,
    accessibleName, nameHint, nameFromContent, composedChildren,
    isCredentialField, isPersonalField, submitsSensitiveForm, formOf,
    controlKind, isInteractive, looksClickable, isDisabled, isSelected, isCurrent, isExpanded,
    optionsOf, valueOf, linkURL, compactHref,
    registry, setRegistry, lookup,
    setNativeValue, fire, keyInit
  };
})();
