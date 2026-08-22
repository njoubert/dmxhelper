// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// `IOSSIOSPEED` from <IOKit/serial/ioss.h> — `_IOW('T', 2, speed_t)`; the macro doesn't import into Swift.
private let IOSSIOSPEED: UInt = 0x8008_5402

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

    /// Default baud. The DMX USB Pro's data path ignores it (FTDI FIFO → MCU), but the
    /// macOS driver's close()/drain accounting is *bytes ÷ baud*, so a low value makes
    /// close() — and process exit — stall for seconds after streaming. Use the FTDI max.
    public static let defaultBaud: speed_t = 3_000_000

    public func open(baud: speed_t = SerialPort.defaultBaud) throws {
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
        // termios only knows the standard rates; anything above 230400 must go through
        // IOSSIOSPEED after tcsetattr (below).
        cfsetspeed(&tio, min(baud, speed_t(B230400)))
        // VMIN/VTIME for reads: return whatever is available after 100ms.
        withUnsafeMutablePointer(to: &tio.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
        }
        guard tcsetattr(f, TCSANOW, &tio) == 0 else { let e = errno; Darwin.close(f); throw SerialError.configure(path, e) }
        if baud > speed_t(B230400) {
            var speed = baud
            if ioctl(f, IOSSIOSPEED, &speed) != 0 { let e = errno; Darwin.close(f); throw SerialError.configure(path, e) }
        }
        tcflush(f, TCIOFLUSH)
        fd = f
    }

    /// Discards any un-transmitted output, then closes. (Closing a serial port with
    /// pending output makes the kernel wait for it to drain, and any other process trying
    /// to open the port blocks behind that.)
    public func close() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
        Darwin.close(fd)
        fd = -1
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

    /// One read() of whatever the driver already has buffered, up to `max` bytes.
    /// With VMIN=0/VTIME=1 this blocks at most ~100 ms on a quiet port, which makes it a
    /// self-pacing read loop: no sleep needed, and no spinning.
    public func readAvailable(max: Int = 8192) -> [UInt8] {
        guard fd >= 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, max) }
        guard n > 0 else { return [] }
        return Array(buf[0..<n])
    }

    /// Bytes still queued in the kernel tty output queue (not yet handed to the USB driver).
    /// Grows when we write faster than the device drains.
    public var outputQueueDepth: Int {
        guard fd >= 0 else { return 0 }
        var n: Int32 = 0
        return ioctl(fd, TIOCOUTQ, &n) == 0 ? Int(n) : 0
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
