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
    print("PASS: Zoom's meeting window found by its frame")
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
    let pictureRange = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)[0].load(.timeRange)
    try check(abs(pictureRange.end.seconds - 6.5) < 0.15, "the picture ends at \(pictureRange.end.seconds) s, expected 6.5 s")
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
    print("PASS: the saved video lies over the saved sound with its gaps; the sound is delivered first, once, whatever the video does")
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
