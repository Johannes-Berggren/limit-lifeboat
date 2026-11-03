import XCTest
@testable import LimitLifeboatCore

final class SwitchFinalCheckPolicyTests: XCTestCase {
    func testContinuesWhenTheVerifiedLoginIsUnchanged() {
        XCTAssertTrue(SwitchFinalCheckPolicy.mayContinueAfterRateLimit(
            targetVerifiedBeforeLease: true,
            fingerprintBeforeLease: "a",
            currentFingerprint: "a"
        ))
    }

    func testStopsWhenTheFirstCheckDidNotVerifyTheTarget() {
        XCTAssertFalse(SwitchFinalCheckPolicy.mayContinueAfterRateLimit(
            targetVerifiedBeforeLease: false,
            fingerprintBeforeLease: "a",
            currentFingerprint: "a"
        ))
    }

    func testStopsWhenTheSavedLoginChangedSinceTheFirstCheck() {
        XCTAssertFalse(SwitchFinalCheckPolicy.mayContinueAfterRateLimit(
            targetVerifiedBeforeLease: true,
            fingerprintBeforeLease: "a",
            currentFingerprint: "b"
        ))
    }

    func testStopsWhenEitherFingerprintIsMissing() {
        XCTAssertFalse(SwitchFinalCheckPolicy.mayContinueAfterRateLimit(
            targetVerifiedBeforeLease: true,
            fingerprintBeforeLease: "a",
            currentFingerprint: nil
        ))
        XCTAssertFalse(SwitchFinalCheckPolicy.mayContinueAfterRateLimit(
            targetVerifiedBeforeLease: true,
            fingerprintBeforeLease: nil,
            currentFingerprint: nil
        ))
    }
}
