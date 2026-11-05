import Foundation

struct QuickCaptureListContinuation: Equatable {
    let indent: String
    let prefix: String
    let endsList: Bool
}

enum QuickCaptureMarkdownContinuation {
    static func continuation(for line: String) -> QuickCaptureListContinuation? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = bulletPattern.firstMatch(in: line, range: range) {
            let indent = substring(line, range: match.range(at: 1))
            let marker = substring(line, range: match.range(at: 2))
            let content = substring(line, range: match.range(at: 3))
            return QuickCaptureListContinuation(
                indent: indent,
                prefix: "\(indent)\(marker) ",
                endsList: content.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        if let match = numberedPattern.firstMatch(in: line, range: range) {
            let indent = substring(line, range: match.range(at: 1))
            let number = Int(substring(line, range: match.range(at: 2))) ?? 0
            let punctuation = substring(line, range: match.range(at: 3))
            let content = substring(line, range: match.range(at: 4))
            return QuickCaptureListContinuation(
                indent: indent,
                prefix: "\(indent)\(number + 1)\(punctuation) ",
                endsList: content.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        return nil
    }

    private static func substring(_ source: String, range: NSRange) -> String {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: source) else { return "" }
        return String(source[swiftRange])
    }

    private static let bulletPattern = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+])\s+(.*)$"#
    )
    private static let numberedPattern = try! NSRegularExpression(
        pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#
    )
}
