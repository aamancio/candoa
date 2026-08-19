enum WebPageScripts {
    static let mediaStateMessageName = "candoaMediaState"
    static let linkHoverMessageName = "candoaLinkHover"
    static let popupDiagnosticsMessageName = "candoaPopupDiagnostics"
    static let webStoreInstallMessageName = "candoaWebStoreInstall"

    /// UI-testing only: reports each page's opener linkage so tests can see
    /// inside cross-origin popups (e.g. OAuth flows) that XCUITest can't reach.
    static let popupDiagnosticsScript = """
    (() => {
      const report = (phase) => {
        window.webkit?.messageHandlers?.\(popupDiagnosticsMessageName)?.postMessage({
          phase,
          href: location.href,
          opener: window.opener !== null,
          name: window.name || ""
        });
      };
      report("start");
      addEventListener("pagehide", () => report("pagehide"));
    })();
    """

    /// Chrome Web Store detail pages, made installable. The store hard-codes
    /// its "Add to Chrome" button to `chrome.webstorePrivate` and ships it
    /// disabled to every non-Chrome browser, so Candoa relabels that same
    /// button, re-enables it, and takes the click itself — the native side
    /// then downloads the item's CRX and installs it (see `ChromeWebStore`).
    ///
    /// Every class name on the page is obfuscated and rotates, so nothing
    /// here selects on one. The button is found by what it says (the brand
    /// name "Chrome" survives in every locale the store translates into) plus
    /// the fact that the store disabled it for us; the "Install Chrome"
    /// banner is told apart by being enabled and carrying the banner's own
    /// copy in its `aria-label`, and its container is hidden — a Chrome
    /// download is not the answer to a page Candoa can install from.
    static var chromeWebStoreScript: String {
        """
        (() => {
          const HOSTS = ["chromewebstore.google.com", "chrome.google.com"];
          if (!HOSTS.includes(location.hostname)) { return; }

          const LABEL_ADD = \(jsStringLiteral(String(localized: "Add to Candoa")));
          const LABEL_BUSY = \(jsStringLiteral(String(localized: "Adding…")));
          const LABEL_DONE = \(jsStringLiteral(String(localized: "Added to Candoa")));
          const ITEM_PATTERN = /\\/detail\\/(?:[^/]+\\/)?([a-p]{32})/;

          let pending = null;

          const itemID = () => {
            const match = location.pathname.match(ITEM_PATTERN);
            return match ? match[1] : null;
          };

          // Theme pages are left exactly as the store shipped them: a Chrome
          // theme paints a Chrome window, and Candoa dresses its own from
          // Spaces. The category chip links to the themes category, which is
          // an href rather than one of the page's rotating class names.
          const isTheme = () => document.querySelector('a[href*="category/themes"]') !== null;

          // Material buttons keep their text in a labelled span; falling back
          // to the button itself would drop its ripple spans, so only do that
          // when the span is gone.
          const labelNode = (button) => button.querySelector('[jsname="V67aGc"]') || button;

          const setLabel = (button, text) => {
            labelNode(button).textContent = text;
            button.setAttribute("aria-label", text);
          };

          const candidates = () => Array.prototype.filter.call(
            document.querySelectorAll("button"),
            (button) => button.dataset.candoaStore === "1" || /chrome/i.test(button.textContent || "")
          );

          const onClick = (event) => {
            const button = event.currentTarget;
            // The store's own click handler is delegated to an ancestor;
            // stopping the event here is what keeps it out of it.
            event.preventDefault();
            event.stopImmediatePropagation();
            const id = itemID();
            if (!id || button.dataset.candoaState === "busy" || button.dataset.candoaState === "done") { return; }
            button.dataset.candoaState = "busy";
            pending = button;
            setLabel(button, LABEL_BUSY);
            window.webkit?.messageHandlers?.\(webStoreInstallMessageName)?.postMessage({
              itemID: id,
              name: document.querySelector("h1")?.textContent?.trim() || ""
            });
          };

          const adopt = (button) => {
            if (button.dataset.candoaStore === "1") {
              // Re-renders put the store's `disabled` back; take it off again,
              // unless this button already finished installing.
              if (button.disabled && button.dataset.candoaState !== "done") { button.disabled = false; }
              return;
            }
            button.dataset.candoaStore = "1";
            button.disabled = false;
            button.removeAttribute("aria-disabled");
            setLabel(button, LABEL_ADD);
            button.addEventListener("click", onClick, true);
          };

          // Hide the "Switch to Chrome" strip, and nothing else. Two guards
          // matter: an already-hidden button has no offsetParent, which stops
          // a hidden strip from sending the next pass up to hide its parent
          // too, and a strip is wide but short — hitting anything tall means
          // this is page content, so hide nothing at all.
          const hideBanner = (button) => {
            if (!button.offsetParent) { return; }
            if (button.getBoundingClientRect().top + window.scrollY > 400) { return; }
            let strip = null;
            let node = button;
            for (let depth = 0; depth < 6; depth += 1) {
              node = node.parentElement;
              if (!node || node === document.body) { break; }
              const rect = node.getBoundingClientRect();
              if (rect.height > 160) { break; }
              if (rect.width >= document.documentElement.clientWidth * 0.5) { strip = node; }
            }
            if (strip) { strip.style.display = "none"; }
          };

          const sync = () => {
            if (!itemID() || isTheme()) { return; }
            candidates().forEach((button) => {
              if (button.dataset.candoaStore === "1" || button.disabled) {
                adopt(button);
              } else if ((button.getAttribute("aria-label") || "").length > (button.textContent || "").length + 4) {
                hideBanner(button);
              }
            });
          };

          // The native side answers every request, so a button never sits on
          // "Adding…" forever.
          window.__candoaWebStoreResult = (state) => {
            const button = pending;
            pending = null;
            if (!button) { return; }
            if (state === "installed") {
              button.dataset.candoaState = "done";
              button.disabled = true;
              setLabel(button, LABEL_DONE);
            } else {
              button.dataset.candoaState = "";
              setLabel(button, LABEL_ADD);
            }
          };

          // The store is a single-page app: item pages swap in without a
          // navigation, so re-run on every DOM change rather than once.
          const start = () => {
            sync();
            new MutationObserver(() => sync()).observe(document.documentElement, {
              childList: true,
              subtree: true
            });
          };
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", start, { once: true });
          } else {
            start();
          }
        })();
        """
    }

    /// Link-destination preview: posts the hovered link's resolved URL, or
    /// null when the pointer leaves links entirely. Injected into every frame
    /// so embeds report too. Purely event-driven — the `lastHref` guard
    /// coalesces the mouseover storm of nested elements down to messages
    /// only when the hovered link actually changes, and a page nobody is
    /// pointing at posts nothing at all.
    static let linkHoverObserverScript = """
    (() => {
      if (window.__candoaLinkHoverObserved) { return; }
      window.__candoaLinkHoverObserved = true;

      let lastHref = null;

      const resolvedHref = (link) => {
        if (!link) { return null; }
        // SVG <a> exposes href as SVGAnimatedString; HTML anchors resolve
        // relative paths through the frame's own base URI either way.
        const raw = typeof link.href === "object" && link.href !== null
          ? link.href.baseVal
          : link.getAttribute("href");
        if (raw == null || raw === "") { return null; }
        try {
          return new URL(raw, document.baseURI).href;
        } catch {
          return null;
        }
      };

      const post = (href) => {
        if (href === lastHref) { return; }
        lastHref = href;
        window.webkit?.messageHandlers?.\(linkHoverMessageName)?.postMessage({ href });
      };

      document.addEventListener("mouseover", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        post(resolvedHref(target?.closest("a[href], area[href]")));
      }, { capture: true, passive: true });

      document.addEventListener("mouseout", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const from = target?.closest("a[href], area[href]");
        if (!from) { return; }
        const to = event.relatedTarget instanceof Element
          ? event.relatedTarget.closest("a[href], area[href]")
          : null;
        // Moving onto another link raises its own mouseover; only leaving
        // links for plain page (or leaving the view) clears.
        if (!to) { post(null); }
      }, { capture: true, passive: true });

      window.addEventListener("pagehide", () => post(null));
    })();
    """

    /// Hibernation guard: anything the user may have typed keeps the page
    /// alive, because tearing down the web view would lose that input.
    static let unsavedInputCheckScript = """
    (() => {
      const hasDirtyField = Array.from(document.querySelectorAll("input, textarea")).some((field) => {
        if (field.type === "checkbox" || field.type === "radio") {
          return field.checked !== field.defaultChecked;
        }
        if (["hidden", "submit", "button", "image", "reset"].includes(field.type)) {
          return false;
        }
        return field.value !== field.defaultValue;
      });
      if (hasDirtyField) { return true; }

      return Array.from(document.querySelectorAll("[contenteditable='true']"))
        .some((editor) => editor.textContent.trim().length > 0);
    })();
    """

    static let readablePageTextScript = """
    (() => {
      const limit = 30000;
      const root = document.body;
      if (!root) { return ""; }

      const clone = root.cloneNode(true);
      clone.querySelectorAll([
        "script",
        "style",
        "noscript",
        "svg",
        "template",
        "canvas",
        "iframe",
        "[aria-hidden='true']"
      ].join(",")).forEach((node) => node.remove());

      clone.querySelectorAll("img").forEach((image) => {
        const label = [image.alt, image.title, image.getAttribute("aria-label")]
          .map((value) => String(value || "").trim())
          .find((value) => value.length > 0);
        if (label) {
          image.replaceWith(document.createTextNode(` Image: ${label} `));
        } else {
          image.remove();
        }
      });

      const cleanControlLabel = (control) => {
        const labelledByText = String(control.getAttribute("aria-labelledby") || "")
          .split(/\\s+/)
          .filter(Boolean)
          .map((id) => String(clone.querySelector(`#${CSS.escape(id)}`)?.textContent || "").trim())
          .filter(Boolean)
          .join(" ");
        const associatedLabelText = Array.from(control.labels || [])
          .map((label) => String(label.innerText || label.textContent || "").trim())
          .filter(Boolean)
          .join(" ");
        const explicitLabelText = control.id
          ? String(clone.querySelector(`label[for="${CSS.escape(control.id)}"]`)?.textContent || "").trim()
          : "";
        const wrappingLabelText = String(control.closest("label")?.textContent || "").trim();

        return [
          control.getAttribute("aria-label"),
          labelledByText,
          associatedLabelText,
          explicitLabelText,
          wrappingLabelText,
          control.placeholder,
          control.title,
          control.value,
          control.innerText,
          control.textContent
        ]
          .map((value) => String(value || "").trim())
          .find((value) => value.length > 0) || "";
      };

      clone.querySelectorAll([
        "input",
        "textarea",
        "select",
        "button",
        "[role='button']",
        "[role='radio']",
        "[role='option']",
        "[role='checkbox']",
        "[role='combobox']",
        "[role='slider']",
        "[role='spinbutton']",
        "[role='tab']"
      ].join(",")).forEach((control) => {
        const label = cleanControlLabel(control);
        if (label) {
          const role = String(control.getAttribute("role") || control.tagName || "control").toLowerCase();
          control.replaceWith(document.createTextNode(` ${role}: ${label} `));
        } else {
          control.remove();
        }
      });

      clone.querySelectorAll("a[href]").forEach((link) => {
        const label = String(link.innerText || link.textContent || link.getAttribute("aria-label") || link.href || "").trim();
        if (label) {
          link.replaceWith(document.createTextNode(` Link: ${label} `));
        } else {
          link.remove();
        }
      });

      const description = document.querySelector("meta[name='description']")?.content || "";
      const clean = (value) => String(value || "")
        .replace(/[\\s\\n\\r\\t]+/g, " ")
        .trim();
      const blockSelectors = [
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "p",
        "li",
        "dt",
        "dd",
        "figcaption",
        "caption",
        "th",
        "td",
        "label",
        "legend",
        "option",
        "summary",
        "[role='heading']",
        "[role='listitem']",
        "[role='radio']"
      ].join(",");
      const seenLines = new Set();
      const bodyLines = Array.from(clone.querySelectorAll(blockSelectors))
        .map((element) => clean(element.innerText || element.textContent))
        .filter((line) => {
          if (!line || seenLines.has(line)) { return false; }
          seenLines.add(line);
          return true;
        });

      const fallbackText = clean(clone.innerText || clone.textContent);
      const text = [
        document.title || "",
        description,
        bodyLines.length ? bodyLines.join("\\n") : fallbackText
      ]
        .join("\\n\\n")
        .replace(/[ \\t\\f\\v]+/g, " ")
        .replace(/\\n{3,}/g, "\\n\\n")
        .trim();

      return text.slice(0, limit);
    })();
    """

    /// Find in Page.
    ///
    /// `WKWebView.find` only moves the page selection, which WebKit paints in
    /// its inactive grey — and paints not at all — while the find field holds
    /// keyboard focus, so matches were effectively invisible. Safari solves
    /// this with private WebKit find-overlay SPI; the public equivalent is the
    /// CSS Custom Highlight API, which tints ranges without touching the DOM.
    ///
    /// The engine is stateless between calls apart from the ranges it is
    /// currently showing: no observers, no timers, and nothing that outlives
    /// `findClearScript` or the next navigation.
    static func findScript(query: String, forward: Bool) -> String {
        """
        (() => {
          const query = \(jsStringLiteral(query));
          const forward = \(forward);
          const ALL = "candoa-find";
          const ACTIVE = "candoa-find-active";
          const STYLE_ID = "candoa-find-style";
          const LIMIT = 5000;

          if (typeof CSS === "undefined" || !CSS.highlights || typeof Highlight !== "function") {
            return { supported: false, count: 0, index: 0 };
          }

          const INDICATOR_ID = "candoa-find-indicator";
          const SCRIM_ID = "candoa-find-scrim";
          const MAX_HOLES = 400;
          const state = window.__candoaFind || (window.__candoaFind = { query: "", ranges: [], index: -1 });

          // Safari dims the whole page and cuts every match out of the dim, so
          // the matches read as the only lit text. The scrim is one absolutely
          // positioned layer in document coordinates, which means the page
          // scrolls it for free — no scroll handler, nothing running per frame.
          const canCutOut = typeof CSS.supports === "function"
            && CSS.supports("clip-path", "path(evenodd, \\"M0 0Z\\")");

          const hole = (x, y, w, h) => {
            const r = Math.min(3, w / 2, h / 2);
            const round = (value) => value.toFixed(1);
            return "M" + round(x + r) + " " + round(y) +
              "H" + round(x + w - r) + "A" + round(r) + " " + round(r) + " 0 0 1 " + round(x + w) + " " + round(y + r) +
              "V" + round(y + h - r) + "A" + round(r) + " " + round(r) + " 0 0 1 " + round(x + w - r) + " " + round(y + h) +
              "H" + round(x + r) + "A" + round(r) + " " + round(r) + " 0 0 1 " + round(x) + " " + round(y + h - r) +
              "V" + round(y + r) + "A" + round(r) + " " + round(r) + " 0 0 1 " + round(x + r) + " " + round(y) + "Z";
          };

          const dim = () => {
            document.getElementById(SCRIM_ID)?.remove();
            if (!canCutOut || !state.ranges.length || !document.body) { return false; }

            const root = document.documentElement;
            const width = Math.max(root.scrollWidth, document.body.scrollWidth);
            const height = Math.max(root.scrollHeight, document.body.scrollHeight);

            let path = "M0 0H" + width + "V" + height + "H0Z";
            let holes = 0;
            for (const range of state.ranges) {
              for (const rect of range.getClientRects()) {
                if (holes >= MAX_HOLES) { break; }
                // Same inset as the indicator's box, so the lit match and the
                // hole in the dim are exactly the same shape.
                path += hole(
                  rect.left + window.scrollX - 2.5,
                  rect.top + window.scrollY - 1.5,
                  rect.width + 5,
                  rect.height + 3
                );
                holes += 1;
              }
              if (holes >= MAX_HOLES) { break; }
            }

            const scrim = document.createElement("div");
            scrim.id = SCRIM_ID;
            scrim.setAttribute("aria-hidden", "true");
            scrim.style.cssText = [
              "position:absolute",
              "left:0",
              "top:0",
              "width:" + width + "px",
              "height:" + height + "px",
              "z-index:2147483646",
              "pointer-events:none",
              "user-select:none",
              // Dim depth measured against Safari on the same screen, by
              // comparing each browser's own page with find on and off.
              "background:rgba(0, 0, 0, 0.22)",
              "clip-path:path(evenodd, \\"" + path + "\\")",
              "animation:candoa-find-dim 0.15s ease-out"
            ].join(";");
            document.body.appendChild(scrim);
            return true;
          };

          // Safari's find indicator, measured off a screen recording of it:
          // the current match pops to 1.24x about 60ms in and settles back by
          // 150ms. It has to be a real element, because a highlight pseudo
          // cannot be transformed — one node, replaced whenever the current
          // match moves and removed with everything else on clear.
          //
          // A match split by inline markup ("Goo<b>gle</b>") is drawn as one
          // fragment per text node, each in that node's own font, inside a
          // single rounded container that clips them into one seamless bubble
          // and carries the animation so they scale together.
          const indicate = (fragments) => {
            document.getElementById(INDICATOR_ID)?.remove();
            if (!document.body || !fragments.length) { return; }

            const boxes = [];
            for (const fragment of fragments) {
              const rects = fragment.getClientRects();
              const anchor = fragment.startContainer.parentElement;
              // A fragment that wraps mid-word has no single box to pop, and
              // neither does a match spread down the page: leave those to the
              // highlight alone.
              if (rects.length !== 1 || !anchor) { return; }
              if (boxes.length && Math.abs(rects[0].top - boxes[0].rect.top) > 1) { return; }
              boxes.push({ rect: rects[0], anchor, text: fragment.toString() });
            }

            const left = Math.min(...boxes.map((box) => box.rect.left));
            const top = Math.min(...boxes.map((box) => box.rect.top));
            const right = Math.max(...boxes.map((box) => box.rect.right));
            const bottom = Math.max(...boxes.map((box) => box.rect.bottom));

            const bubble = document.createElement("div");
            bubble.id = INDICATOR_ID;
            bubble.setAttribute("aria-hidden", "true");
            bubble.style.cssText = [
              "position:absolute",
              "z-index:2147483647",
              "pointer-events:none",
              "user-select:none",
              "overflow:hidden",
              // The fill lives on the container, so the yellow reaches the
              // rounded corners instead of leaving the cut-out showing as a
              // pale ring around the text.
              "background:#ffff00",
              "border-radius:4px",
              "box-shadow:0 1px 3px rgba(0, 0, 0, 0.4)",
              "transform-origin:center",
              "animation:candoa-find-pop 0.11s linear",
              "left:" + (left + window.scrollX - 2.5) + "px",
              "top:" + (top + window.scrollY - 1.5) + "px",
              "width:" + (right - left + 5) + "px",
              "height:" + (bottom - top + 3) + "px"
            ].join(";");

            for (const box of boxes) {
              const font = getComputedStyle(box.anchor);
              const piece = document.createElement("div");
              piece.textContent = box.text;
              piece.style.cssText = [
                "position:absolute",
                "color:#000",
                "white-space:pre",
                "left:" + (box.rect.left - left + 2.5) + "px",
                "top:0px",
                "height:100%",
                "line-height:" + (bottom - top + 3) + "px",
                "font-family:" + font.fontFamily,
                "font-size:" + font.fontSize,
                "font-weight:" + font.fontWeight,
                "font-style:" + font.fontStyle,
                "font-stretch:" + font.fontStretch,
                "letter-spacing:" + font.letterSpacing,
                "word-spacing:" + font.wordSpacing,
                "text-transform:" + font.textTransform
              ].join(";");
              bubble.appendChild(piece);
            }

            // Like Safari's, the bubble stays on the current match rather than
            // fading: it is positioned in document coordinates, so the page
            // scrolls it, and stepping or clearing replaces it.
            document.body.appendChild(bubble);
          };

          const show = (rebuildScrim) => {
            if (!state.ranges.length) {
              // A query with no matches leaves nothing behind in the page.
              CSS.highlights.delete(ALL);
              CSS.highlights.delete(ACTIVE);
              document.getElementById(INDICATOR_ID)?.remove();
              document.getElementById(SCRIM_ID)?.remove();
              document.getElementById(STYLE_ID)?.remove();
              return;
            }
            if (!document.getElementById(STYLE_ID)) {
              const style = document.createElement("style");
              style.id = STYLE_ID;
              // Safari's own find colors: a soft yellow on every match, pure
              // yellow on the current one, both with a forced dark foreground
              // so the tint stays legible over any page palette.
              style.textContent =
                "::highlight(" + ALL + ") { background-color: #ffe066; color: #000; }" +
                "::highlight(" + ACTIVE + ") { background-color: #ffff00; color: #000; }" +
                "@keyframes candoa-find-dim { from { opacity: 0; } to { opacity: 1; } }" +
                // Sampled off a screen recording of Safari at 16ms, then
                // replayed here as linear stops so the motion is the same
                // curve rather than an approximation of it: it appears
                // already grown, peaks at 1.25 about 32ms in, and eases back
                // to rest by 96ms.
                "@keyframes candoa-find-pop {" +
                "  0% { transform: scale(1.10); }" +
                "  29% { transform: scale(1.25); }" +
                "  44% { transform: scale(1.17); }" +
                "  58% { transform: scale(1.10); }" +
                "  73% { transform: scale(1.05); }" +
                "  100% { transform: scale(1); }" +
                "}" +
                "@media (prefers-reduced-motion: reduce) {" +
                "  #" + INDICATOR_ID + " { animation: none; }" +
                "}";
              (document.head || document.documentElement).appendChild(style);
            }
            // Cutting the matches out of the dim is Safari's treatment, and
            // it leaves them in the page's own colors. The yellow wash on
            // every match is the fallback for pages the scrim cannot cover.
            const cutOut = rebuildScrim ? dim() : !!document.getElementById(SCRIM_ID);
            if (cutOut) {
              CSS.highlights.delete(ALL);
            } else {
              CSS.highlights.set(ALL, new Highlight(...state.ranges));
            }

            const active = state.ranges[state.index];
            CSS.highlights.set(ACTIVE, new Highlight(active));


            const rect = active.getBoundingClientRect();
            const fullyVisible = rect.top >= 0 && rect.bottom <= (window.innerHeight || 0);
            if (!fullyVisible) {
              // scrollIntoView on the containing element, so matches inside a
              // nested scroller are revealed too. Never animated: Find is a
              // keyboard-repeat surface and Reduce Motion must hold.
              const anchor = active.startContainer.parentElement;
              anchor?.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
            }
            indicate(state.fragments[state.index] || []);
          };

          if (state.query === query && state.ranges.length) {
            // Stepping does not move any match, so the scrim it already cut
            // stays valid and is left alone.
            state.index = (state.index + (forward ? 1 : -1) + state.ranges.length) % state.ranges.length;
            show(false);
            return { supported: true, count: state.ranges.length, index: state.index + 1 };
          }

          // Text nodes are concatenated so a match can span inline markup
          // ("Goo<b>gle</b>"), with a newline between block containers so it
          // can never span two of them — the same boundary WebKit's own find
          // respects.
          const BLOCKS = new Set([
            "ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "BODY", "BR", "DD", "DIV", "DL", "DT",
            "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2", "H3", "H4", "H5",
            "H6", "HEADER", "HR", "LI", "MAIN", "NAV", "OL", "P", "PRE", "SECTION", "TABLE",
            "TBODY", "TD", "TFOOT", "TH", "THEAD", "TR", "UL"
          ]);
          const SKIPPED = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TITLE", "TEXTAREA"]);
          const visibility = new Map();
          const isVisible = (element) => {
            if (visibility.has(element)) { return visibility.get(element); }
            const visible = typeof element.checkVisibility === "function"
              ? element.checkVisibility({ checkVisibilityCSS: true })
              : true;
            visibility.set(element, visible);
            return visible;
          };
          const blocks = new Map();
          const blockOf = (element) => {
            if (blocks.has(element)) { return blocks.get(element); }
            let node = element;
            while (node && !BLOCKS.has(node.nodeName)) { node = node.parentElement; }
            blocks.set(element, node);
            return node;
          };

          const walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            {
              acceptNode(node) {
                const parent = node.parentElement;
                if (!parent || SKIPPED.has(parent.nodeName)) { return NodeFilter.FILTER_REJECT; }
                if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
                return isVisible(parent) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
              }
            }
          );

          const pieces = [];
          let haystack = "";
          let lastBlock = null;
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const block = blockOf(node.parentElement);
            if (lastBlock !== null && block !== lastBlock) { haystack += "\\n"; }
            lastBlock = block;
            pieces.push({ node, start: haystack.length, end: haystack.length + node.nodeValue.length });
            haystack += node.nodeValue;
          }

          const pieceAt = (offset) => {
            let low = 0;
            let high = pieces.length - 1;
            while (low <= high) {
              const middle = (low + high) >> 1;
              const piece = pieces[middle];
              if (offset < piece.start) { high = middle - 1; }
              else if (offset >= piece.end) { low = middle + 1; }
              else { return middle; }
            }
            return -1;
          };

          const needle = query.toLowerCase();
          const text = haystack.toLowerCase();
          const ranges = [];
          const fragments = [];
          for (let at = text.indexOf(needle); at !== -1 && ranges.length < LIMIT; at = text.indexOf(needle, at + needle.length)) {
            const stop = at + needle.length;
            const first = pieceAt(at);
            const last = pieceAt(stop - 1);
            if (first === -1 || last === -1) { continue; }
            const startPiece = pieces[first];
            const endPiece = pieces[last];
            const range = document.createRange();
            range.setStart(startPiece.node, at - startPiece.start);
            range.setEnd(endPiece.node, stop - endPiece.start);
            ranges.push(range);

            // One subrange per text node the match covers, so the indicator
            // can draw each fragment in the font it is actually rendered in.
            const parts = [];
            for (let index = first; index <= last; index += 1) {
              const piece = pieces[index];
              const part = document.createRange();
              part.setStart(piece.node, Math.max(at, piece.start) - piece.start);
              part.setEnd(piece.node, Math.min(stop, piece.end) - piece.start);
              parts.push(part);
            }
            fragments.push(parts);
          }

          state.query = query;
          state.ranges = ranges;
          state.fragments = fragments;
          state.index = ranges.length ? (forward ? 0 : ranges.length - 1) : -1;
          show(true);
          return { supported: true, count: ranges.length, index: state.index + 1 };
        })();
        """
    }

    static let findClearScript = """
    (() => {
      if (typeof CSS !== "undefined" && CSS.highlights) {
        CSS.highlights.delete("candoa-find");
        CSS.highlights.delete("candoa-find-active");
      }
      document.getElementById("candoa-find-indicator")?.remove();
      document.getElementById("candoa-find-scrim")?.remove();
      document.getElementById("candoa-find-style")?.remove();
      delete window.__candoaFind;
    })();
    """

    /// A JavaScript string literal for `value`. JSON string syntax is a subset
    /// of JavaScript's, and escaping `<` keeps the result safe to inline.
    private static func jsStringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{2028}": escaped += "\\u2028"
            case "\u{2029}": escaped += "\\u2029"
            case "<": escaped += "\\u003C"
            default:
                if character.value < 0x20 {
                    let hex = String(character.value, radix: 16, uppercase: true)
                    escaped += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        return "\"\(escaped)\""
    }

    static let visiblePageControlsScript = """
    (() => {
      const selectors = [
        "a[href]",
        "button",
        "input",
        "textarea",
        "select",
        "label[for]",
        "[role='button']",
        "[role='link']",
        "[role='searchbox']",
        "[role='textbox']",
        "[role='combobox']",
        "[role='radio']",
        "[role='option']",
        "[role='checkbox']",
        "[role='slider']",
        "[role='spinbutton']",
        "[role='tab']"
      ].join(",");
      const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
      const seen = new Set();

      const clean = (value) => String(value || "")
        .replace(/[\\s\\n\\r\\t]+/g, " ")
        .trim();

      const labelFor = (element) => {
        const childImageText = Array.from(element.querySelectorAll("img"))
          .map((image) => clean([image.alt, image.title, image.getAttribute("aria-label")].find((candidate) => clean(candidate).length > 0)))
          .filter(Boolean)
          .join(" ");
        const ariaLabelledBy = clean(element.getAttribute("aria-labelledby"));
        const labelledByText = ariaLabelledBy
          .split(" ")
          .map((id) => clean(document.getElementById(id)?.innerText || document.getElementById(id)?.textContent))
          .filter(Boolean)
          .join(" ");
        const explicitLabel = element.id
          ? clean(document.querySelector(`label[for="${CSS.escape(element.id)}"]`)?.innerText)
          : "";
        const wrappingLabel = clean(element.closest("label")?.innerText);
        return clean([
          element.getAttribute("aria-label"),
          labelledByText,
          explicitLabel,
          wrappingLabel,
          element.placeholder,
          element.title,
          element.alt,
          childImageText,
          element.value,
          element.innerText,
          element.innerText || element.textContent,
          element.textContent
        ].find((candidate) => clean(candidate).length > 0));
      };

      const locationFor = (rect) => {
        const horizontal = rect.left < viewportWidth * 0.33
          ? "left"
          : rect.left > viewportWidth * 0.66 ? "right" : "center";
        const vertical = rect.top < viewportHeight * 0.33
          ? "top"
          : rect.top > viewportHeight * 0.66 ? "bottom" : "middle";
        return `${vertical} ${horizontal}`;
      };

      const priceFor = (element) => {
        let candidate = element;
        for (let depth = 0; candidate && depth < 6; depth += 1, candidate = candidate.parentElement) {
          const text = clean(candidate.innerText || candidate.textContent);
          if (!text || text.length > 900) { continue; }
          const preferred = text.match(/(?:from|starting at|starts at|now)\\s*\\$\\s*([0-9][0-9,]*(?:\\.[0-9]{2})?)/i);
          if (preferred) { return preferred[1].replaceAll(",", ""); }
        }
        return "";
      };

      const rows = Array.from(document.querySelectorAll(selectors))
        .filter((element) => {
          if (!(element instanceof HTMLElement)) { return false; }
          if (element.closest("[aria-hidden='true'], [hidden]")) { return false; }
          const rect = element.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) { return false; }
          if (rect.bottom < 0 || rect.right < 0 || rect.top > viewportHeight || rect.left > viewportWidth) { return false; }
          const style = window.getComputedStyle(element);
          return style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || "1") > 0.05;
        })
        .map((element) => {
          const rect = element.getBoundingClientRect();
          const role = clean(element.getAttribute("role")) || element.tagName.toLowerCase();
          const label = labelFor(element);
          const href = element.href ? clean(element.href) : "";
          const price = priceFor(element);
          const type = clean(element.getAttribute("type"));
          const key = clean(`${role}|${type}|${label}|${href}|${Math.round(rect.top)}|${Math.round(rect.left)}`);
          if (seen.has(key)) { return null; }
          seen.add(key);
          if (!label && !href) { return null; }
          return `- ${role}${type ? ` (${type})` : ""}: ${label || href}${price ? ` [price: ${price}]` : ""} [visible: ${locationFor(rect)}]${href ? ` [url: ${href}]` : ""}`;
        })
        .filter(Boolean)
        .slice(0, 80);

      return rows.length ? `Visible page controls and links:\\n${rows.join("\\n")}` : "";
    })();
    """

    /// YouTube parks a playing video in its own corner miniplayer when any
    /// in-site navigation leaves the watch page — Back, the logo, Home, a
    /// sidebar link — and restores that miniplayer on later visits from its
    /// own session state. Candoa's floating player owns background playback
    /// (it appears only on tab switch), so the site's copy only ever shows up
    /// as a stray — auto-close it. Deliberate summons (the `i` shortcut or
    /// the player's miniplayer button) also ride a navigation, so they mark
    /// themselves exempt just before it fires. Forward SPA navigations are
    /// caught via `yt-navigate-start`, which YouTube dispatches before it
    /// moves the video into the miniplayer host (`history.pushState` is not
    /// observable — the site captures it before injected scripts run).
    static let youtubeMiniplayerGuardScript = """
    (() => {
      if (window.__candoaYouTubeMiniplayerGuarded) { return; }
      if (!/(^|[.])youtube[.]com$/.test(location.hostname)) { return; }
      window.__candoaYouTubeMiniplayerGuarded = true;

      let explicitSummonAt = 0;
      document.addEventListener("keydown", (event) => {
        if (event.key === "i" && !event.metaKey && !event.ctrlKey && !event.altKey) {
          explicitSummonAt = Date.now();
        }
      }, true);
      document.addEventListener("pointerdown", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        if (target?.closest(".ytp-miniplayer-button")) { explicitSummonAt = Date.now(); }
      }, true);

      // Active means the site moved the player's video inside its
      // miniplayer host; the element itself always exists, just empty.
      const activeMiniplayer = () => {
        const miniplayer = document.querySelector("ytd-miniplayer");
        return miniplayer?.querySelector("video") ? miniplayer : null;
      };

      // The sweep pre-hides the site miniplayer for its whole window so it
      // never paints before the close lands — without this it flashes in
      // the corner for the beat between activation and the click.
      const suppressStyleID = "candoa-youtube-miniplayer-suppress";
      const hideMiniplayer = () => {
        if (document.getElementById(suppressStyleID)) { return; }
        const style = document.createElement("style");
        style.id = suppressStyleID;
        style.textContent = "ytd-miniplayer { visibility: hidden !important; pointer-events: none !important; }";
        document.documentElement.appendChild(style);
      };
      const unhideMiniplayer = () => { document.getElementById(suppressStyleID)?.remove(); };

      let sweepTimer = null;
      const endSweep = () => {
        if (sweepTimer !== null) { clearInterval(sweepTimer); sweepTimer = null; }
        unhideMiniplayer();
      };
      const sweep = (durationMs) => {
        const deadline = Date.now() + durationMs;
        if (sweepTimer !== null) { clearInterval(sweepTimer); }
        hideMiniplayer();
        let closeClicked = false;
        sweepTimer = setInterval(() => {
          const expired = Date.now() > deadline;
          const userMeantIt = Date.now() - explicitSummonAt < 3000;
          if (expired || userMeantIt) {
            endSweep();
            return;
          }
          const miniplayer = activeMiniplayer();
          if (!miniplayer) {
            // After a close, unhide only once the video has left the
            // miniplayer, so its dismissal never paints either.
            if (closeClicked) { endSweep(); }
            return;
          }
          miniplayer.querySelector(".ytp-miniplayer-close-button")?.click();
          closeClicked = true;
        }, 100);
      };

      const onNavigation = () => {
        // A miniplayer already floating predates this navigation — the user
        // opened it on purpose; only activations the navigation causes close.
        if (activeMiniplayer()) { return; }
        sweep(2500);
      };
      window.addEventListener("popstate", onNavigation, true);
      document.addEventListener("yt-navigate-start", onNavigation, true);

      // Session-restored ghost: a miniplayer active shortly after load was
      // carried over from a previous visit, never something the user just
      // did. Swept (and pre-hidden) from document start, before it renders.
      sweep(8000);
    })();
    """

    /// Injected at document start; reports playback state for the selected
    /// foreground video candidate and ignores small/autoplay ad-like media.
    static let mediaObserverScript = """
    (() => {
      if (window.__candoaMediaObserved) { return; }
      window.__candoaMediaObserved = true;

      const trustedMediaHosts = [
        "youtube.com",
        "youtu.be",
        "music.youtube.com",
        "vimeo.com",
        "twitch.tv",
        "netflix.com",
        "hulu.com",
        "max.com",
        "disneyplus.com",
        "primevideo.com",
        "apple.com",
        "tv.apple.com"
      ];
      const likelyAdPattern = /(^|[^a-z])(ad|ads|advert|advertisement|sponsor|sponsored|promo|preroll|midroll|postroll|ima|doubleclick|outstream|instream|teads|taboola|outbrain|aniview|primis|spotx|yieldmo|adchoices|google_ads|gpt)([^a-z]|$)/i;
      const likelyPreviewPattern = /(^|[^a-z])(hover|thumbnail|preview|previews|inline-preview|video-preview|moving-thumbnail|ytp-inline-preview)([^a-z]|$)/i;
      const miniPlayerClass = "__candoa-mini-player-active";
      const miniPlayerAttr = "data-candoa-mini-player";
      const miniPlayerHostID = "__candoa-mini-player-host";
      const miniPlayerStyleID = "__candoa-mini-player-style";

      const normalizedHostname = () => location.hostname.toLowerCase().replace(/^www[.]/, "");

      const isTrustedMediaHost = () => {
        const hostname = normalizedHostname();
        return trustedMediaHosts.some((host) => hostname === host || hostname.endsWith("." + host));
      };

      const isYouTubeHost = () => {
        const hostname = normalizedHostname();
        return hostname === "youtube.com" || hostname.endsWith(".youtube.com") || hostname === "youtu.be";
      };

      const isYouTubePlaybackPage = () => {
        if (normalizedHostname() === "music.youtube.com") { return true; }

        const pathname = location.pathname;
        return pathname === "/watch" ||
          pathname.startsWith("/shorts/") ||
          pathname.startsWith("/live/") ||
          pathname.startsWith("/embed/");
      };

      const finiteDuration = (media) => Number.isFinite(media.duration) ? media.duration : 0;

      const elementIdentity = (element) => {
        const parts = [];
        let cursor = element;
        for (let depth = 0; cursor && depth < 7; depth += 1, cursor = cursor.parentElement) {
          const className = typeof cursor.className === "string"
            ? cursor.className
            : (cursor.getAttribute("class") || "");
          parts.push(
            cursor.id || "",
            className,
            cursor.getAttribute("aria-label") || "",
            cursor.getAttribute("data-testid") || "",
            cursor.getAttribute("role") || "",
            cursor.getAttribute("src") || ""
          );
        }
        parts.push(element.currentSrc || element.src || "");
        return parts.join(" ").toLowerCase();
      };

      const looksLikeAd = (media) => likelyAdPattern.test(elementIdentity(media));

      const looksLikeTransientPreview = (media) => {
        const muted = media.muted || media.volume === 0;
        if (!muted) { return false; }

        if (isYouTubeHost() && !isYouTubePlaybackPage()) { return true; }

        return likelyPreviewPattern.test(elementIdentity(media));
      };

      const visibleRect = (media) => {
        const rect = media.getBoundingClientRect();
        const style = window.getComputedStyle(media);
        const opacity = Number.parseFloat(style.opacity || "1");
        if (
          style.display === "none" ||
          style.visibility === "hidden" ||
          opacity === 0 ||
          rect.width <= 0 ||
          rect.height <= 0
        ) {
          return { width: 0, height: 0, area: 0 };
        }

        return {
          width: rect.width,
          height: rect.height,
          area: rect.width * rect.height
        };
      };

      const mediaScore = (media) => {
        if (media.tagName?.toLowerCase() !== "video") { return -1; }
        if (media.ended) { return -1; }

        const trustedHost = isTrustedMediaHost();
        if (!trustedHost && looksLikeAd(media)) { return -1; }

        const isPlaying = !media.paused && !media.ended && media.readyState >= 2;
        const hasProgress = media.currentTime > 0 && !media.ended;
        if (!isPlaying && !hasProgress && media.readyState < 2) { return -1; }

        const isMiniPlayerPresentation = document.documentElement.classList.contains(miniPlayerClass);
        if (!isMiniPlayerPresentation && looksLikeTransientPreview(media)) { return -1; }

        const rect = visibleRect(media);
        const viewportArea = Math.max(window.innerWidth * window.innerHeight, 1);
        const prominentDimensions = (rect.width >= 360 && rect.height >= 200) ||
          (rect.width >= 240 && rect.height >= 360);
        const fillsEnoughSpace = isMiniPlayerPresentation
          ? rect.area / viewportArea >= 0.60
          : prominentDimensions && rect.area >= 120000 && rect.area / viewportArea >= 0.08;
        const duration = finiteDuration(media);
        const longEnough = duration >= 45;
        const audible = !(media.muted || media.volume === 0);

        if (!fillsEnoughSpace) { return -1; }
        if (!trustedHost && (!longEnough || !audible)) { return -1; }

        return (isPlaying ? 1000000 : 0) + rect.area + Math.min(duration, 7200);
      };

      const selectMedia = () => Array.from(document.querySelectorAll("video"))
        .map((media) => ({ media, score: mediaScore(media) }))
        .filter((candidate) => candidate.score >= 0)
        .sort((a, b) => b.score - a.score)[0]?.media || null;

      const clearMiniPlayerMarkers = () => {
        document.querySelectorAll("[" + miniPlayerAttr + "]").forEach((element) => {
          element.removeAttribute(miniPlayerAttr);
        });
      };

      const ensureMiniPlayerHost = () => {
        let host = document.getElementById(miniPlayerHostID);
        if (host) { return host; }

        host = document.createElement("div");
        host.id = miniPlayerHostID;
        (document.body || document.documentElement).appendChild(host);
        return host;
      };

      const restoreMiniPlayerMedia = () => {
        const state = window.__candoaMiniPlayerState;
        if (!state?.media) { return; }

        state.media.removeAttribute(miniPlayerAttr);

        if (state.parent?.isConnected) {
          if (state.placeholder?.parentNode === state.parent) {
            state.parent.insertBefore(state.media, state.placeholder);
            state.placeholder.remove();
          } else if (state.nextSibling?.parentNode === state.parent) {
            state.parent.insertBefore(state.media, state.nextSibling);
          } else {
            state.parent.appendChild(state.media);
          }
        }

        delete window.__candoaMiniPlayerState;

        // Collapsing the page to the video zeroed the scroll position; put
        // it back so the page returns exactly where the user left it.
        if (Number.isFinite(state.scrollX) && Number.isFinite(state.scrollY)) {
          window.scrollTo(state.scrollX, state.scrollY);
        }
      };

      const installMiniPlayerStyle = () => {
        if (document.getElementById(miniPlayerStyleID)) { return; }
        const style = document.createElement("style");
        style.id = miniPlayerStyleID;
        style.textContent = [
          "html." + miniPlayerClass + ", html." + miniPlayerClass + " body { background: #000 !important; margin: 0 !important; width: 100% !important; height: 100% !important; overflow: hidden !important; }",
          "html." + miniPlayerClass + " body > :not(#" + miniPlayerHostID + ") { display: none !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " { display: flex !important; position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; align-items: center !important; justify-content: center !important; overflow: hidden !important; z-index: 2147483647 !important; visibility: visible !important; background: #000 !important; pointer-events: none !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " * { visibility: visible !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " video[" + miniPlayerAttr + "='true'] { display: block !important; position: static !important; width: 100vw !important; height: 100vh !important; max-width: 100vw !important; max-height: 100vh !important; min-width: 0 !important; min-height: 0 !important; object-fit: contain !important; opacity: 1 !important; background: #000 !important; transform: none !important; border-radius: 0 !important; box-shadow: none !important; pointer-events: none !important; }"
        ].join("");
        document.documentElement.appendChild(style);
      };

      // Last media that passed full-layout selection. Activation may run
      // after the web view has shrunk to mini player size, where nothing
      // can satisfy the area thresholds — this remembers the right element.
      let lastEligibleMedia = null;

      window.__candoaSelectMedia = selectMedia;
      window.__candoaActivateMiniPlayerPresentation = () => {
        const existingState = window.__candoaMiniPlayerState;
        if (
          existingState?.media?.isConnected &&
          existingState.media.parentElement?.id === miniPlayerHostID
        ) {
          document.documentElement.classList.add(miniPlayerClass);
          existingState.media.setAttribute(miniPlayerAttr, "true");
          return true;
        }

        const fallback = lastEligibleMedia?.isConnected && !lastEligibleMedia.ended
          ? lastEligibleMedia
          : null;
        const media = selectMedia() || fallback;
        if (!media) { return false; }

        installMiniPlayerStyle();
        clearMiniPlayerMarkers();
        const host = ensureMiniPlayerHost();
        const placeholder = document.createComment("Candoa mini player media placeholder");
        const parent = media.parentNode;
        const nextSibling = media.nextSibling;

        if (parent) {
          parent.insertBefore(placeholder, media);
        }

        window.__candoaMiniPlayerState = {
          media,
          parent,
          nextSibling,
          placeholder,
          scrollX: window.scrollX,
          scrollY: window.scrollY
        };

        document.documentElement.classList.add(miniPlayerClass);
        media.setAttribute(miniPlayerAttr, "true");
        host.appendChild(media);

        return true;
      };

      window.__candoaDeactivateMiniPlayerPresentation = () => {
        document.documentElement.classList.remove(miniPlayerClass);
        restoreMiniPlayerMedia();
        clearMiniPlayerMarkers();
        document.getElementById(miniPlayerHostID)?.remove();
        window.__candoaReportMediaState?.();
      };

      let playbackTicker = null;
      const syncPlaybackTicker = (isPlaying) => {
        if (isPlaying && playbackTicker === null) {
          playbackTicker = window.setInterval(() => report(), 1000);
        } else if (!isPlaying && playbackTicker !== null) {
          window.clearInterval(playbackTicker);
          playbackTicker = null;
        }
      };

      const report = () => {
        const current = selectMedia();
        if (current) { lastEligibleMedia = current; }
        const playing = current && !current.paused && !current.ended && current.readyState >= 2;
        syncPlaybackTicker(Boolean(playing));

        const handler = window.webkit?.messageHandlers?.\(mediaStateMessageName);
        if (!handler) { return; }
        // The on-page rect only means anything while the page has its real
        // layout; once the mini player presentation strips the page, the
        // video fills the (tiny) viewport and the rect would be garbage.
        const presentationActive = document.documentElement.classList.contains(miniPlayerClass);
        const pageRect = current && !presentationActive ? current.getBoundingClientRect() : null;
        handler.postMessage({
          hasMedia: Boolean(current),
          isPlaying: Boolean(playing),
          isMuted: current ? (current.muted || current.volume === 0) : false,
          isMiniPlayerEligible: Boolean(current),
          currentTime: current ? current.currentTime : 0,
          duration: current ? finiteDuration(current) : 0,
          videoRect: pageRect
            ? { x: pageRect.x, y: pageRect.y, width: pageRect.width, height: pageRect.height }
            : null
        });
      };
      window.__candoaReportMediaState = report;

      let reportQueued = false;
      const queueReport = () => {
        if (reportQueued) { return; }
        reportQueued = true;
        window.setTimeout(() => {
          reportQueued = false;
          report();
        }, 250);
      };

      // Event-driven with a coalescing timeout. The only steady timer is the
      // 1 Hz progress ticker, and it exists solely while media is playing —
      // an idle page costs nothing.
      ["play", "playing", "pause", "ended", "emptied", "seeked", "volumechange", "loadedmetadata", "loadeddata"].forEach((eventName) => {
        document.addEventListener(eventName, queueReport, true);
      });
      document.addEventListener("visibilitychange", queueReport);
      // The floating player morphs out from the video's last reported
      // on-page rect, so scrolling and resizing refresh it (coalesced).
      window.addEventListener("scroll", queueReport, { passive: true, capture: true });
      window.addEventListener("resize", queueReport, { passive: true });
      window.setTimeout(report, 0);
    })();
    """
}
