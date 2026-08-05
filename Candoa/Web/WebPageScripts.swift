enum WebPageScripts {
    static let mediaStateMessageName = "candoaMediaState"
    static let linkHoverMessageName = "candoaLinkHover"
    static let popupDiagnosticsMessageName = "candoaPopupDiagnostics"

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
      window.setTimeout(report, 0);
    })();
    """
}
