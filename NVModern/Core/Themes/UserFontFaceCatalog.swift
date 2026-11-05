import AppKit
import CoreText
import CryptoKit
import Foundation

/// Makes fonts installed outside the system font folders usable in the
/// editor's web views.
///
/// WebKit hides fonts in `~/Library/Fonts` and `/Library/Fonts` from web
/// content, so a theme that names one (Michelangelus, Courier Prime) silently
/// falls back to the next face in its stack. For every family a stylesheet
/// names that lives outside `/System`, this emits `@font-face` rules pointing
/// at `nvmodern-font://face/<token>`, which `FontFaceSchemeHandler` serves.
/// Only files registered here are ever served.
enum UserFontFaceCatalog {
    static let scheme = "nvmodern-font"
    static let host = "face"

    struct Face: Equatable {
        let family: String
        let token: String
        /// PostScript name, for a face inside a `.ttc` collection.
        let collectionMember: String?
        let format: String?
        /// `400`, or `100 900` for a variable font's weight axis.
        let weight: String
        let isItalic: Bool
    }

    private static let lock = NSLock()
    private static var facesByFamily: [String: [Face]] = [:]
    private static var fileURLsByToken: [String: URL] = [:]

    /// `@font-face` rules for every user-installed family named in `css`.
    static func fontFaceCSS(forFamiliesIn css: String) -> String {
        referencedFamilies(in: css)
            .flatMap { faces(forFamily: $0) }
            .map(rule(for:))
            .joined(separator: "\n")
    }

    /// `css` followed by the `@font-face` rules it needs, if any.
    static func appendingFontFaces(to css: String?) -> String? {
        guard let css else { return nil }
        let faces = fontFaceCSS(forFamiliesIn: css)
        return faces.isEmpty ? css : css + "\n\n" + faces
    }

    static func fileURL(forToken token: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return fileURLsByToken[token]
    }

    // MARK: - Family names

    private static let familyDeclarationPattern = try? NSRegularExpression(
        pattern: #"(?:^|[;{\s])(font-family|--[A-Za-z0-9_-]*font-family|--nv3-font-(?:sans|display|label|mono))\s*:\s*([^;{}]+)"#
    )

    private static let genericFamilies: Set<String> = [
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "math", "emoji",
        "fangsong", "inherit", "initial", "unset", "revert", "normal",
    ]

    /// Concrete family names in `font-family` values and font tokens, in order.
    static func referencedFamilies(in css: String) -> [String] {
        guard let pattern = familyDeclarationPattern else { return [] }
        var seen = Set<String>()
        var families: [String] = []
        let range = NSRange(css.startIndex..., in: css)
        for match in pattern.matches(in: css, range: range) {
            guard let valueRange = Range(match.range(at: 2), in: css) else { continue }
            for rawPart in css[valueRange].split(separator: ",") {
                let name = rawPart
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !name.isEmpty,
                      !name.contains("("),
                      !name.hasPrefix("-"),
                      !name.lowercased().hasPrefix("ui-"),
                      !genericFamilies.contains(name.lowercased()),
                      seen.insert(name).inserted else {
                    continue
                }
                families.append(name)
            }
        }
        return families
    }

    // MARK: - Faces

    private static func faces(forFamily family: String) -> [Face] {
        lock.lock()
        if let cached = facesByFamily[family] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let (faces, files) = lookUpFaces(forFamily: family)

        lock.lock()
        facesByFamily[family] = faces
        fileURLsByToken.merge(files) { current, _ in current }
        lock.unlock()
        return faces
    }

    private static func lookUpFaces(forFamily family: String) -> ([Face], [String: URL]) {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else {
            return ([], [:])
        }

        var faces: [Face] = []
        var files: [String: URL] = [:]
        var seenFaces = Set<String>()
        for member in members {
            guard let postScriptName = member.first as? String else { continue }
            let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 0)
            guard let fileURL = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else {
                continue
            }
            // WebKit already sees system fonts.
            if fileURL.path.hasPrefix("/System/") { return ([], [:]) }

            let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
            let traits = CTFontCopyTraits(font) as NSDictionary
            let symbolicTraits = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let isItalic = symbolicTraits & CTFontSymbolicTraits.traitItalic.rawValue != 0
            let ext = fileURL.pathExtension.lowercased()
            let isCollection = ext == "ttc" || ext == "otc"
            let weightRange = weightAxisRange(of: font)

            // A variable font lists each named instance; one rule covers them.
            let faceKey = isCollection ? postScriptName : "\(fileURL.path)|\(isItalic)"
            guard seenFaces.insert(faceKey).inserted else { continue }

            let token = token(for: fileURL)
            files[token] = fileURL
            faces.append(Face(
                family: family,
                token: token,
                collectionMember: isCollection ? postScriptName : nil,
                format: format(forExtension: ext),
                weight: weightRange.map { "\($0.lowerBound) \($0.upperBound)" }
                    ?? String(cssWeight(fromTrait: (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0)),
                isItalic: isItalic
            ))
        }
        return (faces, files)
    }

    private static func weightAxisRange(of font: CTFont) -> ClosedRange<Int>? {
        let weightTag = 0x7767_6874 // 'wght'
        guard let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return nil }
        for axis in axes {
            guard (axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == weightTag,
                  let minimum = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let maximum = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                  minimum < maximum else {
                continue
            }
            return Int(minimum.rounded())...Int(maximum.rounded())
        }
        return nil
    }

    /// Core Text's normalized weight trait to the nearest CSS weight.
    private static func cssWeight(fromTrait trait: Double) -> Int {
        let scale: [(Double, Int)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
            (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900),
        ]
        return scale.min { abs($0.0 - trait) < abs($1.0 - trait) }?.1 ?? 400
    }

    private static func format(forExtension ext: String) -> String? {
        switch ext {
        case "ttf": return "truetype"
        case "otf": return "opentype"
        case "woff": return "woff"
        case "woff2": return "woff2"
        default: return nil
        }
    }

    private static func token(for fileURL: URL) -> String {
        let digest = SHA256.hash(data: Data(fileURL.path.utf8))
        let hex = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        let ext = fileURL.pathExtension.lowercased()
        return ext.isEmpty ? hex : "\(hex).\(ext)"
    }

    private static func rule(for face: Face) -> String {
        let family = face.family.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        let fragment = face.collectionMember.map { "#\($0)" } ?? ""
        let format = face.format.map { " format(\"\($0)\")" } ?? ""
        return """
        @font-face {
          font-family: "\(family)";
          src: url("\(scheme)://\(host)/\(face.token)\(fragment)")\(format);
          font-weight: \(face.weight);
          font-style: \(face.isItalic ? "italic" : "normal");
          font-display: block;
        }
        """
    }
}
