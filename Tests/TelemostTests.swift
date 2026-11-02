import AppKit
import CoreMedia
import Foundation

/// A line as Telemost's app writes it, at `date`.
private func telemostLine(_ text: String, at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMdd-HHmmss.SSS"
    let year = Calendar.current.component(.year, from: date) % 10
    return "\(year)\(formatter.string(from: date)) [-][I] \(text)\n"
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

func checkTelemostLog(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Lines of the log as Telemost 2.25 wrote them in a meeting.
    let samples: [(String, TelemostLog.Event?)] = [
        ("60127-135924.025 [-][W] AudioControllerInternal Setting muted = false: already in this state", .muted(false)),
        ("60127-135932.353 [-][I] AudioControllerInternal Setting muted = true", .muted(true)),
        ("60127-135932.353 [-][I] Core onSendAudio false", .muted(true)),
        ("60127-143115.440 [-][I] Core onSendAudio true", .muted(false)),
        ("60127-135924.428 [-][I] ConnectionController Conference joined: {uri=https://telemost.yandex.ru/j/1; roomId=2}", .joined),
        ("60127-135924.429 [-][I] Core Conference joined {uri=https://telemost.yandex.ru/j/1?sessionid=3}", .joined),
        ("60127-143128.937 [-][I] Core End call", .ended),
        ("61027-110938.686 [][I] WebRTC log severity: 2", .started),
        // Telemost 3.2 notes the meeting's start only so.
        ("61027-122613.437 [-][I] ConferenceSession Starting Goloom session: room_id=b5670ef1, service_name=telemost", .joined),
        ("60127-135921.520 [-][I] AudioControllerInternal Setting input device: name=Микрофон MacBook Pro", nil),
        ("60127-135924.025 [-][I] CameraControllerImpl Setting send video = true: already in this state", nil),
    ]
    for (line, expected) in samples {
        try check(TelemostLog.event(in: Substring(line)) == expected, "Telemost log line misread: \(line)")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    let time = TelemostLog.time(of: "61027-143124.629 [-][I] Core End call", now: now, calendar: calendar)
    let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 31, second: 24, nanosecond: 629_000_000))!
    try check(time.map { abs($0.timeIntervalSince(expected)) < 0.001 } == true, "Telemost log time misread")
    let lastYear = TelemostLog.time(of: "51222-131735.613 [-][W] x", now: now, calendar: calendar)
    try check(lastYear.map { calendar.component(.year, from: $0) } == 2025, "Telemost log year misread")
    try check(TelemostLog.time(of: "- AVAILABLE CAMERAS ------", now: now, calendar: calendar) == nil, "a line without a time was given one")

    // A long log from earlier runs, then the running app's own lines: the earlier ones never count.
    let url = folder.appendingPathComponent("telemost_core.log")
    let launch = Date().addingTimeInterval(-60)
    var old = ""
    for index in 0..<20 {
        let at = launch.addingTimeInterval(-3_600 + Double(index))
        old += telemostLine("Core Conference joined {uri=x}", at: at) + telemostLine("AudioControllerInternal Setting muted = false", at: at)
    }
    try append(old, to: url)
    let tracker = TelemostLog.Tracker(url: url)
    let app = NSRunningApplication.current
    // The tracker takes lines from 2 s before the app's launch: a test process has a launch date of its own.
    let since = app.launchDate ?? .distantPast
    try check(!tracker.state(of: app).inCall || since < launch.addingTimeInterval(-3_600), "an earlier run's meeting taken for the app's")
    try append(telemostLine("WebRTC log severity: 2", at: Date()), to: url)
    try check(tracker.state(of: app) == TelemostLog.State(), "a new run did not start the state over")
    try append(telemostLine("AudioControllerInternal Setting muted = false: already in this state", at: Date()), to: url)
    try check(tracker.state(of: app).microphone == .unavailable, "a microphone before the meeting counted")
    // A line written in two pieces is read once it is whole.
    let joined = telemostLine("Core Conference joined {uri=https://telemost.yandex.ru/j/1}", at: Date())
    try append(String(joined.prefix(20)), to: url)
    try check(!tracker.state(of: app).inCall, "half a line was read")
    try append(String(joined.dropFirst(20)), to: url)
    let state = tracker.state(of: app)
    try check(state.inCall && state.microphone == .unmuted, "joining with the microphone on was missed")
    try append(telemostLine("AudioControllerInternal Setting muted = true", at: Date()), to: url)
    let changes = tracker.changes(of: app)
    try check(changes.count == 1 && changes.first?.microphone == .muted && changes.first?.inCall == true, "muting was missed")
    try append(telemostLine("Core End call", at: Date()), to: url)
    try check(tracker.state(of: app).microphone == .unavailable && !tracker.state(of: app).inCall, "leaving was missed")
    // A new log in place of the old one is read from its start.
    try FileManager.default.removeItem(at: url)
    try append(telemostLine("Core Conference joined {uri=x}", at: Date()) + telemostLine("Core onSendAudio true", at: Date()), to: url)
    try check(tracker.state(of: app).microphone == .unmuted, "a new log file was not read")

    // Only the end of a long log is read at first, from a whole line on.
    let long = folder.appendingPathComponent("long.log")
    let filler = String(repeating: "60127-135924.025 [-][I] New VideoSinkWants: is_active: 0 rotation_applied: 0\n", count: 60_000)
    try append(filler + telemostLine("Core Conference joined {uri=x}", at: Date()) + telemostLine("Core onSendAudio false", at: Date()), to: long)
    let reader = TelemostLog.Reader(url: long, since: nil)
    let events = reader.read().map(\.event)
    try check(events == [.joined, .muted(true)], "the end of a long log misread: \(events)")
    print("PASS: Telemost's log is read as it grows, only the running app's lines, its meeting and microphone")
}

func checkTelemostWatcher(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("telemost_core.log")
    let app = NSRunningApplication.current
    let host = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    let joinedAt = Date()
    try append(telemostLine("WebRTC log severity: 2", at: joinedAt) + telemostLine("Core Conference joined {uri=x}", at: joinedAt)
               + telemostLine("AudioControllerInternal Setting muted = false: already in this state", at: joinedAt), to: url)
    let shown = Locked<[ZoomMuteState]>([])
    let watcher = TelemostMuteWatcher(app: app, tracker: TelemostLog.Tracker(url: url)) { state in shown.current.append(state) }
    watcher.start()
    // The window learns with the first poll; the readings stand for a moment ago. Core Audio's
    // first answer in a new process, asked in that poll, can take a while.
    let begun = Date()
    while shown.current.isEmpty, Date().timeIntervalSince(begun) < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
    try check(shown.current.last == .unmuted && watcher.inMeeting,
              "the meeting going on was not shown: \(shown.current) after \(Date().timeIntervalSince(begun)) s")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    // The microphone goes off now; the log says so a little late, with the moment it happened.
    let mutedAt = Date()
    let mutedHost = host()
    try await Task.sleep(nanoseconds: 150_000_000)
    try append(telemostLine("AudioControllerInternal Setting muted = true", at: mutedAt), to: url)
    try await Task.sleep(nanoseconds: 600_000_000)
    // On again: the voice counts from the press, not half a second before it as for Zoom.
    let unmutedAt = Date()
    let unmutedHost = host()
    try append(telemostLine("AudioControllerInternal Setting muted = false", at: unmutedAt), to: url)
    try await Task.sleep(nanoseconds: 600_000_000)
    watcher.finalReading()
    watcher.stop()
    let timeline = watcher.timeline(from: mutedHost - 1)
    let voice = timeline.voice(from: mutedHost - 1, to: unmutedHost + 0.3, final: true) ?? []
    try check(voice.count == 2 && abs((voice.first?.upperBound ?? 0) - mutedHost) < 0.06,
              "voice did not end where the log says the microphone went off: \(voice)")
    try check(abs((voice.last?.lowerBound ?? 0) - (unmutedHost - TelemostMuteWatcher.lead - MuteTimeline.pad)) < 0.03,
              "voice did not start where the log says the microphone went on: \(voice), on at \(unmutedHost)")
    try check(watcher.control.seen && watcher.control.missing == false, "the microphone control was not seen")
    try check(shown.current == [.unmuted, .muted, .unmuted], "the window was told \(shown.current)")
    let times = timeline.readings.map(\.time)
    try check(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }, "readings out of order")
    print("PASS: Telemost's microphone counts from the moment its log gives, even when the line comes late")
}

func checkTelemostPage() throws {
    try check(Meetings.isTelemostTitle("Яндекс Телемост") && Meetings.isTelemostTitle("(2) Yandex Telemost")
              && !Meetings.isTelemostTitle("Zoom Meeting"), "Telemost's page title misread")
    try check(RecordingSession.fileName(for: Date(timeIntervalSince1970: 0), app: .browser("com.google.Chrome")).hasPrefix("Телемост "),
              "a Telemost recording not named after it")
    try check(MeetingApp.telemost.locative == "в Телемосте" && MeetingApp.zoom.locative == "в Zoom", "app names wrong")

    let window = { (id: CGWindowID, title: String, width: CGFloat, onScreen: Bool) in
        ZoomWindow(id: id, title: title, layer: 0, frame: CGRect(x: 0, y: 0, width: width, height: width * 0.6), onScreen: onScreen)
    }
    let tabs = [window(1, "Почта", 1400, true), window(2, "Яндекс Телемост", 1200, false), window(3, "Яндекс Телемост", 400, true)]
    var choice = ScreenCapture.decideTelemost(windows: tabs, browser: true, inMeeting: true, recording: nil, remembered: nil, hidden: false)
    try check(choice.target == .window(3), "the browser window in sight with Telemost not chosen")
    choice = ScreenCapture.decideTelemost(windows: tabs, browser: true, inMeeting: true, recording: .window(2), remembered: 2, hidden: false)
    try check(choice.target == .window(2), "the window recorded was dropped for another")
    // Another tab in front of the window recorded: that tab is never recorded.
    let switched = [window(1, "Почта", 1400, true), window(2, "Почта — входящие", 1200, true)]
    choice = ScreenCapture.decideTelemost(windows: switched, browser: true, inMeeting: true, recording: .window(2), remembered: 2, hidden: false)
    try check(choice.target == nil && choice.pause == .noMeeting, "another tab in the meeting's window was recorded")
    let own = [window(7, "", 200, true), window(8, "Яндекс Телемост", 1280, false)]
    choice = ScreenCapture.decideTelemost(windows: own, browser: false, inMeeting: true, recording: nil, remembered: nil, hidden: false)
    try check(choice.target == .window(8), "Telemost's own window on another desktop not recorded")
    choice = ScreenCapture.decideTelemost(windows: own, browser: false, inMeeting: false, recording: .window(8), remembered: 8, hidden: false)
    try check(choice.target == nil && choice.pause == .noMeeting, "Telemost recorded outside a meeting")
    choice = ScreenCapture.decideTelemost(windows: own, browser: false, inMeeting: true, recording: nil, remembered: nil, hidden: true)
    try check(choice.pause == .hidden, "a hidden Telemost not told")
    print("PASS: Telemost's page and windows are found, a recording is named after Telemost")
}

func checkSessionRename(_ root: URL) throws {
    let destination = root.appendingPathComponent("out")
    let started = Date(timeIntervalSince1970: 1_790_000_000)
    let session = try RecordingSession.create(destination: destination, name: RecordingSession.fileName(for: started),
                                              started: started, root: root)
    session.name(after: .telemost)
    try check(session.manifest.name == RecordingSession.fileName(for: started, app: .telemost), "the recording was not renamed")
    let saved = try JSONDecoder().decode(RecordingSession.Manifest.self, from: Data(contentsOf: session.folder.appendingPathComponent("session.json")))
    try check(saved.name.hasPrefix("Телемост "), "the new name was not kept for recovery")
    session.remove()
    print("PASS: a recording that moved to Telemost is named after it, also after a crash")
}

func checkMeetingsTogether() throws {
    // Zoom's microphone off throughout; Telemost's on from 2 to 4 s.
    let zoom = MuteTimeline(readings: stride(from: 0.0, through: 6, by: 0.5).map { ($0, false, false) })
    var telemost = MuteTimeline(readings: stride(from: 0.0, through: 6, by: 0.5).map { ($0, $0 >= 2 && $0 < 4, false) }, lead: 0.1)
    var both = zoom
    both.alongside = [telemost]
    let voice = both.voice(from: 0, to: 5) ?? []
    try check(voice.count == 1 && abs(voice[0].lowerBound - 1.87) < 0.01 && abs(voice[0].upperBound - 4.03) < 0.01,
              "voice on in one app of two was not kept: \(voice)")
    // One app's readings not in yet: nothing is decided.
    var lagging = zoom
    lagging.alongside = [MuteTimeline(readings: [(0, true, false), (3, true, false)])]
    try check(lagging.voice(from: 0, to: 5) == nil, "voice decided before every app's readings were in")
    // An app that left: its microphone is off from then, without waiting for readings that never come.
    telemost.ended = 3
    both.alongside = [telemost]
    let left = both.voice(from: 0, to: 5) ?? []
    try check(left.count == 1 && abs(left[0].upperBound - 3.03) < 0.01, "an app that left kept the microphone on: \(left)")
    // A control is missing only where every app misses one.
    let missing = MuteTimeline(readings: [(0, false, true), (6, false, true)])
    var mixed = missing
    mixed.alongside = [zoom]
    try check(!mixed.controlMissing(from: 1, to: 2) && missing.controlMissing(from: 1, to: 2), "a control missing in one app counted for all")
    try check(MeetingMembers.combined([.muted, .unmuted, .unavailable]) == .unmuted && MeetingMembers.combined([.unavailable, .muted]) == .muted
              && MeetingMembers.combined([]) == .unavailable, "the microphone of several apps misread")

    let me = NSRunningApplication.current
    let zoomApp = MeetingTarget(app: .zoom, process: me)
    // Distinct processes are needed only by pid: the targets are told apart by it.
    let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me.processIdentifier }.prefix(2)
    if others.count == 2 {
        let telemostApp = MeetingTarget(app: .telemost, process: others[others.startIndex])
        let browser = MeetingTarget(app: .browser("com.google.Chrome"), process: others[others.startIndex + 1])
        var shown = MeetingMembers.primary(among: [zoomApp, telemostApp], all: [zoomApp, telemostApp, browser], front: telemostApp.pid, previous: zoomApp)
        try check(shown?.pid == telemostApp.pid, "the meeting in front was not shown")
        shown = MeetingMembers.primary(among: [zoomApp, telemostApp], all: [zoomApp, telemostApp, browser], front: browser.pid, previous: zoomApp)
        try check(shown?.pid == zoomApp.pid, "an app in front without a meeting took the picture from the one shown")
        shown = MeetingMembers.primary(among: [telemostApp], all: [zoomApp, telemostApp], front: nil, previous: zoomApp)
        try check(shown?.pid == telemostApp.pid, "a meeting that ended kept the picture")
        shown = MeetingMembers.primary(among: [], all: [zoomApp, telemostApp], front: nil, previous: telemostApp)
        try check(shown?.pid == telemostApp.pid, "between meetings the picture jumped to another app")
    }
    print("PASS: Zoom and Telemost in one recording: voice kept where either has the microphone on, the meeting in front shown")
}
