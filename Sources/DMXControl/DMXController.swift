import Foundation
import DMXCore
import Combine

/// Owns the 512-channel universe and streams it to an Enttec DMX USB Pro.
///
/// UI mutates `channels` on the main actor; a background timer snapshots the
/// frame under a lock and writes it to the widget at `frameRate` Hz.
@MainActor
final class DMXController: ObservableObject {
    // MARK: Published UI state
    @Published private(set) var channels: [UInt8] = Array(repeating: 0, count: 512)
    @Published var selectedPort: String = ""
    @Published private(set) var availablePorts: [String] = []
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "Disconnected"
    @Published private(set) var widgetInfo: String = ""
    @Published private(set) var framesSent: Int = 0
    @Published var frameRate: Double = 30 { didSet { restartTimerIfNeeded() } }

    /// Snapshot of what was most recently written to the widget, for the debug panel.
    struct OutputDebug {
        var lastPacket: [UInt8] = []          // full Enttec message, header..E7
        var lastSentAt: Date? = nil
        var measuredFPS: Double = 0
        var bytesSent: Int = 0
        var writeErrors: Int = 0
    }
    @Published private(set) var debug = OutputDebug()
    /// Timestamped log of every frame whose content differed from the previous one.
    @Published private(set) var changeLog: [String] = []
    static let changeLogLimit = 200

    // MARK: Private
    // Shared with the ioQueue timer; every access goes through `lock`.
    private let lock = NSLock()
    nonisolated(unsafe) private var frame: [UInt8] = Array(repeating: 0, count: 512)
    nonisolated(unsafe) private var port: SerialPort?
    nonisolated(unsafe) private var sentCounter = 0
    nonisolated(unsafe) private var bytesCounter = 0
    // ioQueue-only state (never touched from main):
    nonisolated(unsafe) private var lastSnapshot: [UInt8]? = nil
    nonisolated(unsafe) private var sendTimes: [TimeInterval] = []
    nonisolated(unsafe) private var pendingLog: [String] = []
    nonisolated(unsafe) private var lastPacketSent: [UInt8] = []
    nonisolated(unsafe) private var lastSendTime: Date? = nil
    private let ioQueue = DispatchQueue(label: "dmx.enttec.io", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    init() {
        refreshPorts()
        // Auto-pick the Enttec if it's there.
        if let ent = availablePorts.first(where: { $0.contains("usbserial") }) { selectedPort = ent }
    }

    // MARK: Ports

    func refreshPorts() {
        availablePorts = SerialPort.availablePorts()
        if !availablePorts.contains(selectedPort) { selectedPort = availablePorts.first ?? "" }
    }

    func connect() {
        guard !isConnected, !selectedPort.isEmpty else { return }
        let path = selectedPort
        statusMessage = "Opening \(path)…"
        ioQueue.async { [weak self] in
            let p = SerialPort(path: path)
            var info = ""
            var err: String?
            do {
                try p.open()
                // Query the widget so we can confirm it's really an Enttec Pro.
                try p.write(EnttecPro.getSerialRequest())
                let serialResp = p.read(max: 64, timeout: 0.5)
                try p.write(EnttecPro.getParametersRequest())
                let paramResp = p.read(max: 64, timeout: 0.5)
                var parts: [String] = []
                if let m = EnttecPro.parseMessage(serialResp), m.label == EnttecPro.Label.getWidgetSerial.rawValue,
                   let s = EnttecPro.parseSerial(m.data) {
                    parts.append("S/N \(s)")
                }
                if let m = EnttecPro.parseMessage(paramResp), m.label == EnttecPro.Label.getWidgetParameters.rawValue,
                   let prm = EnttecPro.parseParameters(m.data) {
                    let fw = "\(prm.firmwareVersion >> 8).\(prm.firmwareVersion & 0xFF)"
                    let brk = Double(prm.breakTime) * 10.67
                    let mab = Double(prm.mabTime) * 10.67
                    parts.append("FW \(fw)")
                    parts.append(String(format: "break %.0fµs, MAB %.0fµs, refresh %d Hz", brk, mab, prm.refreshRate))
                }
                info = parts.isEmpty ? "No reply from widget (still streaming blindly)" : parts.joined(separator: " · ")
            } catch {
                err = error.localizedDescription
                p.close()
            }
            DispatchQueue.main.async {
                if let err {
                    self?.statusMessage = "Error: \(err)"
                    self?.isConnected = false
                    return
                }
                self?.setPort(p)
                self?.ioQueue.async { self?.lastSnapshot = nil; self?.sendTimes = [] }
                self?.isConnected = true
                self?.widgetInfo = info
                self?.statusMessage = "Connected to \(path)"
                self?.startTimer()
            }
        }
    }

    func disconnect() {
        stopTimer()
        let p = currentPort()
        setPort(nil)
        ioQueue.async { p?.close() }
        isConnected = false
        widgetInfo = ""
        statusMessage = "Disconnected"
    }

    // MARK: Channel access (1-based, DMX-style)

    func value(of channel: Int) -> UInt8 {
        guard (1...512).contains(channel) else { return 0 }
        return channels[channel - 1]
    }

    func set(channel: Int, value: UInt8) {
        guard (1...512).contains(channel), channels[channel - 1] != value else { return }
        channels[channel - 1] = value
        lock.lock(); frame[channel - 1] = value; lock.unlock()
    }

    func set(startingAt channel: Int, values: [UInt8]) {
        for (i, v) in values.enumerated() { set(channel: channel + i, value: v) }
    }

    func blackout() { setAll(0) }
    func fullOn() { setAll(255) }

    func setAll(_ v: UInt8) {
        channels = Array(repeating: v, count: 512)
        lock.lock(); frame = channels; lock.unlock()
    }

    // MARK: Streaming

    private func startTimer() {
        stopTimer()
        frameRateHint = frameRate
        let interval = 1.0 / max(1, frameRate)
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func restartTimerIfNeeded() {
        if isConnected { startTimer() }
    }

    /// Runs on ioQueue.
    nonisolated private func tick() {
        lock.lock()
        let snapshot = frame
        lock.unlock()
        let packet = EnttecPro.dmxPacket(universe: snapshot)
        guard let p = currentPort() else { return }
        let now = Date()
        do {
            try p.write(packet)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.debug.writeErrors += 1
                self?.statusMessage = "Write error: \(error.localizedDescription)"
                self?.disconnect()
            }
            return
        }

        // Bookkeeping (ioQueue-only state).
        sentCounter += 1
        bytesCounter += packet.count
        lastPacketSent = packet
        lastSendTime = now
        sendTimes.append(now.timeIntervalSinceReferenceDate)
        let cutoff = now.timeIntervalSinceReferenceDate - 1.0
        while let f = sendTimes.first, f < cutoff { sendTimes.removeFirst() }

        if let prev = lastSnapshot {
            if prev != snapshot {
                pendingLog.append(Self.describeChange(from: prev, to: snapshot, at: now))
            }
        } else {
            pendingLog.append(Self.stamp(now) + "  first frame → " + Self.describeActive(snapshot))
        }
        lastSnapshot = snapshot

        // Push to the UI at ~5 Hz (or immediately when something changed).
        if !pendingLog.isEmpty || sentCounter % max(1, Int(frameRateHint / 5)) == 0 {
            let dbg = OutputDebug(lastPacket: packet, lastSentAt: now, measuredFPS: Double(sendTimes.count),
                                  bytesSent: bytesCounter, writeErrors: 0)
            let n = sentCounter
            let log = pendingLog; pendingLog.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let errs = self.debug.writeErrors
                var d = dbg; d.writeErrors = errs
                self.debug = d
                self.framesSent = n
                if !log.isEmpty {
                    self.changeLog.append(contentsOf: log)
                    if self.changeLog.count > Self.changeLogLimit {
                        self.changeLog.removeFirst(self.changeLog.count - Self.changeLogLimit)
                    }
                }
            }
        }
    }

    /// Cached copy of `frameRate` readable from ioQueue.
    nonisolated(unsafe) private var frameRateHint: Double = 30

    nonisolated private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    nonisolated private static func stamp(_ d: Date) -> String { timeFmt.string(from: d) }

    nonisolated static func describeActive(_ u: [UInt8]) -> String {
        let active = u.enumerated().filter { $0.element != 0 }
        if active.isEmpty { return "all 512 channels = 0" }
        return active.map { "ch\($0.offset + 1)=\($0.element)" }.joined(separator: " ")
    }

    nonisolated static func describeChange(from a: [UInt8], to b: [UInt8], at d: Date) -> String {
        var diffs: [String] = []
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            diffs.append("ch\(i + 1) \(a[i])→\(b[i])")
            if diffs.count >= 12 { diffs.append("…"); break }
        }
        return stamp(d) + "  " + diffs.joined(separator: ", ")
    }

    func clearChangeLog() { changeLog.removeAll() }

    nonisolated private func currentPort() -> SerialPort? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    nonisolated private func setPort(_ p: SerialPort?) {
        lock.lock(); port = p; lock.unlock()
    }
}
