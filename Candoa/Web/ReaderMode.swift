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
    /// Reader is text-only, matching Safari: figures leave with their
    /// captions (never orphaning caption text the way Safari does), and
    /// images, video, and audio go with them. `.noprint` is the
    /// long-standing convention (MediaWiki and elsewhere) for on-screen
    /// chrome excluded from print — reader is the same context.
    /// `.mw-editsection` is MediaWiki's "[edit]" heading link, worth naming
    /// outright for how much of the readable web runs on it.
    private static let strippedSelectors = """
    script, style, link, noscript, template, iframe, object, embed, form, \
    button, input, select, textarea, nav, aside, footer, header, dialog, \
    figure, figcaption, picture, img, svg, video, audio, \
    [role=navigation], [role=banner], [role=complementary], [role=search], \
    [role=form], [aria-hidden=true], [hidden], .noprint, .mw-editsection, \
    .catlinks, .side-box
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

      // The clone loses the page's stylesheets, which would resurrect
      // everything the page keeps hidden (consent banners, share sheets,
      // MediaWiki's short-description line). The fresh clone's elements
      // correspond index-for-index with the live container's, so the live
      // side answers what is actually rendered.
      if (best.checkVisibility) {
        const liveElements = best.querySelectorAll("*");
        const cloneElements = clone.querySelectorAll("*");
        const hidden = [];
        const count = Math.min(liveElements.length, cloneElements.length);
        for (let index = 0; index < count; index += 1) {
          if (!liveElements[index].checkVisibility()) { hidden.push(cloneElements[index]); }
        }
        hidden.forEach((el) => el.remove());
      }

      clone.querySelectorAll("\(strippedSelectors)").forEach((el) => el.remove());

      // Boxes of links are page furniture, not prose: infobox-style tables
      // by their widespread class names, and any table whose text is mostly
      // link text (navigation grids, related-article rails).
      const linkDensity = (el) => {
        const total = el.textContent.trim().length;
        if (!total) { return 1; }
        let linked = 0;
        for (const link of el.querySelectorAll("a")) {
          linked += link.textContent.trim().length;
        }
        return linked / total;
      };
      clone.querySelectorAll("table").forEach((table) => {
        const className = typeof table.className === "string" ? table.className : "";
        if (/(^|\\s)(infobox|navbox|sidebar|vcard|metadata|ambox)/i.test(className)
            || linkDensity(table) > 0.5) {
          table.remove();
        }
      });

      // Lists whose items are essentially bare links are link rails
      // (category strips, "see also" stacks), not prose. References and
      // bibliographies survive: their items carry real text around the
      // links.
      clone.querySelectorAll("ul, ol").forEach((list) => {
        const items = [...list.children].filter((child) => child.tagName === "LI");
        if (items.length < 4) { return; }
        const bareLinkItems = items.filter((item) => {
          const text = item.textContent.trim().length;
          return !text || linkDensity(item) > 0.9;
        });
        if (bareLinkItems.length / items.length >= 0.8) { list.remove(); }
      });

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

      // Removals leave husks behind; drop blocks with no text left,
      // leaves first so newly emptied parents follow.
      [...clone.querySelectorAll("p, div, section, ul, ol, dl, span")]
        .reverse()
        .forEach((el) => {
          if (!el.textContent.trim()) { el.remove(); }
        });

      // The page's own heading beats document.title and og:title, which
      // routinely carry " - Site Name" suffixes.
      const heading = document.querySelector("article h1, main h1, h1")?.textContent?.trim();
      const metaTitle = document.querySelector("meta[property='og:title']")?.content?.trim();
      const title = heading || metaTitle || document.title.trim();

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

      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

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

      // Safari-style entrance: the backdrop fades in while the card rises
      // into place. Web Animations API — a page CSP cannot block it, and it
      // leaves no styles behind. Reduce Motion gets a plain quick fade.
      if (reduceMotion) {
        host.animate(
          { opacity: [0, 1] },
          { duration: 120, easing: "ease-out" }
        );
      } else {
        host.animate(
          { opacity: [0, 1] },
          { duration: 220, easing: "ease-out" }
        );
        article.animate(
          {
            opacity: [0, 1],
            transform: ["translateY(14px) scale(0.985)", "translateY(0) scale(1)"]
          },
          { duration: 300, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" }
        );
      }
      return true;
    })()
    """

    /// Restores the page immediately (scroll, interactivity, accessibility),
    /// then fades the overlay away and removes it. Returns `true` when an
    /// overlay was actually open.
    static let exitReaderScript = """
    (() => {
      const state = window.__candoaReader;
      if (!state) { return false; }
      delete window.__candoaReader;
      document.documentElement.style.overflow = state.previousOverflow || "";
      document.body.inert = state.previousInert || false;

      // The page is already live underneath; the departing card must not
      // swallow clicks while it fades.
      state.host.style.pointerEvents = "none";
      const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
      const exit = state.host.animate(
        reduceMotion
          ? { opacity: [1, 0] }
          : { opacity: [1, 0], transform: ["scale(1)", "scale(0.99)"] },
        { duration: reduceMotion ? 100 : 180, easing: "ease-in" }
      );
      exit.onfinish = () => state.host.remove();
      exit.oncancel = () => state.host.remove();
      return true;
    })()
    """

    /// Reader typography, Safari-calibrated: the article sits on an elevated
    /// card over a dimmed backdrop, body text at 1.5× the system body size
    /// (still tracking the accessibility text-size setting through
    /// `-apple-system-body`), and the regular page-zoom commands scale the
    /// whole overlay. Colors are `light-dark()` pairs resolved by the
    /// `color-scheme` on the host; increased contrast falls back to pure
    /// system colors.
    private static let overlayCSS = """
    :host { color-scheme: light dark; }
    .candoa-reader-scroller {
      position: absolute;
      inset: 0;
      overflow-y: auto;
      overscroll-behavior: contain;
      background: light-dark(#e6e6e9, #1b1b1d);
      font: -apple-system-body;
      font-family: -apple-system, system-ui, sans-serif;
    }
    article {
      background: light-dark(#ffffff, #2a2a2c);
      color: light-dark(#1d1d1f, #e3e3e7);
      font-size: 1.5em;
      line-height: 1.6;
      max-width: 46em;
      margin: 2.75rem auto 5rem;
      padding: 3.25rem 4.25rem 4.25rem;
      border-radius: 12px;
      box-shadow: 0 1px 4px rgba(0, 0, 0, 0.12);
      overflow-wrap: break-word;
    }
    header { margin-bottom: 2rem; }
    header h1 {
      font-size: 2em;
      font-weight: 700;
      letter-spacing: -0.015em;
      line-height: 1.2;
      margin: 0 0 0.45rem;
    }
    .candoa-reader-meta {
      color: light-dark(#6e6e73, #98989d);
      font-size: 0.8em;
      margin: 0;
    }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; }
    h2 { font-size: 1.4em; margin: 2.2rem 0 0.9rem; }
    h3 { font-size: 1.15em; margin: 1.8rem 0 0.7rem; }
    a, a:visited {
      color: light-dark(#0a68d8, #539df8);
      text-decoration: none;
    }
    a:hover { text-decoration: underline; }
    sup, sub { font-size: 0.7em; line-height: 1; }
    pre, code { font-family: ui-monospace, monospace; font-size: 0.88em; }
    pre {
      overflow-x: auto;
      padding: 0.75rem 1rem;
      background: light-dark(#f2f2f4, #1f1f21);
      border-radius: 8px;
    }
    blockquote {
      margin: 1.5rem 0;
      padding-left: 1rem;
      border-left: 3px solid light-dark(#d1d1d6, #48484a);
      color: light-dark(#48484a, #b9b9be);
    }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    td, th {
      border: 1px solid light-dark(#d1d1d6, #48484a);
      padding: 0.35rem 0.6rem;
      text-align: left;
    }
    hr {
      border: none;
      border-top: 1px solid light-dark(#d1d1d6, #48484a);
      margin: 2rem 0;
    }
    @media (max-width: 760px) {
      .candoa-reader-scroller { background: light-dark(#ffffff, #2a2a2c); }
      article {
        margin: 0;
        max-width: none;
        padding: 2rem 1.5rem 3rem;
        border-radius: 0;
        box-shadow: none;
      }
    }
    @media (prefers-contrast: more) {
      .candoa-reader-scroller { background: Canvas; }
      article {
        background: Canvas;
        color: CanvasText;
        box-shadow: none;
      }
      .candoa-reader-meta { color: CanvasText; }
      a, a:visited { color: LinkText; text-decoration: underline; }
    }
    """
}
