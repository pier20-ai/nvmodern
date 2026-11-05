import XCTest
@testable import nvModern

final class PluginFailureNotificationPolicyTests: XCTestCase {
    func testLoadFailuresAreDeduplicatedAndRearmedAfterRecovery() {
        var policy = PluginFailureNotificationPolicy()
        XCTAssertEqual(policy.loadFailuresToNotify(["a.js: bad", "a.js: bad"]), ["a.js: bad"])
        XCTAssertEqual(policy.loadFailuresToNotify(["a.js: bad"]), [])
        XCTAssertEqual(policy.loadFailuresToNotify(["a.js: bad", "b.js: bad"]), ["b.js: bad"])
        XCTAssertEqual(policy.loadFailuresToNotify(["a.js: changed", "b.js: bad"]), ["a.js: changed"])
        XCTAssertEqual(policy.loadFailuresToNotify([]), [])
        XCTAssertEqual(policy.loadFailuresToNotify(["a.js: changed"]), ["a.js: changed"])
    }

    func testRuntimeFailureCooldownIsPerMethodAndDoesNotExtendOnSuppression() {
        var policy = PluginFailureNotificationPolicy()
        XCTAssertTrue(policy.shouldNotifyRuntimeFailure(method: "plugin.a.run", uptime: 100))
        XCTAssertFalse(policy.shouldNotifyRuntimeFailure(method: "plugin.a.run", uptime: 109.9))
        XCTAssertTrue(policy.shouldNotifyRuntimeFailure(method: "plugin.b.run", uptime: 109.9))
        XCTAssertTrue(policy.shouldNotifyRuntimeFailure(method: "plugin.a.run", uptime: 110))
        XCTAssertFalse(policy.shouldNotifyRuntimeFailure(method: "plugin.a.run", uptime: 110.1))
    }
}
