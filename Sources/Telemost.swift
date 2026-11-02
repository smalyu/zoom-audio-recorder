import AppKit
import CoreAudio
import CoreGraphics
import CoreMedia
import Darwin
import Foundation

/// The meeting app a recording follows: Zoom, Yandex Telemost's own app, or Telemost in a browser.
enum MeetingApp: Equatable, CustomStringConvertible {
    case zoom
    case telemost
    /// Telemost in a browser, by the browser's bundle identifier.
    case browser(String)

    var description: String {
        switch self {
        case .zoom: return "Zoom"
        case .telemost: return "Telemost"
        case let .browser(id): return "Telemost in \(id)"
        }
    }

    /// "Zoom", "Телемост": also the start of a recording's file name.
    var name: String { self == .zoom ? "Zoom" : "Телемост" }
    /// "Звук Zoom", "Звук Телемоста".
    var genitive: String { self == .zoom ? "Zoom" : "Телемоста" }
    /// "в Zoom", "в Телемосте".
    var locative: String { self == .zoom ? "в Zoom" : "в Телемосте" }
    /// "к Zoom", "к Телемосту".
    var dative: String { self == .zoom ? "к Zoom" : "к Телемосту" }
    /// "с Zoom", "с Телемостом".
    var instrumental: String { self == .zoom ? "с Zoom" : "с Телемостом" }

    var isBrowser: Bool { if case .browser = self { return true } else { return false } }
}

/// A running app to record.
struct MeetingTarget {
    let app: MeetingApp
    let process: NSRunningApplication
    var pid: pid_t { process.processIdentifier }
}

/// Finds the meeting to record.
enum Meetings {
    static let telemostBundle = "ru.yandex.desktop.telemost"
    /// Browsers Telemost is looked for in.
    static let browsers: Set<String> = [
        "ru.yandex.desktop.yandex-browser", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.operasoftware.Opera", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium", "org.mozilla.firefox",
    ]

    static func telemost() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: telemostBundle).first { !$0.isTerminated }
    }

    /// Telemost's page is called "Яндекс Телемост", or "Yandex Telemost" in English.
    static func isTelemostTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("телемост") || lower.contains("telemost")
    }

    /// Browsers with Telemost's page in front of one of their windows, on any desktop, the
    /// frontmost window first. A browser's window is named after the tab it shows.
    static func telemostBrowsers() -> [NSRunningApplication] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: [pid_t] = []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let title = info[kCGWindowName as String] as? String, isTelemostTitle(title),
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), !pids.contains(pid) else { continue }
            pids.append(pid)
        }
        return pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !$0.isTerminated && browsers.contains($0.bundleIdentifier ?? "") }
    }

    /// A Telemost meeting going on: Telemost's app in a meeting by its log, or a browser showing
    /// Telemost while it takes the microphone.
    static func inCall() -> MeetingTarget? {
        let app = telemost()
        let browsers = telemostBrowsers()
        guard app != nil || !browsers.isEmpty else { return nil }
        let inputs = AudioInputs.processes()
        // The app takes the microphone only in a meeting: that holds even if its log changes.
        if let app, TelemostLog.shared.state(of: app).inCall || AudioInputs.capturing(inputs, by: app) {
            return MeetingTarget(app: .telemost, process: app)
        }
        return browsers.first { AudioInputs.capturing(inputs, by: $0) }.map { MeetingTarget(app: .browser($0.bundleIdentifier ?? ""), process: $0) }
    }

    /// What to record when a recording starts: a Telemost meeting going on, as Zoom often stays
    /// open between its own meetings; then Zoom; then Telemost before its meeting begins.
    static func choose() -> MeetingTarget? {
        if let call = inCall() { return call }
        if let zoom = ZoomAudio.runningZoom() { return MeetingTarget(app: .zoom, process: zoom) }
        if let app = telemost() { return MeetingTarget(app: .telemost, process: app) }
        return telemostBrowsers().first.map { MeetingTarget(app: .browser($0.bundleIdentifier ?? ""), process: $0) }
    }

    /// Whether there is something to record; cheap enough to ask every second.
    static var available: Bool { ZoomAudio.runningZoom() != nil || telemost() != nil || !telemostBrowsers().isEmpty }
}

/// The microphone state of a meeting app, read as it changes; the recording keeps the user's
/// voice by it.
protocol MicrophoneWatcher: AnyObject {
    /// Whether the app's microphone control has been found, and whether it is missing now.
    var control: (seen: Bool, missing: Bool) { get }
    /// Whether the app is in a meeting now.
    var inMeeting: Bool { get }
    /// Readings from just before `time` on, for deciding captured microphone audio.
    func timeline(from time: Double) -> MuteTimeline
    func start()
    /// One last reading after any poll still in flight.
    func finalReading()
    /// Returns after any poll in flight, so nothing is reported after it.
    func stop()
}

/// Which processes take audio from an input device now, from Core Audio's list of its clients.
enum AudioInputs {
    static func processes() -> [(pid: pid_t, bundle: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard read(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
                  let pid = read(object, kAudioProcessPropertyPID, pid_t(0)) else { return nil }
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
            return (pid, status == noErr ? name?.takeRetainedValue() as String? ?? "" : "")
        }
    }

    /// Whether `app` or a helper of its own takes the microphone: browsers capture in a helper.
    static func capturing(_ inputs: [(pid: pid_t, bundle: String)], by app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? "\u{0}"
        return inputs.contains { input in
            input.pid == app.processIdentifier || input.bundle.hasPrefix(id + ".") || parent(of: input.pid) == app.processIdentifier
                || (id == "com.apple.Safari" && input.bundle.hasPrefix("com.apple.WebKit."))
        }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }

    private static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: Value) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }
}

/// Telemost's app notes in its own log when it joins and leaves a meeting and when its microphone
/// goes on and off, to the millisecond, as it happens:
///
///     61027-143124.629 [-][I] AudioControllerInternal Setting muted = true
///
/// The first figure is the year's last digit, the month and the day, then the time of day.
enum TelemostLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Yandex.Telemost/log/telemost_core.log")

    enum Event: Equatable {
        /// The app started, and a new run of the log begins.
        case started
        case joined
        case ended
        case muted(Bool)
    }

    static func event(in line: Substring) -> Event? {
        if line.contains("Setting muted = "), line.contains("AudioController") {
            if line.contains("Setting muted = true") { return .muted(true) }
            if line.contains("Setting muted = false") { return .muted(false) }
        }
        if line.contains("Core onSendAudio true") { return .muted(false) }
        if line.contains("Core onSendAudio false") { return .muted(true) }
        // Telemost 2 notes "Conference joined"; Telemost 3 only starts its media session here.
        if line.contains("Conference joined") || line.contains("Starting Goloom session") { return .joined }
        if line.contains("Core End call") { return .ended }
        if line.contains("WebRTC log severity") { return .started }
        return nil
    }

    /// The local time a line begins with; the year is the latest one with that last digit.
    static func time(of line: Substring, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let bytes = Array(line.utf8.prefix(16))
        guard bytes.count == 16, bytes[5] == UInt8(ascii: "-"), bytes[12] == UInt8(ascii: ".") else { return nil }
        var digits: [Int] = []
        for (index, byte) in bytes.enumerated() where index != 5 && index != 12 {
            guard (48...57).contains(byte) else { return nil }
            digits.append(Int(byte) - 48)
        }
        let number = { (from: Int, count: Int) in digits[from..<from + count].reduce(0) { $0 * 10 + $1 } }
        let current = calendar.component(.year, from: now)
        var components = DateComponents()
        components.year = current - ((current - digits[0]) % 10 + 10) % 10
        components.month = number(1, 2)
        components.day = number(3, 2)
        components.hour = number(5, 2)
        components.minute = number(7, 2)
        components.second = number(9, 2)
        components.nanosecond = number(11, 3) * 1_000_000
        guard var date = calendar.date(from: components) else { return nil }
        if date > now.addingTimeInterval(2 * 86_400), let earlier = calendar.date(byAdding: .year, value: -10, to: date) { date = earlier }
        return date
    }

    /// What one run of the app says so far.
    struct State: Equatable {
        var inCall = false
        var muted: Bool?

        mutating func apply(_ event: Event) {
            switch event {
            case .started: self = State()
            case .joined: inCall = true
            case .ended: inCall = false
            case let .muted(value): muted = value
            }
        }

        /// The user's microphone: off outside a meeting, unknown until the app says.
        var microphone: ZoomMuteState {
            guard inCall, let muted else { return .unavailable }
            return muted ? .muted : .unmuted
        }
    }

    /// For telling at a glance whether the app is in a meeting.
    static let shared = Tracker()

    /// Reads the log as it grows: lines of the running app only, from its launch on.
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private var reader: Reader?
        private var pid: pid_t?
        private var state = State()

        init(url: URL = TelemostLog.url) {
            self.url = url
        }

        /// The state of `app`'s meeting now.
        func state(of app: NSRunningApplication) -> State {
            changes(of: app)
            return lock.withLock { state }
        }

        /// The changes of the microphone since the last call, with their times; the first call
        /// reads the end of the log, and gives the state of the meeting going on.
        @discardableResult
        func changes(of app: NSRunningApplication) -> [(time: Date, microphone: ZoomMuteState, inCall: Bool)] {
            lock.withLock {
                if pid != app.processIdentifier || reader == nil {
                    pid = app.processIdentifier
                    // Lines from before the app started are another run's.
                    reader = Reader(url: url, since: app.launchDate?.addingTimeInterval(-2))
                    state = State()
                }
                var result: [(time: Date, microphone: ZoomMuteState, inCall: Bool)] = []
                for (time, event) in reader?.read() ?? [] {
                    let before = state
                    state.apply(event)
                    if state.microphone != before.microphone || state.inCall != before.inCall {
                        result.append((time, state.microphone, state.inCall))
                    }
                }
                return result
            }
        }
    }

    /// The lines added to the log since the last read, as events.
    final class Reader {
        /// A long log is read from near its end: a run's start is among its last lines.
        static let tail: UInt64 = 4_000_000
        private let url: URL
        private let since: Date?
        private var offset: UInt64?
        private var file: UInt64?
        private var partial = Data()

        init(url: URL, since: Date?) {
            self.url = url
            self.since = since
        }

        func read() -> [(time: Date, event: Event)] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return [] }
            let size = UInt64(info.st_size)
            // A new file in its place, or one cut short, is read from its start.
            if file != UInt64(info.st_ino) || size < (offset ?? 0) {
                let first = file == nil
                file = UInt64(info.st_ino)
                offset = first && size > Self.tail ? size - Self.tail : 0
                partial = Data()
                if first, size > Self.tail { partial = Data([0]) }
            }
            guard let start = offset, size > start else { return [] }
            try? handle.seek(toOffset: start)
            let data = (try? handle.read(upToCount: Int(min(size - start, 8_000_000)))) ?? Data()
            offset = start + UInt64(data.count)
            var text = partial + data
            // Read from the middle of a line: that line is not whole.
            if text.first == 0 {
                guard let newline = text.firstIndex(of: 0x0A) else {
                    partial = text
                    return []
                }
                text = text[text.index(after: newline)...]
            }
            guard let last = text.lastIndex(of: 0x0A) else {
                partial = text
                return []
            }
            partial = Data(text[text.index(after: last)...])
            var events: [(time: Date, event: Event)] = []
            var latest: Date?
            for line in String(decoding: text[..<last], as: UTF8.self).split(separator: "\n") {
                // Lines of several lines carry the time of their first one.
                if let time = TelemostLog.time(of: line) { latest = time }
                guard let event = TelemostLog.event(in: line), let time = latest else { continue }
                if let since, time < since { continue }
                events.append((time, event))
            }
            return events
        }
    }
}

/// Follows the microphone of Telemost's own app by its log: nothing is asked of the app, and every
/// change counts from the moment the log gives it.
final class TelemostMuteWatcher: MicrophoneWatcher {
    /// Readings stand for this long ago, so that a line written a little late still counts at its own time.
    /// Telemost 3.2 writes each line within 11 ms of its time.
    static let lag = 0.25
    /// Voice kept before the microphone goes on: the log gives the press itself, not a sign of it shown later.
    static let lead = 0.1
    private let app: NSRunningApplication
    private let tracker: TelemostLog.Tracker
    private let queue = DispatchQueue(label: "zoom-audio.telemost")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var history: [MuteTimeline.Reading] = []
    /// Changes read but not yet due.
    private var pending: [(time: Double, state: ZoomMuteState)] = []
    private var current: ZoomMuteState = .unavailable
    private var lastTime = -Double.infinity
    private var latest: ZoomMuteState?
    private var meeting = false
    /// The app takes the microphone, as it does only in a meeting; asked once a second.
    private var capturing = false
    private var lastCaptureCheck = -Double.infinity
    private var gone = false
    private var controlSeen = false
    private let onChange: (ZoomMuteState) -> Void

    init(app: NSRunningApplication, tracker: TelemostLog.Tracker = TelemostLog.Tracker(), onChange: @escaping (ZoomMuteState) -> Void) {
        self.app = app
        self.tracker = tracker
        self.onChange = onChange
    }

    var control: (seen: Bool, missing: Bool) { lock.withLock { (controlSeen, current == .unavailable) } }
    var inMeeting: Bool { lock.withLock { meeting || capturing } }

    func timeline(from time: Double) -> MuteTimeline {
        lock.withLock {
            let first = history.lastIndex { $0.time < time } ?? history.startIndex
            return MuteTimeline(readings: Array(history[first...]), lead: Self.lead)
        }
    }

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.refresh(lag: Self.lag) }
        self.timer = timer
        timer.resume()
    }

    func finalReading() {
        timer?.cancel()
        queue.sync { refresh(lag: 0) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    private func refresh(lag: Double) {
        let now = Self.now()
        let wall = Date()
        if now - lastCaptureCheck >= 1 {
            lastCaptureCheck = now
            let taking = AudioInputs.capturing(AudioInputs.processes(), by: app)
            lock.withLock { capturing = taking }
        }
        let changes = tracker.changes(of: app)
        for change in changes {
            pending.append((now - wall.timeIntervalSince(change.time), change.microphone))
        }
        // Lines read together, as the meeting's beginning when the recording starts, show as one change.
        if let last = changes.last {
            lock.withLock { meeting = last.inCall }
            note(last.microphone)
        }
        // A Telemost that quit says nothing more: its microphone is off from now.
        if !gone, kill(app.processIdentifier, 0) != 0, errno == ESRCH {
            gone = true
            pending.append((now, .unavailable))
            lock.withLock { meeting = false }
            note(.unavailable)
        }
        let due = now - lag
        while let first = pending.first, first.time <= due {
            pending.removeFirst()
            record(first.state, at: max(first.time, lastTime))
        }
        record(current, at: max(due, lastTime))
    }

    /// The window shows a change as soon as it is read.
    private func note(_ state: ZoomMuteState) {
        guard state != latest else { return }
        latest = state
        onChange(state)
    }

    private func record(_ state: ZoomMuteState, at time: Double) {
        lock.withLock {
            history.append((time, state == .unmuted, state == .unavailable))
            if history.count > 6_000 { history.removeFirst(3_000) }
            lastTime = time
            current = state
            controlSeen = controlSeen || state != .unavailable
        }
        if latest == nil { note(state) }
    }
}

/// Follows Telemost in a browser. The page cannot be read: Chrome shows its pages to no one but
/// VoiceOver, and macOS hides windows on other desktops from Accessibility. So the user's voice
/// counts whenever the browser takes the microphone, as it does through the whole meeting, the
/// Telemost microphone muted or not.
final class BrowserMuteWatcher: MicrophoneWatcher {
    private let app: NSRunningApplication
    private let queue = DispatchQueue(label: "zoom-audio.browser")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var history: [MuteTimeline.Reading] = []
    private var lastReported: ZoomMuteState?
    private var controlSeen = false
    private let onChange: (ZoomMuteState) -> Void

    init(app: NSRunningApplication, onChange: @escaping (ZoomMuteState) -> Void) {
        self.app = app
        self.onChange = onChange
    }

    var control: (seen: Bool, missing: Bool) { lock.withLock { (controlSeen, lastReported == .unavailable) } }
    var inMeeting: Bool { lock.withLock { lastReported == .unmuted } }

    func timeline(from time: Double) -> MuteTimeline {
        lock.withLock {
            let first = history.lastIndex { $0.time < time } ?? history.startIndex
            return MuteTimeline(readings: Array(history[first...]))
        }
    }

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func finalReading() {
        timer?.cancel()
        queue.sync { refresh() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    private func refresh() {
        let begun = Self.now()
        let next: ZoomMuteState = AudioInputs.capturing(AudioInputs.processes(), by: app) ? .unmuted : .unavailable
        lock.lock()
        history.append((next == .unmuted ? begun : Self.now(), next == .unmuted, next == .unavailable))
        if history.count > 6_000 { history.removeFirst(3_000) }
        let changed = next != lastReported
        lastReported = next
        controlSeen = controlSeen || next != .unavailable
        lock.unlock()
        if changed { onChange(next) }
    }
}

/// For checking what the recorder sees of Telemost, run from the app with --diagnose-telemost.
func telemostDiagnostics() -> [String: Any] {
    var result: [String: Any] = ["logExists": FileManager.default.fileExists(atPath: TelemostLog.url.path)]
    if let app = Meetings.telemost() {
        let state = TelemostLog.Tracker().state(of: app)
        result["app"] = ["pid": app.processIdentifier, "launched": app.launchDate.map { "\($0)" } ?? "unknown",
                         "version": app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown",
                         "inCall": state.inCall, "muted": state.muted.map { "\($0)" } ?? "unknown",
                         "microphone": String(describing: state.microphone)]
    } else {
        result["app"] = "not running"
    }
    let inputs = AudioInputs.processes()
    result["inputs"] = inputs.map { "\($0.pid) \($0.bundle) parent \(AudioInputs.parent(of: $0.pid).map(String.init) ?? "?")" }
    result["browsers"] = Meetings.telemostBrowsers().map { "\($0.bundleIdentifier ?? "") pid \($0.processIdentifier), takes the microphone \(AudioInputs.capturing(inputs, by: $0))" }
    result["choice"] = Meetings.choose().map { "\($0.app) pid \($0.pid)" } ?? "none"
    result["inCall"] = Meetings.inCall().map { "\($0.app) pid \($0.pid)" } ?? "none"
    return result
}


/// The meeting apps one recording follows at once, each with its microphone watcher: Zoom and
/// Telemost may both be in the same call, one after the other or together. Read from the
/// capture's queue, changed by the recording's loop.
final class MeetingMembers: @unchecked Sendable {
    struct Member {
        let target: MeetingTarget
        let watcher: MicrophoneWatcher
        var speakers: ZoomSpeakerWatcher?
        /// Host time the app left the recording.
        var ended: Double?
        var state: ZoomMuteState = .unavailable
    }

    /// An app that left is kept this long, for microphone audio still held from before.
    static let keep = Capture.voiceHold + 5
    private let lock = NSLock()
    private var members: [Member] = []
    private var shown: ZoomMuteState?

    var active: [Member] { lock.withLock { members.filter { $0.ended == nil } } }

    /// Whether the window should be told `state`: it shows it from now on.
    func show(_ state: ZoomMuteState) -> Bool {
        lock.withLock {
            defer { shown = state }
            return shown != state
        }
    }

    func add(_ member: Member) {
        lock.withLock { members.append(member) }
    }

    /// Ends the apps not among `pids` at host time `time`: each makes a last reading, and its
    /// watchers stop. Returns those ended.
    @discardableResult
    func end(keeping pids: Set<pid_t> = [], at time: Double) -> [Member] {
        let leaving = active.filter { !pids.contains($0.target.pid) }
        for member in leaving {
            member.watcher.finalReading()
            member.watcher.stop()
            member.speakers?.stop()
        }
        lock.withLock {
            for index in members.indices where members[index].ended == nil && !pids.contains(members[index].target.pid) {
                members[index].ended = time
            }
        }
        return leaving
    }

    /// Forgets apps that left long enough ago, or all of them.
    func forget(before time: Double = .infinity) {
        lock.withLock { members.removeAll { ($0.ended ?? .infinity) < time } }
    }

    /// Voice is kept where any app has the microphone on.
    func timeline(from time: Double) -> MuteTimeline {
        let list = lock.withLock { members }
        var timelines = list.map { member -> MuteTimeline in
            var timeline = member.watcher.timeline(from: time)
            timeline.ended = member.ended
            return timeline
        }
        guard !timelines.isEmpty else { return MuteTimeline() }
        var first = timelines.removeFirst()
        first.alongside = timelines
        return first
    }

    /// A control seen in any app; missing while every app in the recording misses one.
    var control: (seen: Bool, missing: Bool) {
        let list = lock.withLock { members }
        let current = list.filter { $0.ended == nil }.map(\.watcher.control)
        return (list.contains { $0.watcher.control.seen }, current.allSatisfy(\.missing))
    }

    /// Notes one app's microphone; returns that of the recording: on if on in any app, else off if
    /// off in any, else not seen.
    func note(_ state: ZoomMuteState, of pid: pid_t) -> ZoomMuteState {
        lock.withLock {
            for index in members.indices where members[index].target.pid == pid && members[index].ended == nil {
                members[index].state = state
            }
            return Self.combined(members.filter { $0.ended == nil }.map(\.state))
        }
    }

    var microphone: ZoomMuteState { lock.withLock { Self.combined(members.filter { $0.ended == nil }.map(\.state)) } }

    static func combined(_ states: [ZoomMuteState]) -> ZoomMuteState {
        states.contains(.unmuted) ? .unmuted : states.contains(.muted) ? .muted : .unavailable
    }

    /// The app to show and to record the picture of: among those in a meeting, the one in front
    /// now, else the one shown before, else the first.
    static func primary(among meeting: [MeetingTarget], all: [MeetingTarget], front: pid_t?, previous: MeetingTarget?) -> MeetingTarget? {
        if let front, let shown = meeting.first(where: { $0.pid == front }) { return shown }
        if let previous, meeting.contains(where: { $0.pid == previous.pid }) { return previous }
        return meeting.first ?? all.first(where: { $0.pid == previous?.pid }) ?? all.first ?? previous
    }
}

/// The browsers in a recording: one showing Telemost's page joins, and stays while it keeps the
/// microphone, as with the page's tab switched away, and a little while after either.
final class BrowserMembership {
    static let grace: TimeInterval = 10
    private var seen: [pid_t: Date] = [:]

    func current(now: Date = Date()) -> [MeetingTarget] {
        for browser in Meetings.telemostBrowsers() { seen[browser.processIdentifier] = now }
        if !seen.isEmpty {
            let inputs = AudioInputs.processes()
            for pid in seen.keys {
                if let app = NSRunningApplication(processIdentifier: pid), AudioInputs.capturing(inputs, by: app) { seen[pid] = now }
            }
        }
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.grace && NSRunningApplication(processIdentifier: $0.key)?.isTerminated == false }
        return seen.keys.sorted().compactMap { pid in
            NSRunningApplication(processIdentifier: pid).map { MeetingTarget(app: .browser($0.bundleIdentifier ?? ""), process: $0) }
        }
    }
}
