import AppKit
import Foundation
import WebKit

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
