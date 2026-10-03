import Foundation

/// Reads the session JSON Claude Code hands a status line, without ever
/// blocking a shell prompt.
///
/// Claude Code (a Bun binary) spawns the command with a Unix socketpair as
/// stdin, not a FIFO, so sockets have to be read. The same command also runs
/// from shell prompts, tmux, and bar widgets that pass a terminal or an
/// inherited descriptor nobody ever closes. So: never a terminal or other
/// character device, never longer than `budget` in total, at most 1 MB.
public enum StatusLineStdinReader {
    public static func read(fd: Int32, budget: TimeInterval = 0.15) -> Data? {
        guard isatty(fd) == 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        guard type == S_IFIFO || type == S_IFREG || type == S_IFSOCK else { return nil }

        let deadline = Date().addingTimeInterval(budget)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 1_048_576 {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1_000)
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
