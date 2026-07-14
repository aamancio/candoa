import Foundation

extension BrowserStore {
    func activeAIPageContext() async -> CandoaAIPageContext {
        await aiPageContext(for: activeTabID)
    }

    func aiPageContext(for tabID: UUID?) async -> CandoaAIPageContext {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        let pageText: String?
        let controlsText: String?
        let imageText: String?
        if let tabID = tab?.id {
            pageText = await webCoordinator.readablePageText(for: tabID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            controlsText = await webCoordinator.visiblePageControlsText(for: tabID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            imageText = await visiblePageOCRText(for: tabID)
        } else {
            pageText = nil
            controlsText = nil
            imageText = nil
        }
        let pageTextSection = pageText.map { "Full page semantic text:\n\($0)" }
        let imageTextSection = imageText.map { "Visible page image text from OCR:\n\($0)" }
        let combinedText = [pageTextSection, controlsText, imageTextSection]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        return CandoaAIPageContext(
            title: tab?.title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: tab?.url?.absoluteString,
            text: combinedText.isEmpty ? nil : combinedText
        )
    }

    func performAIPageAction(_ action: CandoaPageActionProposal, in tabID: UUID?) async -> String {
        guard let tabID, tabs.contains(where: { $0.id == tabID }) else {
            return "That page is no longer open."
        }

        return await webCoordinator.performAIPageAction(action, for: tabID)
    }

    private func visiblePageOCRText(for tabID: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            webCoordinator.captureVisiblePage(for: tabID) { image in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CandoaImageTextRecognizer.recognizedText(in: image))
            }
        }
    }
}
