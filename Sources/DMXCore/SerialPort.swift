import Foundation
import Darwin

/// Minimal POSIX serial port wrapper (raw 8N1, no flow control).
public final class SerialPort: @unchecked Sendable {
    public enum SerialError: Error, LocalizedError {
        case open(String, Int32)
        case configure(String, Int32)
        case write(Int32)
        case notOpen

        public var errorDescription: String? {
            switch self {
            case .open(let path, let e): return "open(\(path)) failed: \(String(cString: strerror(e)))"
            case .configure(let path, let e): return "termios setup for \(path) failed: \(String(cString: strerror(e)))"
            case .write(let e): return "write failed: \(String(cString: strerror(e)))"
            case .notOpen: return "serial port is not open"
            }
        }
    }

    public private(set) var fd: Int32 = -1
    public let path: String

    public init(path: String) { self.path = path }
    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    public func open(baud: speed_t = 115_200) throws {
        guard fd < 0 else { return }
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw SerialError.open(path, errno) }

        // Exclusive access; ignore failure (not fatal).
        _ = ioctl(f, TIOCEXCL)

        // Back to blocking I/O for simple write() semantics.
        let flags = fcntl(f, F_GETFL)
        _ = fcntl(f, F_SETFL, flags & ~O_NONBLOCK)

        var tio = termios()
        guard tcgetattr(f, &tio) == 0 else { let e = errno; Darwin.close(f); throw SerialError.configure(path, e) }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(CSIZE)
        tio.c_cflag |= tcflag_t(CS8)
        tio.c_cflag &= ~tcflag_t(PARENB)          // no parity
        tio.c_cflag &= ~tcflag_t(CSTOPB)          // 1 stop bit
        tio.c_cflag &= ~tcflag_t(CRTSCTS)         // no HW flow control
        tio.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        cfsetspeed(&tio, baud)
        // VMIN/VTIME for reads: return whatever is available after 100ms.
        withUnsafeMutablePointer(to: &tio.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
        }
        guard tcsetattr(f, TCSANOW, &tio) == 0 else { let e = errno; Darwin.close(f); throw SerialError.configure(path, e) }
        tcflush(f, TCIOFLUSH)
        fd = f
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    public func write(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        try bytes.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SerialError.write(errno)
                }
                offset += n
            }
        }
    }

    /// Read up to `max` bytes, waiting at most `timeout` seconds total.
    public func read(max: Int, timeout: TimeInterval) -> [UInt8] {
        guard fd >= 0 else { return [] }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: max)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < max && Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, max - out.count) }
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
            else if n < 0 && errno != EAGAIN && errno != EINTR { break }
        }
        return out
    }

    /// Enumerate candidate serial devices.
    public static func availablePorts() -> [String] {
        let dev = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return dev
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .map { "/dev/" + $0 }
            .sorted { a, b in
                // Prefer usbserial/usbmodem devices first.
                let ua = a.contains("usb"), ub = b.contains("usb")
                if ua != ub { return ua }
                return a < b
            }
    }
}
