import Foundation

/// Reader mode's page-side pieces: a one-shot availability probe and the
/// enter/exit scripts for a same-document reader overlay. The overlay is a
/// shadow-DOM layer over the live page — no second WKWebView, no snapshot,
/// no navigation, and nothing retained after it closes. Because the page
/// never goes away, exiting trivially restores it (scroll included), the
/// back-forward list stays truthful, and hibernation needs no special
/// handling: serialized interaction state describes the real page, so a
/// woken tab simply comes back without the overlay.
///
/// Styling lives in a constructed stylesheet (`adoptedStyleSheets`) and
/// CSSOM property assignments, neither of which a page's CSP can block the
/// way it blocks inline style markup.
enum ReaderMode {
    /// Article-like sections that never belong in extracted reading content.
    private static let strippedSelectors = """
    script, style, link, noscript, template, iframe, object, embed, form, \
    button, input, select, textarea, nav, aside, footer, header, dialog, \
    [role=navigation], [role=banner], [role=complementary], [role=search], \
    [role=form], [aria-hidden=true], [hidden]
    """

    /// Paragraph text that sits inside chrome-like containers is ignored
    /// when scoring, so index pages full of teaser links don't qualify.
    private static let chromeAncestors = "nav, aside, footer, header, form, [role=navigation], [role=banner]"

    /// Shared by the probe (cheap threshold check) and the enter script
    /// (full candidate scoring): paragraph text length, discounted for
    /// link-heavy blocks so menus and related-article rails score near zero.
    private static let paragraphScoreFunction = """
    const paragraphScore = (root) => {
      let score = 0;
      for (const paragraph of root.querySelectorAll("p")) {
        if (paragraph.closest("\(chromeAncestors)")) { continue; }
        const text = paragraph.textContent.trim();
        if (text.length < 40) { continue; }
        let linkLength = 0;
        for (const link of paragraph.querySelectorAll("a")) {
          linkLength += link.textContent.trim().length;
        }
        score += Math.max(0, text.length - linkLength * 2);
      }
      return score;
    };
    """

    /// Evaluates to `true` when the page carries enough contiguous paragraph
    /// text to be worth reading in Reader. Runs once per finished load of
    /// the active tab — never on a timer.
    static let availabilityProbeScript = """
    (() => {
      if (!document.body) { return false; }
      \(paragraphScoreFunction)
      const root = document.querySelector("article")
        || document.querySelector("main, [role=main]")
        || document.body;
      return paragraphScore(root) >= 600;
    })()
    """

    /// Extracts the best article container and presents it in the reader
    /// overlay. Returns `true` when the overlay is showing. Idempotent: a
    /// second call while open is a no-op success.
    static let enterReaderScript = """
    (() => {
      if (window.__candoaReader) { return true; }
      if (!document.body) { return false; }

      \(paragraphScoreFunction)

      const candidates = [...document.querySelectorAll(
        "article, main, [role=main], [itemprop=articleBody]"
      )];
      if (!candidates.length) { candidates.push(document.body); }
      let best = candidates[0];
      let bestScore = paragraphScore(best);
      for (const candidate of candidates.slice(1)) {
        const score = paragraphScore(candidate);
        if (score > bestScore) { best = candidate; bestScore = score; }
      }
      if (bestScore < 600) { return false; }

      const clone = best.cloneNode(true);
      clone.querySelectorAll("\(strippedSelectors)").forEach((el) => el.remove());

      for (const el of clone.querySelectorAll("*")) {
        for (const attribute of [...el.attributes]) {
          const name = attribute.name.toLowerCase();
          if (name.startsWith("on") || name === "style" || name === "srcset" || name === "sizes") {
            el.removeAttribute(attribute.name);
          }
        }
      }

      clone.querySelectorAll("a[href]").forEach((anchor) => {
        try {
          const resolved = new URL(anchor.getAttribute("href"), location.href);
          if (resolved.protocol === "http:" || resolved.protocol === "https:" || resolved.protocol === "mailto:") {
            anchor.setAttribute("href", resolved.href);
          } else {
            anchor.removeAttribute("href");
          }
        } catch {
          anchor.removeAttribute("href");
        }
      });

      clone.querySelectorAll("img").forEach((image) => {
        const source = image.currentSrc || image.src || "";
        if (!/^https?:/.test(source)) { image.remove(); return; }
        image.setAttribute("src", source);
        image.setAttribute("loading", "lazy");
        image.setAttribute("decoding", "async");
      });

      const metaTitle = document.querySelector("meta[property='og:title']")?.content?.trim();
      const heading = document.querySelector("article h1, main h1, h1")?.textContent?.trim();
      const title = metaTitle || heading || document.title.trim();

      const byline = (
        document.querySelector("meta[name=author]")?.content
          || document.querySelector("[rel=author]")?.textContent
          || document.querySelector("[itemprop=author]")?.textContent
          || ""
      ).trim().replace(/\\s+/g, " ").slice(0, 200);

      // The overlay header renders the title itself; a duplicate leading
      // heading inside the article would read twice.
      const firstHeading = clone.querySelector("h1");
      if (firstHeading && title && firstHeading.textContent.trim() === title) {
        firstHeading.remove();
      }

      const host = document.createElement("candoa-reader");
      // CSSOM assignments so a strict page CSP cannot reject the styling.
      Object.assign(host.style, {
        position: "fixed",
        inset: "0",
        zIndex: "2147483647",
        display: "block"
      });

      const shadow = host.attachShadow({ mode: "closed" });
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(`\(overlayCSS)`);
      shadow.adoptedStyleSheets = [sheet];

      const scroller = document.createElement("div");
      scroller.className = "candoa-reader-scroller";

      const article = document.createElement("article");
      article.setAttribute("role", "document");
      article.setAttribute("aria-label", title);

      const header = document.createElement("header");
      const headline = document.createElement("h1");
      headline.textContent = title;
      header.appendChild(headline);

      const metaParts = [byline, location.hostname].filter(Boolean);
      if (metaParts.length) {
        const metaLine = document.createElement("p");
        metaLine.className = "candoa-reader-meta";
        metaLine.textContent = metaParts.join(" · ");
        header.appendChild(metaLine);
      }
      article.appendChild(header);

      const body = document.createElement("div");
      body.append(...clone.childNodes);
      article.appendChild(body);

      scroller.appendChild(article);
      shadow.appendChild(scroller);
      document.documentElement.appendChild(host);

      // Freeze the page underneath so only the reader scrolls, and take it
      // out of the accessibility tree and hit-testing entirely — the reader
      // host is a sibling of <body>, so it stays live. Both previous values
      // come back verbatim on exit, scroll position untouched.
      const previousOverflow = document.documentElement.style.overflow;
      const previousInert = document.body.inert;
      document.documentElement.style.overflow = "hidden";
      document.body.inert = true;
      window.__candoaReader = { host, previousOverflow, previousInert };
      return true;
    })()
    """

    /// Removes the overlay and restores the page exactly as it was.
    /// Returns `true` when an overlay was actually open.
    static let exitReaderScript = """
    (() => {
      const state = window.__candoaReader;
      if (!state) { return false; }
      document.documentElement.style.overflow = state.previousOverflow || "";
      document.body.inert = state.previousInert || false;
      state.host.remove();
      delete window.__candoaReader;
      return true;
    })()
    """

    /// Reader typography: system font tracking the system text size, system
    /// colors tracking appearance and increased contrast, and the regular
    /// page-zoom commands scale the whole overlay. Backslash-escaped
    /// template characters survive the outer JS template literal.
    private static let overlayCSS = """
    :host { color-scheme: light dark; }
    .candoa-reader-scroller {
      position: absolute;
      inset: 0;
      overflow-y: auto;
      overscroll-behavior: contain;
      background: Canvas;
      color: CanvasText;
    }
    article {
      font: -apple-system-body;
      font-family: -apple-system, system-ui, sans-serif;
      line-height: 1.6;
      max-width: 42em;
      margin: 0 auto;
      padding: 3.5rem 1.75rem 6rem;
      overflow-wrap: break-word;
    }
    header { margin-bottom: 2.25rem; }
    header h1 { font-size: 1.75em; line-height: 1.25; margin: 0 0 0.4rem; }
    .candoa-reader-meta {
      color: color-mix(in srgb, CanvasText 55%, Canvas);
      font-size: 0.85em;
      margin: 0;
    }
    h1, h2, h3, h4, h5, h6 { line-height: 1.3; }
    img, video, svg { max-width: 100%; height: auto; }
    figure { margin: 1.5rem 0; }
    figcaption {
      color: color-mix(in srgb, CanvasText 55%, Canvas);
      font-size: 0.85em;
      margin-top: 0.4rem;
    }
    a { color: LinkText; }
    pre, code { font-family: ui-monospace, monospace; font-size: 0.9em; }
    pre {
      overflow-x: auto;
      padding: 0.75rem 1rem;
      background: color-mix(in srgb, CanvasText 6%, Canvas);
      border-radius: 6px;
    }
    blockquote {
      margin: 1.5rem 0;
      padding-left: 1rem;
      border-left: 3px solid color-mix(in srgb, CanvasText 25%, Canvas);
      color: color-mix(in srgb, CanvasText 75%, Canvas);
    }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    td, th {
      border: 1px solid color-mix(in srgb, CanvasText 20%, Canvas);
      padding: 0.35rem 0.6rem;
      text-align: left;
    }
    hr {
      border: none;
      border-top: 1px solid color-mix(in srgb, CanvasText 20%, Canvas);
      margin: 2rem 0;
    }
    """
}
