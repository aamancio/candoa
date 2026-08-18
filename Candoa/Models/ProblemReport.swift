import Foundation

/// What a report describes. `crash` is a process death MetricKit handed back
/// after the fact, `error` is a fault the app survived, and `report` is a
/// person deliberately describing a problem. Only `report` carries prose.
enum ProblemReportKind: String, Sendable {
    case crash
    case error
    case report
}

/// One problem on its way to Candoa Cloud's intake, which deduplicates by
/// fingerprint and files a single issue per defect.
///
/// The app deliberately sends no page addresses, no tab titles, and nothing
/// from a person's browsing. A browser knows more about someone than almost
/// anything else on their Mac, so a report carries the code that broke and
/// nothing about what they were reading. Cloud redacts as well, but the safest
/// data is the data that never leaves.
struct ProblemReport: Encodable, Sendable, Equatable {
    let source = "browser"
    let kind: ProblemReportKind
    let name: String
    let message: String
    let stack: [String]
    let appVersion: String
    let platform: String
    let context: [String: String]
    let userDescription: String

    private enum CodingKeys: String, CodingKey {
        case source, kind, name, message, stack, appVersion, platform, context, userDescription
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(message, forKey: .message)
        try container.encode(stack, forKey: .stack)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(platform, forKey: .platform)
        try container.encode(context, forKey: .context)
        try container.encode(userDescription, forKey: .userDescription)
    }

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var currentPlatform: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// A report a person wrote by hand. Their words are the whole point, so
    /// they travel verbatim; nothing about the page they were on is added.
    static func written(description: String) -> ProblemReport {
        ProblemReport(
            kind: .report,
            name: "Reported by a person",
            message: "",
            stack: [],
            appVersion: currentAppVersion,
            platform: currentPlatform,
            context: [:],
            userDescription: description.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Turns MetricKit's crash payloads into reports. Kept free of MetricKit types
/// so the parsing — the part that actually breaks — is unit-testable without
/// having to crash a real process to produce a fixture.
enum CrashCallStackParser {
    /// Flattens `MXCallStackTree.jsonRepresentation()` into frames.
    ///
    /// The tree nests every frame under `subFrames`, and the thread that
    /// actually crashed is the one flagged `threadAttributed`. Taking the
    /// frames in tree order from that thread reproduces the call stack that a
    /// person would read top-down in a crash log.
    static func frames(fromCallStackTreeJSON data: Data) -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let callStacks = root["callStacks"] as? [[String: Any]]
        else { return [] }

        let attributed = callStacks.first { $0["threadAttributed"] as? Bool == true }
        let chosen = attributed ?? callStacks.first
        guard let rootFrames = chosen?["callStackRootFrames"] as? [[String: Any]] else { return [] }

        var frames: [String] = []
        for frame in rootFrames {
            appendFrames(from: frame, into: &frames)
        }
        return Array(frames.prefix(60))
    }

    private static func appendFrames(from frame: [String: Any], into frames: inout [String]) {
        guard frames.count < 60 else { return }
        if let described = describe(frame) {
            frames.append(described)
        }
        for subFrame in frame["subFrames"] as? [[String: Any]] ?? [] {
            appendFrames(from: subFrame, into: &frames)
        }
    }

    private static func describe(_ frame: [String: Any]) -> String? {
        let binary = frame["binaryName"] as? String ?? "unknown"
        guard let offset = frame["offsetIntoBinaryTextSegment"] as? NSNumber else {
            return binary
        }
        return "\(binary) +\(offset.intValue)"
    }
}

enum CrashReportBuilder {
    /// Identifies one crash across MetricKit deliveries. A payload can arrive
    /// more than once, and the same defect recurs across launches; sending it
    /// twice would be pure noise on an issue the intake has already filed.
    static func signature(name: String, frames: [String], appVersion: String) -> String {
        let top = frames.prefix(5).joined(separator: "|")
        return "\(appVersion)#\(name)#\(top)"
    }

    static func report(
        name: String,
        message: String,
        frames: [String],
        appVersion: String,
        platform: String,
        context: [String: String]
    ) -> ProblemReport {
        ProblemReport(
            kind: .crash,
            name: name,
            message: message,
            stack: frames,
            appVersion: appVersion,
            platform: platform,
            context: context,
            userDescription: ""
        )
    }
}
