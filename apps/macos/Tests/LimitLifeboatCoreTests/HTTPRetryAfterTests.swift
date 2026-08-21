import XCTest
@testable import LimitLifeboatCore

final class HTTPRetryAfterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testParsesDelaySeconds() {
        XCTAssertEqual(HTTPRetryAfter.seconds(from: "120", now: now), 120)
        XCTAssertEqual(HTTPRetryAfter.seconds(from: "  45  ", now: now), 45)
        XCTAssertEqual(HTTPRetryAfter.seconds(from: "0", now: now), 0)
    }

    func testParsesHTTPDateRelativeToNow() {
        let deadline = now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let parsed = HTTPRetryAfter.seconds(from: formatter.string(from: deadline), now: now)

        // The header has whole-second resolution, so allow the sub-second
        // remainder of `now` to be dropped.
        XCTAssertEqual(try XCTUnwrap(parsed), 90, accuracy: 1)
    }

    func testAlreadyElapsedValuesClampToZeroRatherThanGoingNegative() {
        XCTAssertEqual(HTTPRetryAfter.seconds(from: "-60", now: now), 0)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let past = formatter.string(from: now.addingTimeInterval(-600))

        XCTAssertEqual(HTTPRetryAfter.seconds(from: past, now: now), 0)
    }

    func testUnparseableOrAbsentHeadersReadAsNoGuidance() {
        XCTAssertNil(HTTPRetryAfter.seconds(from: nil, now: now))
        XCTAssertNil(HTTPRetryAfter.seconds(from: "", now: now))
        XCTAssertNil(HTTPRetryAfter.seconds(from: "   ", now: now))
        XCTAssertNil(HTTPRetryAfter.seconds(from: "soon", now: now))
        XCTAssertNil(HTTPRetryAfter.seconds(from: "2026-08-20T09:12:00Z", now: now))
    }
}
