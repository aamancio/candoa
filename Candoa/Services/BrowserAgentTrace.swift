import Foundation

/// Writes each browser-agent step — the snapshot the model saw and what the
/// action did — to a folder, for reading a run back after the fact. Off
/// unless `CANDOA_AGENT_TRACE_DIR` names a directory, and compiled out of
/// Release builds: a trace holds page content.
@MainActor
enum BrowserAgentTrace {
    #if DEBUG
    private static let directory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["CANDOA_AGENT_TRACE_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var counter = 0

    static func record(step: String, target: String, result: String, page: BrowserAgentPage) {
        guard let directory else { return }
        counter += 1
        let stamp = ISO8601DateFormatter().string(from: Date())
        let name = String(format: "%03d-%@.md", counter, step)
        let body = """
        # \(step) — \(stamp)

        target: \(target)
        result: \(result)
        url: \(page.url)
        controls: \(page.controls.count)

        \(page.tree ?? "(no tree)")
        """
        try? body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    #else
    static func record(step: String, target: String, result: String, page: BrowserAgentPage) {}
    #endif
}
