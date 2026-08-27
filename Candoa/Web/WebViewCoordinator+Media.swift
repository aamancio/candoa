import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    // MARK: - Media Playback State & Controls

    /// Single WKScriptMessageHandler entry point for every page script,
    /// media state and link hover alike.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            let webView = message.webView,
            let tabID = tabID(for: webView)
        else {
            return
        }

        switch message.name {
        case WebPageScripts.mediaStateMessageName:
            guard let body = message.body as? [String: Any] else { return }
            let state = TabMediaState(
                hasMedia: body["hasMedia"] as? Bool ?? false,
                isPlaying: body["isPlaying"] as? Bool ?? false,
                isMuted: body["isMuted"] as? Bool ?? false,
                isMiniPlayerEligible: body["isMiniPlayerEligible"] as? Bool ?? false,
                currentTime: body["currentTime"] as? Double ?? 0,
                duration: body["duration"] as? Double ?? 0,
                pageVideoFrame: Self.videoFrame(from: body["videoRect"]),
                videoAspectRatio: Self.aspectRatio(from: body["videoAspect"])
            )
            store?.updateMediaState(tabID: tabID, state: state)

        case WebPageScripts.linkHoverMessageName:
            let href = (message.body as? [String: Any])?["href"] as? String
            store?.updateHoveredLink(tabID: tabID, href: href)

        case WebPageScripts.webStoreInstallMessageName:
            guard
                let body = message.body as? [String: Any],
                let itemID = body["itemID"] as? String
            else {
                return
            }
            installWebStoreItem(
                itemID: itemID,
                name: body["name"] as? String ?? "",
                in: webView
            )

        case WebPageScripts.unsavedInputMessageName:
            userEditedTabIDs.insert(tabID)

        case WebPageScripts.webNotificationMessageName:
            handleWebNotificationMessage(message, tabID: tabID, webView: webView)

        case WebPageScripts.pageColorMessageName:
            let verdict = (message.body as? [String: Any])?["color"] as? String ?? ""
            handleSampledPageColorVerdict(verdict, for: webView, tabID: tabID)

        case WebPageScripts.popupDiagnosticsMessageName:
            guard let body = message.body as? [String: Any] else { return }
            let phase = body["phase"] as? String ?? "?"
            let href = body["href"] as? String ?? "?"
            let opener = body["opener"] as? Bool ?? false
            let name = body["name"] as? String ?? ""
            guard BrowserStore.isUITesting else { return }
            store?.uiTestingPopupDiagnostics.append(
                "\(phase) opener=\(opener) name=\(name) href=\(href.prefix(120))"
            )

        default:
            break
        }
    }

    static func videoFrame(from value: Any?) -> CGRect? {
        guard
            let rect = value as? [String: Any],
            let x = rect["x"] as? Double,
            let y = rect["y"] as? Double,
            let width = rect["width"] as? Double,
            let height = rect["height"] as? Double,
            width > 0, height > 0,
            [x, y, width, height].allSatisfy(\.isFinite)
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func aspectRatio(from value: Any?) -> CGFloat? {
        guard let aspect = value as? Double, aspect.isFinite, aspect > 0 else { return nil }
        return CGFloat(aspect)
    }

    /// Styles the page down to its video, pinned at player size at the
    /// layout viewport's top-left. Pure style — the page's layout stays.
    func activateMiniPlayerPresentation(tabID: UUID, playerSize: CGSize) {
        webViews[tabID]?.evaluateJavaScript(
            "window.__candoaActivateMiniPlayerPresentation?.(\(Int(playerSize.width.rounded())), \(Int(playerSize.height.rounded())))"
        )
    }

    func restoreMiniPlayerPresentation(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.__candoaDeactivateMiniPlayerPresentation?.()")
    }

    func toggleMediaPlayback(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = selected ? [selected] : Array.from(document.querySelectorAll("video, audio"));
          const playing = medias.filter((media) => !media.paused && !media.ended);
          if (playing.length > 0) {
            playing.forEach((media) => media.pause());
            return;
          }

          const resumable = medias.find((media) => media.currentTime > 0 && !media.ended)
            || medias.find((media) => media.readyState >= 2);
          if (resumable) { resumable.play(); }
        })();
        """)
    }

    func pauseMediaPlayback(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = selected ? [selected] : Array.from(document.querySelectorAll("video, audio"));
          medias
            .filter((media) => !media.paused && !media.ended)
            .forEach((media) => media.pause());
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func toggleMediaMute(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = (selected ? [selected] : Array.from(document.querySelectorAll("video, audio")))
            .filter((media) => media.readyState >= 1 || media.currentTime > 0);
          if (medias.length === 0) { return; }

          const shouldMute = medias.some((media) => !media.muted);
          medias.forEach((media) => { media.muted = shouldMute; });
        })();
        """)
    }

    func setMediaMuted(_ muted: Bool, tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = (selected ? [selected] : Array.from(document.querySelectorAll("video, audio")))
            .filter((media) => media.readyState >= 1 || media.currentTime > 0);
          medias.forEach((media) => { media.muted = \(muted); });
        })();
        """)
    }

    func skipMediaTrack(tabID: UUID, forward: Bool) {
        let buttonSelectors = forward
            ? ".ytp-next-button, [aria-label='Next'], [data-testid='control-button-skip-forward']"
            : ".ytp-prev-button, [aria-label='Previous'], [data-testid='control-button-skip-back']"
        let seekDelta = forward ? 15.0 : -15.0

        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const button = document.querySelector("\(buttonSelectors)");
          if (button) {
            button.click();
            return;
          }

          // No track controls on this page: nudge the timeline instead.
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = media.currentTime + (\(seekDelta));
          media.currentTime = Math.max(0, Number.isFinite(media.duration) ? Math.min(media.duration, target) : target);
        })();
        """)
    }

    func seekMedia(tabID: UUID, by seconds: Double) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = media.currentTime + (\(seconds));
          media.currentTime = Math.max(0, Number.isFinite(media.duration) ? Math.min(media.duration, target) : target);
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func seekMedia(tabID: UUID, to time: Double) {
        let targetTime = max(0, time)

        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = \(targetTime);
          media.currentTime = Number.isFinite(media.duration) ? Math.min(media.duration, target) : target;
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func refreshMediaState(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.__candoaReportMediaState?.()")
    }
}

