import XCTest
@testable import nvModern

final class AppUpdaterTests: XCTestCase {
    private func bundle(info: [String: String]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString).bundle")
        let contents = dir.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var plist = info
        plist["CFBundleIdentifier"] = "test.updater"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(path: dir.path))
    }

    func testRequiresFeedAndPublicKey() throws {
        let both = try bundle(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "abc="])
        XCTAssertTrue(AppUpdater.isConfigured(bundle: both))
    }

    func testEmptyKeyDisablesUpdater() throws {
        let noKey = try bundle(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": ""])
        XCTAssertFalse(AppUpdater.isConfigured(bundle: noKey))
        let blank = try bundle(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "  "])
        XCTAssertFalse(AppUpdater.isConfigured(bundle: blank))
    }

    func testMissingFeedDisablesUpdater() throws {
        let noFeed = try bundle(info: ["SUPublicEDKey": "abc="])
        XCTAssertFalse(AppUpdater.isConfigured(bundle: noFeed))
    }
}
