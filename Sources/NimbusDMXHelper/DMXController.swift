// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import DMXCore
import Combine

/// Owns the 512-channel universe and streams it to an Enttec DMX USB Pro.
///
/// UI mutates `channels` on the main actor; a background timer on `ioQueue`
/// snapshots the frame under `lock` and writes it to the widget.
///
/// Two streaming modes:
///  * Normal: full 512-channel frames at `frameRate` fps (default 40 = the widget's
///    own DMX refresh rate; a full frame takes ~22.7 ms on the wire, so ~44 Hz is physics).
///  * High speed: widget refresh set to 0 ("as fast as possible"), frames shrunk to the
///    highest in-use channel (min 24), and paced at the DMX line time of that short frame
///    (~1.2 ms → ~750 fps for a 24-channel frame). Sending faster than the line can carry
///    only fills buffers and adds latency (measured: it can even wedge the widget), so we
///    never do that.
@MainActor
final class DMXController: ObservableObject {
    static let shared = DMXController()

    // MARK: Published UI state
    @Published private(set) var channels: [UInt8] = Array(repeating: 0, count: 512)
    @Published var selectedPort: String = ""
    @Published private(set) var availablePorts: [String] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var statusMessage = "Disconnected"
    @Published private(set) var widgetInfo: String = ""
    @Published private(set) var framesSent: Int = 0
    /// Normal-mode frame rate. Ignored in high-speed mode.
    @Published var frameRate: Double = 40 { didSet { lock.lock(); frameRateHint = frameRate; lock.unlock() } }
    /// High-speed mode: widget refresh 0 + shrunken frames + line-rate pacing.
    @Published var highSpeed = false { didSet { if oldValue != highSpeed { applyHighSpeed() } } }

    /// Snapshot of what was most recently written to the widget, for the debug panel.
    struct OutputDebug {
        var lastPacket: [UInt8] = []          // full Enttec message, header..E7
        var lastSentAt: Date? = nil
        var measuredFPS: Double = 0
        var bytesSent: Int = 0
        var writeErrors: Int = 0
        var frameChannels: Int = 512          // channels in the last packet
        var targetInterval: TimeInterval = 1.0 / 40
        var widgetRefresh: Int? = nil         // widget's refresh-rate parameter as we last set/read it
    }
    @Published private(set) var debug = OutputDebug()

    /// What the widget hears on its DMX IN port, refreshed at 10 Hz while `monitoring`.
    struct InputSnapshot {
        var slots = [UInt8](repeating: 0, count: 512)
        var lastChange = [Date](repeating: .distantPast, count: 512)
        var frames = 0                 // label 5 messages
        var deltas = 0                 // label 9 messages
        var fps: Double = 0
        var slotCount = 0              // widest frame seen; sources may send fewer than 512
        var startCode: UInt8? = nil
        var lastFrameAt: Date? = nil
        var overflows = 0              // widget receive FIFO overran (we were too slow)
        var overruns = 0               // trouble on the incoming line
        var otherMessages = 0
        var highestLit = 0
        var resyncs = 0

        /// Frames still arriving — DMX sources repeat themselves, so a gap means signal loss.
        var live: Bool { lastFrameAt.map { Date().timeIntervalSince($0) < 1.0 } ?? false }
    }
    @Published private(set) var input = InputSnapshot()

    /// Listen to DMX IN instead of transmitting. The Pro can only do one at a time.
    @Published var monitoring = false { didSet { if oldValue != monitoring { applyMonitoring() } } }
    /// Timestamped log of every frame whose content differed from the previous one.
    @Published private(set) var changeLog: [String] = []
    static let changeLogLimit = 200

    // MARK: Shared with ioQueue — every access goes through `lock`.
    private let lock = NSLock()
    nonisolated(unsafe) private var frame: [UInt8] = Array(repeating: 0, count: 512)
    nonisolated(unsafe) private var port: SerialPort?
    nonisolated(unsafe) private var frameRateHint: Double = 40
    nonisolated(unsafe) private var highSpeedFlag = false

    // MARK: ioQueue-only state (never touched from main)
    private let ioQueue = DispatchQueue(label: "dmx.enttec.io", qos: .userInteractive)
    nonisolated(unsafe) private var timer: DispatchSourceTimer?
    nonisolated(unsafe) private var timerInterval: TimeInterval = 0
    nonisolated(unsafe) private var sentCounter = 0
    nonisolated(unsafe) private var bytesCounter = 0
    nonisolated(unsafe) private var lastSnapshot: [UInt8]? = nil
    nonisolated(unsafe) private var sendTimes: [TimeInterval] = []
    nonisolated(unsafe) private var pendingLog: [String] = []
    nonisolated(unsafe) private var lastUIPush = Date.distantPast
    nonisolated(unsafe) private var hwmChannels = 0            // high-water mark of in-use channels
    nonisolated(unsafe) private var hwmExpiry = Date.distantPast
    nonisolated(unsafe) private var originalParams: EnttecPro.WidgetParameters? = nil
    nonisolated(unsafe) private var widgetRefreshNow: Int? = nil
    nonisolated(unsafe) private var readSource: DispatchSourceRead?
    nonisolated(unsafe) private var rxTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var rxStream = EnttecPro.MessageStream()
    nonisolated(unsafe) private var rx = InputSnapshot()
    nonisolated(unsafe) private var rxTimes: [TimeInterval] = []

    /// How long a channel that went back to 0 keeps the frame long enough to include it,
    /// so the fixture actually receives the zero before we shrink the frame.
    nonisolated static let shrinkHold: TimeInterval = 2.0
    /// Safety margin on top of the modelled DMX line time when pacing high-speed frames.
    nonisolated static let paceMargin = 1.1

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
        guard !isConnected, !isConnecting, !selectedPort.isEmpty else { return }
        let path = selectedPort
        isConnecting = true
        statusMessage = "Opening \(path)…"
        // If open() blocks (e.g. a previous instance is still closing the port in the
        // kernel — that takes ~1 s after a stream is killed), tell the user what's going on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isConnecting else { return }
            self.statusMessage = "Still opening \(path)… another process may still be closing it; wait a few seconds or unplug/replug the widget."
        }
        let wantHighSpeed = highSpeed
        ioQueue.async { [weak self] in
            let p = SerialPort(path: path)
            var info = ""
            var err: String?
            var params: EnttecPro.WidgetParameters?
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
                    params = prm
                    let fw = "\(prm.firmwareVersion >> 8).\(prm.firmwareVersion & 0xFF)"
                    parts.append("FW \(fw)")
                    parts.append(String(format: "break %.0fµs, MAB %.0fµs, refresh %d Hz",
                                        Double(prm.breakTime) * 10.67, Double(prm.mabTime) * 10.67, prm.refreshRate))
                }
                info = parts.isEmpty ? "No reply from widget (still streaming blindly)" : parts.joined(separator: " · ")
                if wantHighSpeed {
                    try p.write(EnttecPro.setParametersRequest(breakTime: 9, mabTime: 1, refreshRate: 0))
                }
            } catch {
                err = error.localizedDescription
                p.close()
            }
            guard let self else { return }
            // Reset ioQueue-only streaming state.
            self.lastSnapshot = nil
            self.sendTimes = []
            self.hwmChannels = 0
            self.hwmExpiry = .distantPast
            self.originalParams = params
            self.widgetRefreshNow = wantHighSpeed ? 0 : params.map { Int($0.refreshRate) }
            DispatchQueue.main.async {
                self.isConnecting = false
                if let err {
                    self.statusMessage = "Error: \(err)"
                    self.isConnected = false
                    return
                }
                self.setPort(p)
                self.isConnected = true
                self.widgetInfo = info
                self.statusMessage = "Connected to \(path)"
                if self.monitoring { self.applyMonitoring() } else { self.startStreaming() }
            }
        }
    }

    func disconnect() {
        guard isConnected || isConnecting else { return }
        let p = currentPort()
        setPort(nil)
        let restore = originalParamsForRestore()
        ioQueue.async { [weak self] in
            self?.stopTimerOnIO()
            self?.stopReceivingOnIO()
            Self.restoreAndClose(p, restore: restore)
        }
        isConnected = false
        widgetInfo = ""
        statusMessage = "Disconnected"
        debug.widgetRefresh = nil
    }

    /// Synchronous shutdown for app termination: stops streaming, restores widget
    /// parameters if we changed them, flushes and closes the port — and only returns once
    /// the kernel has actually closed the port, so the next launch can open it immediately.
    func shutdownSync() {
        let p = currentPort()
        setPort(nil)
        let restore = originalParamsForRestore()
        let t0 = Date()
        ioQueue.sync { [self] in
            stopTimerOnIO()
            stopReceivingOnIO()
            Self.restoreAndClose(p, restore: restore)
        }
        isConnected = false
        if p != nil {
            FileHandle.standardError.write("NimbusDMXHelper: port closed in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)
        }
    }

    /// Runs on ioQueue.
    nonisolated private static func restoreAndClose(_ p: SerialPort?, restore: EnttecPro.WidgetParameters?) {
        guard let p else { return }
        if let r = restore {
            try? p.write(EnttecPro.setParametersRequest(breakTime: r.breakTime, mabTime: r.mabTime, refreshRate: r.refreshRate))
            usleep(20_000)
        }
        p.close()
    }

    /// If high-speed mode changed the widget's parameters, what to put back.
    private func originalParamsForRestore() -> EnttecPro.WidgetParameters? {
        guard highSpeed else { return nil }
        return originalParams ?? EnttecPro.WidgetParameters.defaults
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

    // MARK: High-speed mode

    private func applyHighSpeed() {
        let on = highSpeed
        lock.lock(); highSpeedFlag = on; lock.unlock()
        guard isConnected, let p = currentPort() else { return }
        let restore = originalParams ?? EnttecPro.WidgetParameters.defaults
        ioQueue.async { [weak self] in
            guard let self else { return }
            let msg = on
                ? EnttecPro.setParametersRequest(breakTime: 9, mabTime: 1, refreshRate: 0)
                : EnttecPro.setParametersRequest(breakTime: restore.breakTime, mabTime: restore.mabTime, refreshRate: restore.refreshRate)
            try? p.write(msg)
            self.widgetRefreshNow = on ? 0 : Int(restore.refreshRate)
            self.hwmChannels = 0
            self.hwmExpiry = .distantPast
            self.pendingLog.append(Self.stamp(Date()) + (on
                ? "  high speed ON → widget refresh 0 (as fast as possible), frames shrink to used channels"
                : "  high speed OFF → widget refresh \(restore.refreshRate) Hz, full 512-channel frames"))
            self.reschedule(interval: self.desiredInterval(channels: on ? EnttecPro.minChannels : 512))
        }
    }

    // MARK: Monitoring DMX IN

    /// The widget can transmit or listen, never both: label 8 puts it into receive mode and it
    /// stays there until the next frame we send. So turning monitoring on stops the send timer,
    /// and turning it off restarts it — the first tick is what flips the widget back.
    private func applyMonitoring() {
        let on = monitoring
        guard isConnected, let p = currentPort() else { return }
        if on {
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.stopTimerOnIO()
                self.rx = InputSnapshot()
                self.rxStream = EnttecPro.MessageStream()
                self.rxTimes = []
                try? p.write(EnttecPro.receiveDMXRequest(.always))
                self.pendingLog.append(Self.stamp(Date()) + "  monitor ON → widget listening on DMX IN, output stopped")
                self.startReceivingOnIO(p)
            }
            statusMessage = "Listening on DMX IN (not transmitting)"
        } else {
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.stopReceivingOnIO()
                self.pendingLog.append(Self.stamp(Date()) + "  monitor OFF → transmitting again")
            }
            statusMessage = "Connected to \(selectedPort)"
            startStreaming()
        }
    }

    /// Runs on ioQueue. A read source fires only when bytes are actually there; a separate
    /// 10 Hz timer pushes to the UI whether or not anything arrived, so signal loss shows up.
    nonisolated private func startReceivingOnIO(_ p: SerialPort) {
        let src = DispatchSource.makeReadSource(fileDescriptor: p.fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.readInput(p) }
        readSource = src
        src.resume()

        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.setEventHandler { [weak self] in self?.pushInput() }
        t.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(20))
        rxTimer = t
        t.resume()
    }

    /// Runs on ioQueue. Must happen before the port closes — the read source holds its fd.
    nonisolated private func stopReceivingOnIO() {
        readSource?.cancel(); readSource = nil
        rxTimer?.cancel(); rxTimer = nil
    }

    /// Runs on ioQueue.
    nonisolated private func readInput(_ p: SerialPort) {
        let bytes = p.readAvailable()
        guard !bytes.isEmpty else { return }
        rxStream.append(bytes)
        let now = Date()
        while let msg = rxStream.next() {
            switch msg.label {
            case EnttecPro.Label.receivedDMXPacket.rawValue:
                guard let frame = EnttecPro.parseReceivedDMX(msg.data) else { break }
                rx.frames += 1
                rx.startCode = frame.startCode
                rx.slotCount = max(rx.slotCount, frame.slots.count)
                if frame.overflow { rx.overflows += 1 }
                if frame.overrun { rx.overruns += 1 }
                for (i, v) in frame.slots.enumerated() where i < 512 {
                    if rx.slots[i] != v { rx.slots[i] = v; rx.lastChange[i] = now }
                    if v != 0 { rx.highestLit = max(rx.highestLit, i + 1) }
                }
                rx.lastFrameAt = now
                rxTimes.append(now.timeIntervalSinceReferenceDate)
            case EnttecPro.Label.receivedDMXChangeOfState.rawValue:
                for slot in EnttecPro.applyChangeOfState(msg.data, to: &rx.slots) {
                    rx.lastChange[slot - 1] = now
                    if rx.slots[slot - 1] != 0 { rx.highestLit = max(rx.highestLit, slot) }
                }
                rx.deltas += 1
                rx.lastFrameAt = now
                rxTimes.append(now.timeIntervalSinceReferenceDate)
            default:
                rx.otherMessages += 1
            }
        }
    }

    /// Runs on ioQueue at 10 Hz while monitoring.
    nonisolated private func pushInput() {
        let cutoff = Date().timeIntervalSinceReferenceDate - 1.0
        while let f = rxTimes.first, f < cutoff { rxTimes.removeFirst() }
        var snapshot = rx
        snapshot.fps = Double(rxTimes.count)
        snapshot.resyncs = rxStream.resyncs
        let log = pendingLog; pendingLog.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.input = snapshot
            guard !log.isEmpty else { return }
            self.changeLog.append(contentsOf: log)
            if self.changeLog.count > Self.changeLogLimit {
                self.changeLog.removeFirst(self.changeLog.count - Self.changeLogLimit)
            }
        }
    }

    // MARK: Streaming

    private func startStreaming() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.stopTimerOnIO()
            let t = DispatchSource.makeTimerSource(queue: self.ioQueue)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            self.timerInterval = 0
            self.reschedule(interval: self.desiredInterval(channels: self.highSpeedFlag ? EnttecPro.minChannels : 512))
            t.resume()
        }
    }

    /// Runs on ioQueue.
    nonisolated private func stopTimerOnIO() {
        timer?.cancel()
        timer = nil
    }

    /// Runs on ioQueue. Re-arms the timer if the interval changed by more than a few %.
    nonisolated private func reschedule(interval: TimeInterval) {
        guard let t = timer else { return }
        if abs(interval - timerInterval) / max(interval, 1e-6) < 0.03 { return }
        timerInterval = interval
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(200))
    }

    /// Runs on ioQueue. Interval between frames for the given frame length.
    nonisolated private func desiredInterval(channels: Int) -> TimeInterval {
        lock.lock(); let hs = highSpeedFlag; let fps = frameRateHint; lock.unlock()
        if hs {
            // Pace at the DMX line time of the (short) frame, plus margin.
            return EnttecPro.dmxLineTime(channels: channels) * Self.paceMargin
        }
        return 1.0 / max(1, fps)
    }

    /// Runs on ioQueue.
    nonisolated private func tick() {
        lock.lock()
        let snapshot = frame
        let hs = highSpeedFlag
        lock.unlock()
        guard let p = currentPort() else { return }
        let now = Date()

        // Frame length: full universe normally; in high-speed mode, through the highest
        // in-use channel with a hold so fixtures still receive the zeros after a channel drops.
        var nch = 512
        if hs {
            let used = (snapshot.lastIndex(where: { $0 != 0 }) ?? -1) + 1
            if used >= hwmChannels {
                hwmChannels = used; hwmExpiry = now.addingTimeInterval(Self.shrinkHold)
            } else if now > hwmExpiry {
                hwmChannels = used; hwmExpiry = now.addingTimeInterval(Self.shrinkHold)
            }
            nch = max(EnttecPro.minChannels, hwmChannels)
        }
        let packet = EnttecPro.dmxPacket(universe: snapshot, channels: nch)
        let interval = desiredInterval(channels: nch)
        reschedule(interval: interval)

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

        // Bookkeeping.
        sentCounter += 1
        bytesCounter += packet.count
        sendTimes.append(now.timeIntervalSinceReferenceDate)
        let cutoff = now.timeIntervalSinceReferenceDate - 1.0
        while let f = sendTimes.first, f < cutoff { sendTimes.removeFirst() }

        if let prev = lastSnapshot {
            if prev != snapshot { pendingLog.append(Self.describeChange(from: prev, to: snapshot, at: now)) }
        } else {
            pendingLog.append(Self.stamp(now) + "  first frame → " + Self.describeActive(snapshot))
        }
        lastSnapshot = snapshot

        // Push to the UI at ~5 Hz, or immediately when something changed.
        if !pendingLog.isEmpty || now.timeIntervalSince(lastUIPush) > 0.2 {
            lastUIPush = now
            let dbg = OutputDebug(lastPacket: packet, lastSentAt: now, measuredFPS: Double(sendTimes.count),
                                  bytesSent: bytesCounter, writeErrors: 0, frameChannels: nch,
                                  targetInterval: interval, widgetRefresh: widgetRefreshNow)
            let n = sentCounter
            let log = pendingLog; pendingLog.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var d = dbg; d.writeErrors = self.debug.writeErrors
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

    // MARK: Helpers

    nonisolated private func currentPort() -> SerialPort? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    nonisolated private func setPort(_ p: SerialPort?) {
        lock.lock(); port = p; lock.unlock()
    }

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
}
