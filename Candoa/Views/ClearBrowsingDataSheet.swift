import AppKit
import SwiftUI

/// The Clear History sheet, laid out the way Safari's is: the icon at the
/// leading edge, the text beside it, and the buttons on the trailing edge.
///
/// `NSAlert` is the native API for this and was what Candoa used, but on
/// current macOS it lays every alert out vertically with its buttons centered,
/// including window-modal sheets: a bare `NSAlert` — no accessory view, no
/// custom icon — presented with `beginSheetModal(for:)` renders centered, so
/// there is no configuration that produces Safari's layout. The sheet is still
/// assembled from system controls, and the parts an alert would own —
/// Escape cancels, Return confirms, destructive tint on the confirming
/// button — are kept.
struct ClearBrowsingDataSheet: View {
    let message: String
    let detail: String
    let onCancel: () -> Void
    let onClear: (HistoryClearRange) -> Void

    @State private var range: HistoryClearRange = .lastHour

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 13, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("Clear")
                            .font(.system(size: 12))

                        Picker("", selection: $range) {
                            ForEach(HistoryClearRange.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .accessibilityIdentifier("clear-browsing-data-range")
                    }
                    .padding(.top, 4)
                }
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button("Cancel", action: onCancel)
                    .buttonTreatment(.secondary)
                    .keyboardShortcut(.cancelAction)

                Button(BrowserCommandTitles.clearHistoryConfirmation) {
                    onClear(range)
                }
                .buttonTreatment(.primary)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("clear-browsing-data-confirm")
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
