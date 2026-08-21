// Prints Eli's page snapshot for a URL, using the exact scripts the app
// ships, in an off-screen WKWebView. For developing and checking the
// perception layer without driving Candoa itself.
//
//   swiftc -O scripts/agent-snapshot.swift -o /tmp/agent-snapshot
//   /tmp/agent-snapshot https://example.com [--scroll 800] [--budget 24000] [--controls] [--json]
//   /tmp/agent-snapshot --html path/to/page.html
//
// The scripts are read from Candoa/Resources/BrowserAgent relative to the
// script's own location, so a worktree prints its own version.

import AppKit
import Foundation
import WebKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: agent-snapshot <url> | --html <file> [--scroll px] [--budget chars] [--controls] [--json] [--wait seconds]\n".utf8))
    exit(2)
}

var url: URL?
var htmlPath: String?
var scroll: Int = 0
var budget: Int = 24000
var printControls = false
var printJSON = false
var wait: Double = 1.5
var dumpSelector: String?
var actions: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--html": htmlPath = arguments[index + 1]; index += 1
    case "--scroll": scroll = Int(arguments[index + 1]) ?? 0; index += 1
    case "--budget": budget = Int(arguments[index + 1]) ?? 24000; index += 1
    case "--wait": wait = Double(arguments[index + 1]) ?? 1.5; index += 1
    case "--dump": dumpSelector = arguments[index + 1]; index += 1
    case "--act": actions.append(arguments[index + 1]); index += 1
    case "--controls": printControls = true
    case "--json": printJSON = true
    default: url = URL(string: argument)
    }
    index += 1
}

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = ProcessInfo.processInfo.environment["CANDOA_REPO"].map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let scriptsURL = repoRoot.appendingPathComponent("Candoa/Resources/BrowserAgent")

func source(_ name: String) -> String {
    let fileURL = scriptsURL.appendingPathComponent("\(name).js")
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        FileHandle.standardError.write(Data("missing \(fileURL.path)\n".utf8))
        exit(1)
    }
    return text
}

final class Runner: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let world = WKContentWorld.world(name: "CandoaBrowserAgent")

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.snapshot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    func snapshot() {
        Task { @MainActor in
            if scroll > 0 {
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(scroll)); undefined")
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let dumpSelector {
                let js = "Array.from(document.querySelectorAll(\(String(reflecting: dumpSelector)))).slice(0, 5).map(e => e.outerHTML.slice(0, 1500)).join('\\n----\\n')"
                let html = (try? await webView.evaluateJavaScript(js)) as? String ?? "(no match)"
                print(html)
                exit(0)
            }
            // Each --act runs against a fresh snapshot, waits for the page to
            // settle, then the next one; the final snapshot is printed.
            var controlsByRef: [String: [String: Any]] = [:]
            for action in actions {
                let parts = action.split(separator: ":", maxSplits: 2).map(String.init)
                let snapshotID = UUID().uuidString.lowercased()
                let snapshotJSON = (try? await webView.callAsyncJavaScript(source("shared") + "\n" + source("snapshot"), arguments: ["snapshotID": snapshotID, "budget": budget], in: nil, contentWorld: world)) as? String ?? "{}"
                let object = (try? JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8))) as? [String: Any] ?? [:]
                controlsByRef = Dictionary(uniqueKeysWithValues: ((object["controls"] as? [[String: Any]]) ?? []).map { ($0["ref"] as? String ?? "", $0) })
                let ref = parts[0], kind = parts.count > 1 ? parts[1] : "click", value = parts.count > 2 ? parts[2] : ""
                let result: Any?
                if kind == "scroll" {
                    result = try? await webView.callAsyncJavaScript(source("shared") + "\n" + source("scroll"), arguments: ["snapshotID": snapshotID, "direction": ref], in: nil, contentWorld: world)
                } else {
                    guard let control = controlsByRef[ref] else { print("no such ref \(ref)"); exit(1) }
                    result = try? await webView.callAsyncJavaScript(source("shared") + "\n" + source("performReferencedAction"), arguments: ["snapshotID": snapshotID, "ref": ref, "expectedLabel": control["label"] ?? "", "expectedKind": control["kind"] ?? "", "kind": kind, "value": value], in: nil, contentWorld: world)
                }
                print("→ \(action): \(result ?? "nil")")
                let settle = try? await webView.callAsyncJavaScript(source("waitForSettle"), arguments: ["quietMilliseconds": 400, "timeoutMilliseconds": 4000], in: nil, contentWorld: world)
                print("  settle: \(settle ?? "nil") url=\(webView.url?.absoluteString ?? "")")
                while webView.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
            }
            let started = Date()
            do {
                let result = try await webView.callAsyncJavaScript(
                    source("shared") + "\n" + source("snapshot"),
                    arguments: ["snapshotID": UUID().uuidString.lowercased(), "budget": budget],
                    in: nil,
                    contentWorld: world
                )
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                guard let json = result as? String, let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    FileHandle.standardError.write(Data("unexpected result: \(String(describing: result))\n".utf8))
                    exit(1)
                }
                let tree = object["tree"] as? String ?? ""
                let controls = object["controls"] as? [[String: Any]] ?? []
                if printJSON {
                    print(json)
                } else {
                    print(tree)
                    print("\n— \(tree.count) chars, \(controls.count) refs, \(elapsed) ms")
                    if printControls {
                        for control in controls {
                            print("\(control["ref"] ?? "") \(control["kind"] ?? "")/\(control["role"] ?? "") \"\(control["label"] ?? "")\"\(control["sensitive"] as? Bool == true ? " sensitive" : "")\(control["disabled"] as? Bool == true ? " disabled" : "")\(control["url"] as? String ?? "" == "" ? "" : " → \(control["url"]!)")")
                        }
                    }
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("script failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let runner = Runner()
if let htmlPath {
    let html = try! String(contentsOfFile: htmlPath, encoding: .utf8)
    runner.webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.candoa.test/page"))
} else if let url {
    runner.webView.load(URLRequest(url: url))
} else {
    exit(2)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
    FileHandle.standardError.write(Data("timed out\n".utf8))
    exit(1)
}
app.run()
