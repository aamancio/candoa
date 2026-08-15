import SwiftUI

/// "What Eli Knows": the per-Space memory surface. Shows every saved fact
/// and lets the user delete facts one by one or all at once. Memory has no
/// off switch by design (always on outside private browsing, like sync);
/// deliberately popover-only, mirroring how Site Info keeps per-site state
/// next to where it applies.
struct EliMemoryPopoverView: View {
    @ObservedObject var store: BrowserStore
    @State private var facts: [SpaceMemoryFact] = []

    private var spaceName: String {
        let name = store.activeSpace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "This Space") : name
    }

    var body: some View {
        Group {
            if facts.isEmpty {
                emptyBody
            } else {
                factsBody
            }
        }
        .padding(14)
        .onAppear {
            facts = store.activeSpaceMemoryFacts()
        }
    }

    /// An empty list needs no heading and no explanation of what memory is —
    /// just the plain fact that there is nothing here, the way an empty
    /// history list reads.
    private var emptyBody: some View {
        Text("Nothing saved yet.")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("eli-memory-title")
            .frame(width: 150, alignment: .leading)
    }

    private var factsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What Eli Knows")
                    .font(.system(size: 13.5, weight: .semibold))
                    .accessibilityIdentifier("eli-memory-title")
                Text(verbatim: spaceName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // A plain stack, not a ScrollView: scroll content inside an
            // NSPopover reports offset accessibility frames, which makes
            // the rows unclickable for AX clients. The fact cap keeps the
            // list popover-sized.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    factRow(fact, index: index)
                }
            }

            Button("Forget All", role: .destructive) {
                store.deleteActiveSpaceMemory()
                facts = []
            }
            .controlSize(.small)
            .accessibilityIdentifier("eli-memory-forget-all")

            Text("Saved details stay in this Space and never leave it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
    }

    private func factRow(_ fact: SpaceMemoryFact, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: fact.content)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.deleteSpaceMemoryFact(fact.id)
                facts.removeAll { $0.id == fact.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Forget This Detail")
            .accessibilityIdentifier("eli-memory-delete-\(index)")
        }
        .padding(.vertical, 3)
    }
}
