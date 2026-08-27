import AppKit
import Foundation
import WebKit
import os

extension WebViewCoordinator {
    func tabID(for webView: WKWebView) -> UUID? {
        guard let tabIDString = tabIDsByWebView.object(forKey: webView) as String? else { return nil }
        return UUID(uuidString: tabIDString)
    }

    func updateStore(from webView: WKWebView, isLoading: Bool) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        if webView.url != nil {
            popupTabIDsAwaitingFirstLoad.remove(tabID)
        }

        let progress = webView.estimatedProgress
        let resolvedIsLoading = isLoading && progress < 0.999

        store?.updateTabFromWebView(
            tabID: tabID,
            title: webView.title,
            url: webView.url,
            isLoading: resolvedIsLoading,
            loadingProgress: resolvedIsLoading ? progress : 1,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    func recordHistoryVisit(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        store?.recordHistoryVisit(tabID: tabID, title: webView.title, url: webView.url)
    }

    func observe(_ webView: WKWebView, tabID: UUID) {
        observations[tabID] = [
            webView.observe(\.title, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                    // Same-document navigations (SPA route changes) never
                    // reach didFinish, but can repaint the page's header.
                    self?.armPageThemeColorRetries(for: webView)
                    self?.schedulePageThemeColorRefresh(for: webView)
                }
            },
            // The page's declared color arrives whenever WebKit parses or the
            // page rewrites `<meta name="theme-color">`.
            webView.observe(\.themeColor, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.refreshPageThemeColor(for: webView)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            // Element full screen is WebKit's to drive; hosting only has to
            // get out of its way and back in (see `isInElementFullscreen`).
            // Observed without `.new`: the state is read off the web view, so
            // there is no enum to decode out of the change dictionary.
            webView.observe(\.fullscreenState, options: []) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.elementFullscreenStateDidChange(for: webView)
                }
            }
        ]
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.preferredAcceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Mirrors macOS's language priority list so websites can choose their
    /// localized experience. The header is created for each navigation to keep
    /// it in sync with language changes made while the app is running.
    static var preferredAcceptLanguageHeader: String {
        let languages = Locale.preferredLanguages
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .reduce(into: [String]()) { result, language in
                guard !language.isEmpty, !result.contains(language) else { return }
                result.append(language)
            }
            .prefix(10)

        guard !languages.isEmpty else { return "en-US" }

        return languages.enumerated().map { index, language in
            guard index > 0 else { return language }
            return "\(language);q=\(String(format: "%.1f", max(0.1, 1.0 - (Double(index) * 0.1))))"
        }
        .joined(separator: ", ")
    }

    func refreshFavicon(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        let script = """
        (() => {
          const links = Array.from(document.querySelectorAll("link[rel*='icon'], link[rel='mask-icon']"));
          const first = links.map(link => link.href).find(Boolean);
          return first || "";
        })();
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] value, _ in
            Task { @MainActor in
                guard let self, let webView else { return }
                let candidateString = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateURL = candidateString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                // The store's favicon service, not the shared one: private
                // windows fetch favicons over an ephemeral session.
                guard let store = self.store else { return }
                let data = await store.faviconService.faviconData(for: webView.url, candidateURL: candidateURL)
                store.updateFavicon(tabID: tabID, data: data)
            }
        }
    }

    // MARK: - Page Theme Color

    /// Asks the page's resident color observer (`pageColorObserverScript`)
    /// to report the color it paints along its top edge. The observer also
    /// reports on its own whenever the page repaints that edge — a drawer
    /// sliding open, a site switching its own theme — so the bar follows
    /// in-page changes no navigation beat would catch. Verdicts land in
    /// `handleSampledPageColorVerdict`.
    func refreshPageThemeColor(for webView: WKWebView) {
        guard tabID(for: webView) != nil else { return }
        webView.evaluateJavaScript(
            "window.__candoaPageColorReport ? (window.__candoaPageColorReport(), true) : false",
            in: nil,
            in: .page
        ) { [weak self, weak webView] result in
            Task { @MainActor in
                guard
                    let self,
                    let webView,
                    let tabID = self.tabID(for: webView),
                    ((try? result.get()) as? Bool) != true
                else {
                    return
                }
                // No observer in this document (an error page, a blank
                // placeholder): the declared color is all there is.
                self.publishPageThemeColor(
                    hex: self.declaredChromeworthyHex(of: webView),
                    host: webView.url?.host,
                    tabID: tabID
                )
            }
        }
    }

    /// The painted top edge is the truth the bar must blend into, so the
    /// sampled color always wins; the declared `<meta name="theme-color">`
    /// is only a fallback while no sample has landed. Declarations
    /// routinely lie about the pixels — YouTube declares #212121 while
    /// painting #0F0F0F, and plenty of apps declare #ffffff boilerplate
    /// under a saturated header — and Dia wears the pixels in both cases.
    /// A settle-in re-sample keeps seeking the painted truth after a
    /// navigation beat, because an SPA's first painted frame is often its
    /// blank shell (LUMM samples white until Angular boots its teal header
    /// well past didFinish). Strictly bounded — never a poll: requests
    /// coalesce, the budget is spent when a retry fires (a burst of
    /// verdicts can't burn it), and it only refills on the next beat.
    ///
    /// A veil verdict ("veil:r,g,b,a" — a modal scrim covers the top edge)
    /// dims the color the bar already wears by compositing the scrim over
    /// the stored BASE color, so the bar darkens exactly the way the page's
    /// own header darkens under it (Dia's bar does the same). The base
    /// survives in `PageThemeColor.baseHex`, so a repeated veil can never
    /// dim an already-dimmed value. A plain inconclusive verdict HOLDS the
    /// worn color: the top edge is split or mid-transition, not repainted.
    /// The declared fallback applies only while nothing is worn yet, and a
    /// stale hold cannot outlive its page: the cross-origin commit clear
    /// still drops it.
    func handleSampledPageColorVerdict(_ verdict: String, for webView: WKWebView, tabID: UUID) {
        if verdict.hasPrefix("veil:"),
           let stored = store?.pageThemeColorsByTab[tabID],
           let dimmed = veiledHex(from: verdict, base: stored.baseHex) {
            store?.updatePageThemeColor(
                tabID: tabID,
                color: PageThemeColor(hex: dimmed, host: stored.host, baseHex: stored.baseHex)
            )
        } else if let sampled = PageChromeTint.hex(fromRGBString: verdict) {
            publishPageThemeColor(hex: sampled, host: webView.url?.host, tabID: tabID)
        } else if store?.pageThemeColorsByTab[tabID] == nil {
            publishPageThemeColor(
                hex: declaredChromeworthyHex(of: webView),
                host: webView.url?.host,
                tabID: tabID
            )
        }
        schedulePageThemeColorRefresh(
            for: webView,
            delay: 1.2,
            consumesRetryBudget: true
        )
    }

    /// Parses "veil:r,g,b,a" and composites that scrim over `base`.
    private func veiledHex(from verdict: String, base: String) -> String? {
        let parts = verdict.dropFirst("veil:".count)
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return PageChromeTint.veiledHex(
            base: base,
            scrimRed: parts[0],
            scrimGreen: parts[1],
            scrimBlue: parts[2],
            scrimAlpha: parts[3]
        )
    }

    /// One coalesced refresh per burst of same-document URL changes, so an
    /// SPA rewriting its route never streams sampling scripts into the page.
    /// A budget-consuming call is a settle-in retry: it only runs while the
    /// tab's retry budget lasts, and spends it at fire time.
    func schedulePageThemeColorRefresh(
        for webView: WKWebView,
        delay: TimeInterval = 0.45,
        consumesRetryBudget: Bool = false
    ) {
        guard let tabID = tabID(for: webView) else { return }
        if consumesRetryBudget, (pageThemeColorRetryBudgets[tabID] ?? 0) <= 0 { return }
        pageThemeColorRefreshWork[tabID]?.cancel()
        let work = DispatchWorkItem { [weak self, weak webView] in
            MainActor.assumeIsolated {
                guard let self, let webView else { return }
                self.pageThemeColorRefreshWork[tabID] = nil
                if consumesRetryBudget {
                    guard (self.pageThemeColorRetryBudgets[tabID] ?? 0) > 0 else { return }
                    self.pageThemeColorRetryBudgets[tabID]? -= 1
                }
                self.refreshPageThemeColor(for: webView)
            }
        }
        pageThemeColorRefreshWork[tabID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Arms the settle-in re-samples for a fresh page cycle (see the retry
    /// note in `refreshPageThemeColor`). Six retries at 1.2s cover ~8s of
    /// settling: an SPA's boot paint fires no transition and no click, so
    /// only these catch it, and a slow boot (LUMM restoring a big session)
    /// outlived the old two-retry budget — the bar froze on the blank
    /// shell's white. Bounded all the same: a page that never shows a color
    /// costs seven tiny samples per navigation and then goes quiet.
    func armPageThemeColorRetries(for webView: WKWebView) {
        guard let tabID = tabID(for: webView) else { return }
        pageThemeColorRetryBudgets[tabID] = 6
    }

    /// A committed cross-origin page starts from the neutral chrome unless it
    /// declares its own color; holding the previous site's color over a slow
    /// unrelated load would dress the new site in the old one's identity.
    /// Same-site commits hold steady until the new page's verdict lands.
    func clearCrossOriginPageThemeColor(for webView: WKWebView) {
        guard
            let tabID = tabID(for: webView),
            declaredChromeworthyHex(of: webView) == nil,
            let stored = store?.pageThemeColorsByTab[tabID],
            stored.host != webView.url?.host
        else {
            return
        }
        store?.updatePageThemeColor(tabID: tabID, color: nil)
    }

    /// The page's declared theme color, but only when it is one the chrome
    /// would actually wear. Near-white boilerplate declarations don't count
    /// as a claim — the painted header gets sampled instead.
    private func declaredChromeworthyHex(of webView: WKWebView) -> String? {
        guard
            let declared = webView.themeColor,
            let hex = PageChromeTint.hex(from: declared),
            PageChromeTint.isChromeworthy(hex: hex)
        else {
            return nil
        }
        return hex
    }

    private static let pageThemeColorLogger = Logger(
        subsystem: "app.candoa.browser",
        category: "PageThemeColor"
    )

    /// Publishes whatever the callers resolved: sampled pixels are worn
    /// as-is (the near-white gate applies only to declared colors, which
    /// the callers pre-filter through `declaredChromeworthyHex`).
    private func publishPageThemeColor(hex: String?, host: String?, tabID: UUID) {
        guard let hex else {
            Self.pageThemeColorLogger.info(
                "no wearable color for \(host ?? "-", privacy: .public)"
            )
            store?.updatePageThemeColor(tabID: tabID, color: nil)
            return
        }
        Self.pageThemeColorLogger.info(
            "wearing \(hex, privacy: .public) for \(host ?? "-", privacy: .public)"
        )
        store?.updatePageThemeColor(tabID: tabID, color: PageThemeColor(hex: hex, host: host))
    }

    func forwardWebAppPromptIfNeeded(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString),
            let pendingPrompt = pendingWebAppPrompts[tabID],
            store?.navigationService.canForwardWebAppPrompt(to: webView.url, providerID: pendingPrompt.providerID) == true
        else {
            return
        }

        let promptLiteral = javaScriptStringLiteral(for: pendingPrompt.query)
        let script = """
        (() => {
          const prompt = \(promptLiteral);
          const selectors = [
            "textarea",
            "[contenteditable='true']",
            "[role='textbox']"
          ];

          const isVisible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          };

          const setPlainInputValue = (element, value) => {
            const prototype = Object.getPrototypeOf(element);
            const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
            if (descriptor && descriptor.set) {
              descriptor.set.call(element, value);
            } else {
              element.value = value;
            }
          };

          const setPromptText = (element) => {
            element.focus();
            if (element.isContentEditable) {
              const selection = window.getSelection();
              const range = document.createRange();
              range.selectNodeContents(element);
              selection.removeAllRanges();
              selection.addRange(range);
              document.execCommand("insertText", false, prompt);
            } else {
              setPlainInputValue(element, prompt);
            }

            element.dispatchEvent(new InputEvent("input", {
              bubbles: true,
              cancelable: true,
              data: prompt,
              inputType: "insertText"
            }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
          };

          const submitPrompt = (element) => {
            const buttons = Array.from(document.querySelectorAll("button, [role='button']"));
            const sendButton = buttons.find((button) => {
              const label = [
                button.getAttribute("aria-label"),
                button.getAttribute("data-tooltip"),
                button.title,
                button.textContent
              ].filter(Boolean).join(" ").toLowerCase();
              return !button.disabled && !button.getAttribute("aria-disabled") && /send|submit/.test(label);
            });

            if (sendButton) {
              sendButton.click();
              return;
            }

            element.dispatchEvent(new KeyboardEvent("keydown", {
              bubbles: true,
              cancelable: true,
              key: "Enter",
              code: "Enter"
            }));
          };

          const findPromptBox = () => {
            return selectors
              .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
              .filter(isVisible)
              .find((element) => !element.closest("[aria-hidden='true']"));
          };

          const deadline = Date.now() + 10000;
          return new Promise((resolve) => {
            const attempt = () => {
              const promptBox = findPromptBox();
              if (!promptBox) {
                if (Date.now() < deadline) {
                  window.setTimeout(attempt, 250);
                } else {
                  resolve(false);
                }
                return;
              }

              setPromptText(promptBox);
              window.setTimeout(() => {
                submitPrompt(promptBox);
                resolve(true);
              }, 200);
            };

            attempt();
          });
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                self?.pendingWebAppPrompts[tabID] = nil
            }
        }
    }

    func javaScriptStringLiteral(for value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let arrayLiteral = String(data: data, encoding: .utf8),
            arrayLiteral.first == "[",
            arrayLiteral.last == "]"
        else {
            return "\"\""
        }

        return String(arrayLiteral.dropFirst().dropLast())
    }
}
