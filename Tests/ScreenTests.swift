import AVFoundation
import CoreMedia
import Foundation

/// A uniform picture of brightness `level` (video range Y), as ScreenCaptureKit delivers frames.
func picture(level: Int, width: Int = 320, height: Int = 180) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "pixel buffer")
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    for (plane, value) in [(0, level), (1, 128)] {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!, Int32(value),
               CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var format: CMVideoFormatDescription?
    try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr, "video format")
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format!,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "video sample")
    return sample!
}

/// The brightness of the picture at `seconds`, 0...1.
func brightness(_ url: URL, at seconds: Double) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    var gray: UInt8 = 0
    let context = CGContext(data: &gray, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Double(gray) / 255
}

func samples(in url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .video)[0], outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var count = 0
    while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
    return count
}

func checkMeetingWindow() throws {
    let meeting = CGRect(x: 100, y: 50, width: 1200, height: 800)
    let home: (id: CGWindowID, frame: CGRect) = (1, CGRect(x: 0, y: 0, width: 1512, height: 982))
    let toolbar: (id: CGWindowID, frame: CGRect) = (3, CGRect(x: 110, y: 60, width: 300, height: 200))
    let window: (id: CGWindowID, frame: CGRect) = (2, CGRect(x: 100, y: 51, width: 1200, height: 799))
    try check(ZoomMeetingWindow.match(meeting, in: [home, window, toolbar]) == 2, "meeting window not matched")
    try check(ZoomMeetingWindow.match(meeting, in: [home, toolbar]) == nil, "another window taken for the meeting")
    // The user's own share: Zoom's share windows, and a window of Zoom's exactly over the shared display.
    let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 1920, height: 1080)]
    let toolbar2 = (title: "zoom share toolbar window", layer: 97, frame: CGRect(x: 1900, y: 0, width: 600, height: 60))
    let statusbar = (title: "Zoom Share Statusbar Window", layer: 97, frame: CGRect(x: 2200, y: 1000, width: 300, height: 40))
    let wholeDisplay = ZoomMeetingWindow.share(windows: [toolbar2, statusbar, ("Annotation - Zoom", 96, displays[1])], displays: displays)
    try check(wholeDisplay.sharing && wholeDisplay.display == 1, "a shared display not found: \(wholeDisplay)")
    let oneWindow = ZoomMeetingWindow.share(windows: [toolbar2, ("Annotation - Zoom", 96, CGRect(x: 1600, y: 100, width: 800, height: 600))],
                                            displays: displays)
    try check(oneWindow.sharing && oneWindow.display == nil, "a shared window taken for a display: \(oneWindow)")
    let both = ZoomMeetingWindow.share(windows: [toolbar2, ("Annotation - Zoom", 96, displays[0]), ("Annotation - Zoom", 96, displays[1])],
                                       displays: displays)
    try check(both.sharing && both.display == nil, "one of two covered displays taken for the shared one: \(both)")
    let meetingOnly = ZoomMeetingWindow.share(windows: [("Zoom Meeting", 0, displays[0]), ("zoom floating video window", 26, displays[1])],
                                              displays: displays)
    try check(!meetingOnly.sharing && meetingOnly.display == nil, "a meeting without a share taken for one: \(meetingOnly)")
    // The user switching desktops with Zoom's meeting window on one of them, again and again: the window is
    // recorded on any desktop, by its place while Accessibility names it and as the window remembered while
    // it does not; another window of Zoom's at the same place, in sight or not, is not taken for it; every
    // pause says why.
    let screen = [(id: CGDirectDisplayID(1), frame: displays[0])]
    let place = CGRect(x: 100, y: 80, width: 1000, height: 700)
    let named = ZoomMeetingWindow.Lookup.window(place, title: "Zoom Meeting")
    let meetingWindow = ZoomWindow(id: 100, title: "Zoom Meeting", layer: 0, frame: place, onScreen: true)
    let elsewhere = ZoomWindow(id: 100, title: "Zoom Meeting", layer: 0, frame: place, onScreen: false)
    let homeWindow = ZoomWindow(id: 102, title: "Zoom Workplace", layer: 0, frame: place, onScreen: true)
    let ghost = ZoomWindow(id: 101, title: "", layer: 0, frame: place, onScreen: false)
    let fullScreen = ZoomWindow(id: 100, title: "Zoom Meeting", layer: 0, frame: displays[0], onScreen: true)
    let fullScreenElsewhere = ZoomWindow(id: 100, title: "Zoom Meeting", layer: 0, frame: displays[0], onScreen: false)
    typealias Step = (windows: [ZoomWindow], lookup: ZoomMeetingWindow.Lookup, hidden: Bool,
                      target: ScreenCapture.Target?, pause: ScreenCapture.Pause?)
    let steps: [Step] = [
        ([homeWindow, ghost, meetingWindow], named, false, .window(100), nil),
        ([ghost, elsewhere], .missing, false, .window(100), nil),
        ([ghost, meetingWindow], .missing, false, .window(100), nil),
        ([ghost, elsewhere], named, false, .window(100), nil),
        ([ghost, meetingWindow], named, false, .window(100), nil),
        ([fullScreen], .window(displays[0], title: "Zoom Meeting"), false, .window(100), nil),
        ([fullScreenElsewhere], .missing, false, .window(100), nil),
        ([fullScreen], .missing, false, .window(100), nil),
        ([meetingWindow], named, false, .window(100), nil),
        ([elsewhere], .minimized, false, nil, .minimized),
        // Minimized and left out by Accessibility: still minimized, until it is in sight again.
        ([elsewhere], .missing, false, nil, .minimized),
        ([meetingWindow], .missing, false, .window(100), nil),
        ([elsewhere], named, true, nil, .hidden),
        ([meetingWindow], named, false, .window(100), nil),
        ([ghost], .missing, false, nil, .noMeeting),
    ]
    var recording: ScreenCapture.Target?
    var remembered: CGWindowID?
    var pause: ScreenCapture.Pause?
    for (index, step) in steps.enumerated() {
        let choice = ScreenCapture.decide(windows: step.windows, displays: screen, meeting: { step.lookup }, paused: { false },
                                          recording: recording, remembered: remembered, lastPause: pause, hidden: step.hidden)
        try check(choice.target == step.target && choice.pause == step.pause && !choice.sharing,
                  "desktop step \(index): \(String(describing: choice.target)), \(String(describing: choice.pause))")
        recording = choice.target
        remembered = choice.remembered
        pause = choice.pause
    }
    // Recording begun with the meeting window on another desktop, should Zoom name it there: the window
    // so named, not another at the same place; none so named, nothing.
    let begun = ScreenCapture.decide(windows: [ghost, elsewhere], displays: screen, meeting: { named }, paused: { false },
                                     recording: nil, remembered: nil)
    try check(begun.target == .window(100) && begun.remembered == 100, "another window taken for the meeting: \(begun)")
    let unnamed = ScreenCapture.decide(windows: [ghost], displays: screen, meeting: { named }, paused: { false },
                                       recording: nil, remembered: nil)
    try check(unnamed.target == nil && unnamed.pause == .noMeeting, "a ghost taken for the meeting: \(unnamed)")
    // A share starting, going on from another desktop, pausing, resuming, shrinking to one window and ending.
    let shareBar = ZoomWindow(id: 7, title: "zoom share toolbar window", layer: 97, frame: CGRect(x: 400, y: 0, width: 600, height: 60),
                              onScreen: true)
    let border = ZoomWindow(id: 8, title: "", layer: 96, frame: displays[0], onScreen: true)
    let shareBarOff = ZoomWindow(id: 7, title: "zoom share toolbar window", layer: 97, frame: shareBar.frame, onScreen: false)
    let shares: [(windows: [ZoomWindow], paused: Bool, target: ScreenCapture.Target?, pause: ScreenCapture.Pause?)] = [
        ([meetingWindow], false, .window(100), nil), ([shareBar, border], false, .display(1), nil),
        ([shareBarOff, elsewhere], false, .display(1), nil), ([shareBar, border], false, .display(1), nil),
        ([shareBar, border], true, nil, .sharePaused), ([shareBar, border], false, .display(1), nil),
        ([shareBar], false, nil, .sharingWindow), ([meetingWindow], false, .window(100), nil),
    ]
    for (index, step) in shares.enumerated() {
        let choice = ScreenCapture.decide(windows: step.windows, displays: screen, meeting: { named },
                                          paused: { step.paused }, recording: recording, remembered: remembered)
        try check(choice.target == step.target && choice.pause == step.pause,
                  "share step \(index): \(String(describing: choice.target)), \(String(describing: choice.pause))")
        recording = choice.target
        remembered = choice.remembered
    }
    // A window of another shape goes in the middle of the picture, as large as fits.
    for (size, expected) in [(CGSize(width: 700, height: 700), CGRect(x: 420, y: 0, width: 1080, height: 1080)),
                             (CGSize(width: 1600, height: 900), CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                             (CGSize(width: 1200, height: 400), CGRect(x: 0, y: 220, width: 1920, height: 640)),
                             (CGSize(width: 333, height: 777), CGRect(x: 729, y: 0, width: 462, height: 1080))] {
        let placed = ScreenCapture.placement(of: size)
        try check(placed == expected, "a \(size) window placed at \(placed), expected \(expected)")
    }
    try check(!ScreenCapture.differs(CGSize(width: 1000, height: 701), from: CGSize(width: 1000, height: 700))
              && ScreenCapture.differs(CGSize(width: 1000, height: 600), from: CGSize(width: 1000, height: 700)),
              "rounding taken for a new window shape, or a new shape missed")
    print("PASS: Zoom's meeting window found by its frame and placed in the middle of the picture; the user's shared display found"
          + (ScreenTrack.encodesForQuality ? "" : " (this encoder takes no quality setting: a fixed bit rate is used)"))
}

/// Parts start at their first frame, a still picture is written again every second, and a
/// part lasts until it is closed.
func checkScreenTrack(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let track = ScreenTrack(directory: folder, width: 320, height: 180, realtime: false)
    let frame = try picture(level: 100)
    for index in 0..<20 { track.append(frame, at: Int64(index * 4800)) }
    // Nothing new after 1.9 s: the picture is written again at 3 s only.
    for index in 21...30 { track.hold(at: Int64(index * 4800)) }
    track.close(at: 168_000)
    for index in 0..<10 { track.append(frame, at: 240_000 + Int64(index * 4800)) }
    await track.finish(at: 288_000)
    let parts = ScreenTrack.parts(in: folder)
    try check(parts.map(\.start) == [0, 240_000], "screen parts start at \(parts.map(\.start))")
    let lengths = try await parts.asyncMap { try await verifyRecording($0.url, audio: 0) }
    try check(abs(lengths[0] - 3.5) < 0.05 && abs(lengths[1] - 1) < 0.05, "screen parts last \(lengths) s")
    let count = try await samples(in: parts[0].url)
    try check(count == 21, "first part holds \(count) frames, expected 20 and one held")
    print("PASS: screen parts start at their first frame, hold a still picture and end where closed")
}

/// The saved video lies over the saved sound: both start where the silence before the meeting
/// was cut, and a gap in the picture stays a gap. The sound is delivered first, whatever happens
/// to the video, and never twice.
func checkScreenDelivery(_ folder: URL) async throws {
    let root = folder.appendingPathComponent("sessions")
    let destination = folder.appendingPathComponent("meetings")
    let manager = FileManager.default
    // Ten seconds, a participant from 3 s on, so the saved file starts at 2 s.
    func session(_ name: String) async throws -> RecordingSession {
        let session = try RecordingSession.create(destination: destination, name: name, root: root)
        let zoom = AudioTrack(name: "zoom", directory: session.folder, channels: 2, realtime: false)
        let pcm = PCMNormalizer(channels: 2)
        for index in 0..<100 {
            zoom.append(try pcm.convert(try sample(frequency: index >= 30 ? 440 : 0, start: Int64(index * 4800), channels: 2,
                                                   float: true)), at: Int64(index * 4800))
        }
        await zoom.finish()
        return session
    }
    /// The picture changes every quarter second of the recording.
    func level(at seconds: Double) -> Int { 30 + 4 * Int(seconds * 4) }
    /// Screen parts over `spans` of the recording, ten frames a second.
    func screen(_ session: RecordingSession, _ spans: [Range<Double>]) async throws -> [URL] {
        let track = ScreenTrack(directory: session.folder, width: 320, height: 180, realtime: false)
        for span in spans {
            var tenth = Int((span.lowerBound * 10).rounded())
            while Double(tenth) / 10 < span.upperBound {
                track.append(try picture(level: level(at: Double(tenth) / 10)), at: Int64(tenth * 4800))
                tenth += 1
            }
            track.close(at: Int64(span.upperBound * 48_000))
        }
        await track.finish(at: nil)
        return track.parts
    }

    // The screen from 1 to 4 s and from 5.5 to 8.5 s of the recording.
    let recorded = try await session("Screen.m4a")
    SpeakerLog(directory: recorded.folder).speaker("Анна", at: 3.5)
    let parts = try await screen(recorded, [1..<4, 5.5..<8.5])
    // What each quarter second looks like once encoded, read from the parts themselves.
    var reference: [Int: Double] = [:]
    for (part, span) in zip(parts, [1.0..<4, 5.5..<8.5]) {
        for quarter in Int(span.lowerBound * 4)..<Int(span.upperBound * 4) {
            let time = max(Double(quarter) / 4 + 0.12, span.lowerBound + 0.05)
            reference[quarter] = try await brightness(part, at: time - span.lowerBound)
        }
    }
    let delivered = try await recorded.deliver(fallback: destination)
    guard let video = delivered.video else { throw TestError.failed("no video saved") }
    try check(video.lastPathComponent == "Screen.mp4" && video.deletingLastPathComponent() == delivered.url.deletingLastPathComponent(),
              "video saved as \(video.path)")
    try await verifyRecording(delivered.url)
    let length = try await verifyRecording(video)
    try check(abs(length - delivered.duration) < 0.1 && abs(length - 8) < 0.15, "video lasts \(length) s, the sound \(delivered.duration) s")
    // Time without a picture is black, up to the end of the sound, and the speakers go with the video.
    let pictureRange = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)[0].load(.timeRange)
    try check(abs(pictureRange.end.seconds - length) < 0.15, "the picture ends at \(pictureRange.end.seconds) s, the sound at \(length) s")
    for time in [2.5, 7.0] {
        let shown = try await brightness(video, at: time)
        try check(shown < 0.03, "at \(time) s, with no picture, the video shows \(shown), not black")
    }
    let tags = try await AVURLAsset(url: video).load(.metadata)
    let described = try await tags.asyncMap { try await $0.load(.stringValue) ?? "" }
    try check(described.contains { $0.contains("Анна") }, "the speakers did not go with the video: \(described)")
    for time in [0.1, 1.9, 3.6, 6.3] {
        let shown = try await brightness(video, at: time)
        let nearest = reference.keys.min { abs(reference[$0]! - shown) < abs(reference[$1]! - shown) }!
        let expected = Int((time + 2) * 4)
        try check(nearest == expected, "at \(time) s the video shows \(Double(nearest) / 4) s of the recording, expected \(Double(expected) / 4) s")
    }
    try check(!delivered.incomplete && !delivered.videoFailed, "a good screen marked as a problem")
    try check(!manager.fileExists(atPath: recorded.folder.path), "the session was not retired")

    // A screen only during the silence that was cut: no video, nothing lost.
    let early = try await session("Early.m4a")
    _ = try await screen(early, [0..<1])
    let earlyDelivery = try await early.deliver(fallback: destination)
    try check(earlyDelivery.video == nil && !earlyDelivery.incomplete && !earlyDelivery.videoFailed, "a screen outside the saved file was saved")

    // An unreadable screen part goes aside; the sound is saved.
    let damaged = try await session("Damaged.m4a")
    let part = damaged.folder.appendingPathComponent("screen-1-0.mp4")
    try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: part)
    let damagedDelivery = try await damaged.deliver(fallback: destination)
    try check(damagedDelivery.video == nil && damagedDelivery.incomplete, "a damaged screen part was not kept aside")
    try check(manager.fileExists(atPath: damagedDelivery.unreadableFolder!.appendingPathComponent(part.lastPathComponent).path),
              "the damaged screen part was lost")

    /// A folder in place of the copy `place` makes of the video, which it can neither remove nor replace.
    func blockVideoCopy(of session: RecordingSession, in directory: URL) throws -> URL {
        let blocker = directory.appendingPathComponent(".zoom-recording-\(session.folder.lastPathComponent)-screen.partial.mp4")
        try manager.createDirectory(at: blocker, withIntermediateDirectories: true)
        try manager.setAttributes([.immutable: true], ofItemAtPath: blocker.path)
        return blocker
    }
    func unblock(_ url: URL) throws {
        try manager.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try manager.removeItem(at: url)
    }

    // A video that cannot be copied: the sound is delivered, the video kept aside.
    let copy = try await session("Copy.m4a")
    _ = try await screen(copy, [2..<6])
    let blocked = try blockVideoCopy(of: copy, in: destination)
    let copyDelivery = try await copy.deliver(fallback: destination)
    try unblock(blocked)
    try check(manager.fileExists(atPath: copyDelivery.url.path) && copyDelivery.url.lastPathComponent == "Copy.m4a"
              && !copyDelivery.usedFallback, "the sound was not delivered with its video failing: \(copyDelivery.url.path)")
    try check(copyDelivery.video == nil && copyDelivery.videoFailed && !copyDelivery.incomplete, "a failed video copy was not reported")
    try check(manager.fileExists(atPath: copyDelivery.unreadableFolder!.appendingPathComponent("screen.mp4").path),
              "the video that could not be copied was lost")
    try check(!manager.fileExists(atPath: copy.folder.path), "the session was kept after the sound was delivered")

    // An export cut short by a crash or a hang is not tried again: the parts go aside, the sound is delivered.
    let interrupted = try await session("Interrupted.m4a")
    let interruptedParts = try await screen(interrupted, [2..<6])
    manager.createFile(atPath: interrupted.folder.appendingPathComponent("screen-attempt").path, contents: nil)
    let interruptedDelivery = try await interrupted.deliver(fallback: destination)
    try check(manager.fileExists(atPath: interruptedDelivery.url.path) && interruptedDelivery.videoFailed,
              "an interrupted video export held up the sound")
    try check(interruptedParts.allSatisfy {
        manager.fileExists(atPath: interruptedDelivery.unreadableFolder!.appendingPathComponent($0.lastPathComponent).path)
    }, "the parts of an interrupted video were lost")

    // A video that can be neither saved nor kept aside keeps the session; the next attempt saves the video
    // and does not deliver the sound again.
    let retry = try await session("Retry.m4a")
    _ = try await screen(retry, [2..<6])
    let blockedAgain = try blockVideoCopy(of: retry, in: destination)
    let aside = retry.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Unreadable")
    try manager.createDirectory(at: aside, withIntermediateDirectories: true)
    try manager.setAttributes([.immutable: true], ofItemAtPath: aside.path)
    let first = try await retry.deliver(fallback: destination)
    try manager.setAttributes([.immutable: false], ofItemAtPath: aside.path)
    try unblock(blockedAgain)
    try check(first.videoFailed && manager.fileExists(atPath: retry.folder.path), "a video that could not be kept aside was dropped")
    let second = try await retry.deliver(fallback: destination)
    try check(second.url == first.url && second.video?.lastPathComponent == "Retry.mp4", "the retry gave \(second.url.path), \(String(describing: second.video))")
    try check(!manager.fileExists(atPath: destination.appendingPathComponent("Retry 2.m4a").path), "the sound was delivered twice")
    try check(!manager.fileExists(atPath: retry.folder.path), "the session was not retired after the retry")

    // Parts at a fixed bit rate, after the picture turned out heavy, go together with the others.
    let heavy = try await session("Heavy.m4a")
    let mixed = ScreenTrack(directory: heavy.folder, width: 320, height: 180, realtime: false)
    for tenth in 20..<50 { mixed.append(try picture(level: level(at: Double(tenth) / 10)), at: Int64(tenth * 4800)) }
    mixed.close(at: 240_000)
    mixed.capped = true
    for tenth in 50..<90 { mixed.append(try picture(level: level(at: Double(tenth) / 10)), at: Int64(tenth * 4800)) }
    await mixed.finish(at: nil)
    let heavyDelivery = try await heavy.deliver(fallback: destination)
    try check(heavyDelivery.video != nil && !heavyDelivery.videoFailed, "parts of both kinds did not make one video")

    // Without a black part the video is still saved, its gaps empty.
    let defaultBlack = RecordingSession.blackPart
    RecordingSession.blackPart = { _, _, _ in throw RecorderError.message("no black") }
    let plain = try await session("Plain.m4a")
    _ = try await screen(plain, [3..<5, 7..<8])
    let plainDelivery = try await plain.deliver(fallback: destination)
    try check(plainDelivery.video != nil && !plainDelivery.videoFailed, "a video without a black part was not saved")

    // A video step that hangs is given up: the sound is delivered at once, once, and the session retired.
    let defaultTimeout = RecordingSession.screenTimeout
    RecordingSession.screenTimeout = { _ in 2 }
    RecordingSession.blackPart = { _, _, _ in
        try await Task.sleep(for: .seconds(3600))
        throw RecorderError.message("unreachable")
    }
    let hung = try await session("Hung.m4a")
    _ = try await screen(hung, [3..<5])
    let begun = Date()
    let hungDelivery = try await hung.deliver(fallback: destination)
    RecordingSession.blackPart = defaultBlack
    RecordingSession.screenTimeout = defaultTimeout
    try check(Date().timeIntervalSince(begun) < 15, "a hung video held up saving for \(Date().timeIntervalSince(begun)) s")
    try check(manager.fileExists(atPath: hungDelivery.url.path) && hungDelivery.videoFailed && hungDelivery.video == nil,
              "a hung video was not set aside with the sound delivered")
    try check(!manager.fileExists(atPath: hung.folder.path), "the session of a hung video was kept")
    print("PASS: the saved video lies over the saved sound with its gaps; the sound is delivered first, once, whatever the video does")
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
