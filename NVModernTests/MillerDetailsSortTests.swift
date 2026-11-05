import Foundation
import XCTest
@testable import nvModern

final class MillerDetailsSortTests: XCTestCase {
    private let workspace = LaunchpadRootColumn.workspacePath
    private let recent = LaunchpadRootColumn.recentPath

    // MARK: — folder keys

    func testRootColumnHasNoKeyAndDeeperColumnsKeyByChain() {
        let chain = [workspace, "Projects", "Projects/Alpha"]
        XCTAssertNil(MillerDetailsSortResolver.folderKey(chain: chain, depth: 0))
        XCTAssertEqual(MillerDetailsSortResolver.folderKey(chain: chain, depth: 1), workspace)
        XCTAssertEqual(MillerDetailsSortResolver.folderKey(chain: chain, depth: 2), "Projects")
        XCTAssertEqual(MillerDetailsSortResolver.folderKey(chain: chain, depth: 3), "Projects/Alpha")
        XCTAssertNil(MillerDetailsSortResolver.folderKey(chain: chain, depth: 4))
    }

    func testUnrootedChainIsNormalizedBeforeKeying() {
        XCTAssertEqual(MillerDetailsSortResolver.folderKey(chain: ["Inbox"], depth: 1), workspace)
        XCTAssertEqual(MillerDetailsSortResolver.folderKey(chain: ["Inbox"], depth: 2), "Inbox")
    }

    // MARK: — inheritance

    func testDefaultIsNameAscendingWithoutOverrides() {
        let sort = MillerDetailsSortResolver.effectiveSort(chain: [workspace, "Inbox"], depth: 2) { _ in nil }
        XCTAssertEqual(sort, MillerDetailsSort(field: .name, ascending: true))
    }

    func testRecentDefaultsToNewestFirst() {
        let sort = MillerDetailsSortResolver.effectiveSort(chain: [recent], depth: 1) { _ in nil }
        XCTAssertEqual(sort, .recentDefault)
    }

    func testChildInheritsParentOverride() {
        let byDate = MillerDetailsSort(field: .modified, ascending: false)
        let overrides = ["Projects": byDate]
        let chain = [workspace, "Projects", "Projects/Alpha", "Projects/Alpha/Notes"]

        let deepest = MillerDetailsSortResolver.effectiveSort(chain: chain, depth: 4) { overrides[$0] }
        XCTAssertEqual(deepest, byDate, "grandchild column inherits the nearest ancestor override")

        let parent = MillerDetailsSortResolver.effectiveSort(chain: chain, depth: 1) { overrides[$0] }
        XCTAssertEqual(parent, MillerDetailsSort(), "an override never flows upward")
    }

    func testOwnOverrideBeatsInheritedOne() {
        let overrides = [
            "Projects": MillerDetailsSort(field: .modified, ascending: false),
            "Projects/Alpha": MillerDetailsSort(field: .kind, ascending: true)
        ]
        let chain = [workspace, "Projects", "Projects/Alpha"]
        let sort = MillerDetailsSortResolver.effectiveSort(chain: chain, depth: 3) { overrides[$0] }
        XCTAssertEqual(sort.field, .kind)
    }

    func testRootOverrideIsScopedToItsRoot() {
        let overrides = [workspace: MillerDetailsSort(field: .modified, ascending: false)]
        let underRecent = MillerDetailsSortResolver.effectiveSort(chain: [recent], depth: 1) { overrides[$0] }
        XCTAssertEqual(underRecent, .recentDefault)
    }

    // MARK: — selection semantics

    func testSelectingSameFieldFlipsAndNewDateFieldStartsNewestFirst() {
        var sort = MillerDetailsSort()
        sort.select(.name)
        XCTAssertEqual(sort, MillerDetailsSort(field: .name, ascending: false))
        sort.select(.modified)
        XCTAssertEqual(sort, MillerDetailsSort(field: .modified, ascending: false))
        sort.select(.modified)
        XCTAssertTrue(sort.ascending)
    }

    func testStorageRoundTrip() {
        for field in MillerDetailsSortField.allCases {
            for ascending in [true, false] {
                let sort = MillerDetailsSort(field: field, ascending: ascending)
                XCTAssertEqual(MillerDetailsSort(storageValue: sort.storageValue), sort)
            }
        }
        XCTAssertNil(MillerDetailsSort(storageValue: "garbage"))
        XCTAssertNil(MillerDetailsSort(storageValue: "name:sideways"))
    }

    // MARK: — sorting

    func testFoldersAlwaysComeFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let items = [
            MillerItem(relativePath: "b.md", name: "b.md", kind: .note, modifiedDate: new),
            MillerItem(relativePath: "Zed", name: "Zed", kind: .folder, modifiedDate: old),
            MillerItem(relativePath: "a.md", name: "a.md", kind: .note, modifiedDate: old)
        ]

        let byDate = MillerDetailsSort(field: .modified, ascending: false).sorted(items).map(\.name)
        XCTAssertEqual(byDate, ["Zed", "b.md", "a.md"])

        let byName = MillerDetailsSort(field: .name, ascending: true).sorted(items).map(\.name)
        XCTAssertEqual(byName, ["Zed", "a.md", "b.md"])
    }

    func testOrderedColumnsMatchDetailsSortUsedBySelection() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let root = MillerItem(relativePath: workspace, name: "Workspace", kind: .folder, modifiedDate: nil)
        let first = MillerItem(relativePath: "Inbox/a.md", name: "a.md", kind: .note, modifiedDate: old)
        let second = MillerItem(relativePath: "Inbox/b.md", name: "b.md", kind: .note, modifiedDate: new)
        let columns = [[root], [first, second]]
        let byDate = MillerDetailsSort(field: .modified, ascending: false)

        let plain = MillerDetailsSortResolver.orderedColumns(
            columns, chain: [workspace], detailsEnabled: false
        ) { _ in byDate }
        XCTAssertEqual(plain[1].map(\.name), ["a.md", "b.md"])

        let details = MillerDetailsSortResolver.orderedColumns(
            columns, chain: [workspace], detailsEnabled: true
        ) { _ in byDate }
        XCTAssertEqual(details[0], columns[0], "the synthetic root keeps its fixed order")
        XCTAssertEqual(details[1].map(\.name), ["b.md", "a.md"])
    }

    // MARK: — compact dates

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    func testCompactDateBuckets() {
        let calendar = fixedCalendar()
        let locale = Locale(identifier: "en_US_POSIX")
        let now = date("2026-09-08T15:00:00Z") // a Tuesday

        func stamp(_ iso: String) -> String {
            MillerCompactDate.string(for: date(iso), now: now, calendar: calendar, locale: locale)
        }

        XCTAssertEqual(stamp("2026-09-08T09:05:00Z"), "09:05", "today shows the time")
        XCTAssertEqual(stamp("2026-09-07T23:59:00Z"), "Mon", "yesterday shows the weekday")
        XCTAssertEqual(stamp("2026-09-02T12:00:00Z"), "Wed", "six days ago still shows the weekday")
        XCTAssertEqual(stamp("2026-09-01T12:00:00Z"), "Sep 1", "a week ago falls back to month and day")
        XCTAssertEqual(stamp("2026-01-15T12:00:00Z"), "Jan 15")
        XCTAssertEqual(stamp("2025-12-31T12:00:00Z"), "2025", "older years show only the year")
        XCTAssertEqual(stamp("2026-09-20T12:00:00Z"), "Sep 20", "clock skew into the future is not a weekday")
    }

    func testCompactStampsFitTheColumn() {
        let calendar = fixedCalendar()
        let locale = Locale(identifier: "en_US_POSIX")
        let now = date("2026-12-31T23:00:00Z")
        for iso in ["2026-12-31T00:01:00Z", "2026-12-28T00:00:00Z", "2026-11-30T00:00:00Z", "2020-01-01T00:00:00Z"] {
            let stamp = MillerCompactDate.string(for: date(iso), now: now, calendar: calendar, locale: locale)
            XCTAssertLessThanOrEqual(stamp.count, 6, stamp)
        }
    }
}
