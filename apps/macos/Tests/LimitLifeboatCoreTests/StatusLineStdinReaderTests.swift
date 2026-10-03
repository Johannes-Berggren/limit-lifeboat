import XCTest
@testable import LimitLifeboatCore

final class StatusLineStdinReaderTests: XCTestCase {
    /// Claude Code hands the status line a socketpair, not a FIFO.
    func testReadsFromASocketpairLikeClaudeCode() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        let payload = Data(#"{"prompt_cache":{"warm":true,"ttl":"1h"}}"#.utf8)
        _ = payload.withUnsafeBytes { write(fds[1], $0.baseAddress, payload.count) }
        close(fds[1])

        XCTAssertEqual(StatusLineStdinReader.read(fd: fds[0]), payload)
    }

    func testGivesUpOnAnOpenSilentPipeWithinBudget() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let start = Date()

        XCTAssertNil(StatusLineStdinReader.read(fd: fds[0], budget: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
