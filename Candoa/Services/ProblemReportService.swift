import Foundation
import MetricKit
import OSLog

/// Whether this Mac shares problem reports, and the delivery of those reports
/// to Candoa Cloud's intake.
///
/// Sharing is off until someone turns it on. A browser sees more of a person's
/// life than almost any other app they run, so nothing about a failure leaves
/// this Mac by default — not even an anonymous crash. Turning it on shares the
/// code that broke, never the pages they were on.
enum ProblemReportConsent {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsOption.shareProblemReports) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsOption.shareProblemReports) }
    }
}

enum ProblemReportError: Error, Equatable {
    case emptyDescription
    case rejected(status: Int)
    case transport
}

/// Posts reports to the intake. Delivery is best effort by design: failing to
/// report a problem must never itself become a problem a person notices.
actor ProblemReportSubmitter {
    static let shared = ProblemReportSubmitter()

    private static let logger = Logger(
        subsystem: "app.candoa.browser",
        category: "ProblemReport"
    )

    /// Crash signatures already sent, so a redelivered MetricKit payload or a
    /// defect that recurs across launches does not re-send.
    private static let sentSignaturesKey = "Candoa.ProblemReport.SentCrashSignatures"

    /// A person choosing "Send" is an explicit act, so it reports whatever the
    /// preference says — the act itself is the consent. It deliberately does
    /// not flip the preference for future automatic crash reports.
    func submitWritten(description: String) async throws {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProblemReportError.emptyDescription }
        try await post(ProblemReport.written(description: trimmed))
    }

    /// Automatic reports, which run only with consent.
    func submitAutomatic(_ reports: [ProblemReport]) async {
        guard ProblemReportConsent.isEnabled else { return }

        var sent = Self.sentSignatures()
        for report in reports {
            let signature = CrashReportBuilder.signature(
                name: report.name,
                frames: report.stack,
                appVersion: report.appVersion
            )
            guard !sent.contains(signature) else { continue }
            do {
                try await post(report)
                sent.insert(signature)
                Self.storeSentSignatures(sent)
            } catch {
                // Left unrecorded on purpose: an unsent crash should be
                // retried after the next launch rather than silently dropped.
                Self.logger.error("Could not send a crash report: \(String(describing: error))")
            }
        }
    }

    private func post(_ report: ProblemReport) async throws {
        let request = try Self.request(for: report)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw ProblemReportError.transport
            }
            guard (200..<300).contains(status) else {
                throw ProblemReportError.rejected(status: status)
            }
        } catch let error as ProblemReportError {
            throw error
        } catch {
            throw ProblemReportError.transport
        }
    }

    private static func request(for report: ProblemReport) throws -> URLRequest {
        var request = URLRequest(url: CloudAPI.problemReportURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        request.timeoutInterval = 20
        return request
    }

    private static func sentSignatures() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: sentSignaturesKey) ?? [])
    }

    private static func storeSentSignatures(_ signatures: Set<String>) {
        // Bounded so a long-lived install cannot grow the list without limit.
        let bounded = Array(signatures.sorted().suffix(200))
        UserDefaults.standard.set(bounded, forKey: sentSignaturesKey)
    }
}

/// Receives crash diagnostics from the system.
///
/// A sandboxed app cannot read `~/Library/Logs/DiagnosticReports`, so MetricKit
/// is the only route to a real crash log here. The system hands payloads over
/// on its own schedule — typically once a day rather than on the next launch —
/// so a crash reaches the tracker late, but it reaches it with a genuine stack
/// instead of whatever an in-process handler managed to write while dying.
// `@unchecked Sendable` is accurate rather than a waiver: the reporter holds no
// stored state at all. MetricKit calls back on a queue of its own choosing, and
// everything mutable lives behind the submitter actor.
final class CrashDiagnosticReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics are not problem reports.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap(Self.reports(from:))
        guard !reports.isEmpty else { return }
        Task {
            await ProblemReportSubmitter.shared.submitAutomatic(reports)
        }
    }

    /// MetricKit types stay inside this function so everything downstream is
    /// plain values that tests can build without a crashed process.
    static func reports(from payload: MXDiagnosticPayload) -> [ProblemReport] {
        (payload.crashDiagnostics ?? []).map { diagnostic in
            let frames = CrashCallStackParser.frames(
                fromCallStackTreeJSON: diagnostic.callStackTree.jsonRepresentation()
            )
            var context: [String: String] = [:]
            if let signal = diagnostic.signal {
                context["signal"] = signal.stringValue
            }
            if let exceptionType = diagnostic.exceptionType {
                context["exceptionType"] = exceptionType.stringValue
            }
            if let exceptionCode = diagnostic.exceptionCode {
                context["exceptionCode"] = exceptionCode.stringValue
            }
            return CrashReportBuilder.report(
                name: diagnostic.terminationReason ?? "Crash",
                message: diagnostic.virtualMemoryRegionInfo ?? "",
                frames: frames,
                appVersion: diagnostic.applicationVersion,
                platform: "macOS \(diagnostic.metaData.osVersion)",
                context: context
            )
        }
    }
}
