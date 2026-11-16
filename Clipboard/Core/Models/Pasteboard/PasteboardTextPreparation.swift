import AppKit

enum PasteboardTextPreparation {
    nonisolated static func prepareForSave(_ text: String) -> PasteContent? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        let data = Data(text.utf8)
        return PasteContent(
            type: .string,
            data: data,
            showData: nil,
            searchText: text,
            length: text.utf16.count,
            tag: PasteboardModel.calculateTextTag(text)
        )
    }

    nonisolated struct Content: Sendable {
        let showData: Data
        let searchText: String
        let length: Int
        let uniqueId: String
        let tag: String
    }

    nonisolated static func prepare(_ data: Data) -> Content? {
        guard let text = String(data: data, encoding: .utf8),
              !text.allSatisfy(\.isWhitespace) else { return nil }
        return Content(
            showData: Data(),
            searchText: PasteboardModel.normalizeSearchText(text),
            length: text.utf16.count,
            uniqueId: data.sha256Hex,
            tag: PasteboardModel.calculateTextTag(text)
        )
    }
}
