import Foundation

enum CandoaEliContextSections {
    static func semanticPageText(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        let markerStarts = [
            contextText.range(of: "Visible page controls and links:")?.lowerBound,
            contextText.range(of: "Visible page image text from OCR:")?.lowerBound,
        ].compactMap { $0 }

        if let firstMarkerStart = markerStarts.min() {
            return String(contextText[..<firstMarkerStart])
        }
        return contextText
    }

    static func visibleControlsSection(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        guard let controlsRange = contextText.range(of: "Visible page controls and links:") else { return nil }
        let controlsTail = contextText[controlsRange.upperBound...]
        let controlsEnd = controlsTail.range(of: "\n\nVisible page image text from OCR:")?.lowerBound
            ?? controlsTail.endIndex
        let section = String(controlsTail[..<controlsEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    static func visibleOCRSection(from contextText: String?) -> String? {
        guard let contextText else { return nil }
        guard let ocrRange = contextText.range(of: "Visible page image text from OCR:") else { return nil }
        let section = String(contextText[ocrRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }
}
