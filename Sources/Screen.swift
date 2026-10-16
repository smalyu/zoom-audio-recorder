import AVFoundation
import AppKit
import ApplicationServices
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Zoom's meeting window, written as crash-safe fragmented MP4 parts on the session timeline
/// like the audio tracks: a part is named after its first frame's position in 48 kHz frames.
/// A part ends where the picture does, when the window goes away or recording it is turned
/// off, so a gap stays empty instead of holding a stale picture.
final class ScreenTrack {
    static let width = 1920
    static let height = 1080
    static let frameRate = 10
    /// A still picture is written again every second, so a part cut short by a crash still
    /// plays to its last moment.
    static let hold: Int64 = 48_000
    private static let rate = CMTimeScale(AudioTrack.rate)
    let directory: URL
    private let width: Int
    private let height: Int
    private let realtime: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var start: Int64 = 0
    private var last: (sample: CMSampleBuffer, position: Int64)?
    private var retryAt = Date.distantPast
    private var retryDelay = 5.0
    private let closing = DispatchGroup()
    private(set) var parts: [URL] = []
    private(set) var failure: Error?

    var currentPart: URL? { writer == nil ? nil : parts.last }

    init(directory: URL, width: Int = ScreenTrack.width, height: Int = ScreenTrack.height, realtime: Bool = true) {
        self.directory = directory
        self.width = width
        self.height = height
        self.realtime = realtime
    }

    static func parts(in directory: URL) -> [TrackPart] {
        AudioTrack.parts(named: "screen", in: directory, type: "mp4")
    }

    /// Appends a captured frame at its timeline position. Use one serial queue.
    func append(_ sample: CMSampleBuffer, at position: Int64) {
        if let last, position <= last.position { return }
        if writer == nil { guard openPart(at: position) else { return } }
        guard let writer, let input else { return }
        last = (sample, position)
        if !realtime {
            while !input.isReadyForMoreMediaData, writer.status == .writing { Thread.sleep(forTimeInterval: 0.001) }
        }
        // A busy encoder skips a frame of a live picture rather than falling behind.
        guard input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: position - start, timescale: Self.rate),
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy, input.append(copy) else {
            return fail(writer.error ?? RecorderError.message("Не удалось записать экран"))
        }
        if position - start >= 10 * Self.hold { retryDelay = 5 }
    }

    /// Writes the last picture again when no new one came for a second.
    func hold(at position: Int64) {
        guard let last, writer != nil, position - last.position >= Self.hold else { return }
        append(last.sample, at: position)
    }

    /// Ends the current part at `position`, where the picture stopped: the last frame lasts until then.
    func close(at position: Int64?) {
        if let writer, let input, writer.status == .writing {
            if let last {
                let end = max(position ?? 0, last.position + Self.hold / Int64(Self.frameRate))
                writer.endSession(atSourceTime: CMTime(value: end - start, timescale: Self.rate))
            }
            input.markAsFinished()
            closing.enter()
            writer.finishWriting { [closing] in closing.leave() }
        }
        writer = nil
        input = nil
        last = nil
    }

    /// Closes the last part and flushes every part to storage.
    func finish(at position: Int64?) async {
        close(at: position)
        let closing = closing
        // A picture is never worth holding up the sound: a part left unfinished plays to its last fragment.
        await waitAtMost(10) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                closing.notify(queue: .global()) { done.resume() }
            }
        }
        parts.forEach(syncToStorage)
    }

    private func openPart(at position: Int64) -> Bool {
        guard position >= 0, Date() >= retryAt, parts.count < AudioTrack.maxParts else { return false }
        let url = directory.appendingPathComponent("screen-\(parts.count + 1)-\(position).mp4")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                // Slides and shared screens stand still most of the time: a megabit keeps their
                // text sharp, about 450 MB an hour at most, and a keyframe every 10 s is enough.
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                    AVVideoMaxKeyFrameIntervalDurationKey: 10,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ])
            input.expectsMediaDataInRealTime = realtime
            guard writer.canAdd(input) else { throw RecorderError.message("Не удалось добавить видеодорожку") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? RecorderError.message("Не удалось начать запись экрана") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            parts.append(url)
            start = position
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        recorderLog.error("screen track: \(error.localizedDescription, privacy: .public)")
        failure = error
        // Back off: a full disk or a broken encoder would fail again right away.
        retryAt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 60)
        close(at: nil)
    }
}

/// Finds Zoom's meeting window for ScreenCaptureKit. Accessibility knows which of Zoom's
/// windows is the meeting; ScreenCaptureKit knows windows by number only, so the two are
/// matched by where the window is.
enum ZoomMeetingWindow {
    /// The meeting window's frame in global screen coordinates, top left origin, as in
    /// SCWindow; nil while there is none, as when the user shares their own screen.
    static func frame(pid: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        AXUIElementSetMessagingTimeout(application, 0.2)
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement],
              let window = windows.first(where: { attribute(kAXIdentifierAttribute, of: $0) as? String == "zm.meeting.window.main" }),
              attribute(kAXMinimizedAttribute, of: window) as? Bool != true,
              let position = attribute(kAXPositionAttribute, of: window), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, of: window), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// The window that covers `frame` best, if it covers most of it.
    static func match(_ frame: CGRect, in windows: [(id: CGWindowID, frame: CGRect)]) -> CGWindowID? {
        func overlap(_ other: CGRect) -> Double {
            let common = frame.intersection(other)
            guard !common.isNull, frame.width * frame.height > 0 else { return 0 }
            let shared = common.width * common.height
            return shared / (frame.width * frame.height + other.width * other.height - shared)
        }
        let best = windows.max { overlap($0.frame) < overlap($1.frame) }
        return best.flatMap { overlap($0.frame) >= 0.8 ? $0.id : nil }
    }

    /// The SCWindow at the meeting window's frame `frame`; windows on screen first, as a
    /// same-sized window of Zoom's elsewhere is not the meeting.
    static func find(in content: SCShareableContent, frame: CGRect, pid: pid_t) -> SCWindow? {
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            .sorted { $0.isOnScreen && !$1.isOnScreen }
        let id = match(frame, in: windows.map { ($0.windowID, $0.frame) })
        return windows.first { $0.windowID == id }
    }

    static func find(in content: SCShareableContent, pid: pid_t) -> SCWindow? {
        frame(pid: pid).flatMap { find(in: content, frame: $0, pid: pid) }
    }
}

/// Records Zoom's meeting window while the user wants it, on a stream of its own: whatever
/// happens to the picture never touches the sound. The window is captured on its own, so
/// other windows over it do not hide it; a hidden or minimized window shows nothing.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Below this much free space the screen pauses, so the sound keeps its room.
    static let minimumSpace: Int64 = 300_000_000
    /// A stream that delivers nothing this long while its window is visible has stopped.
    static let silence = 10.0
    let queue = DispatchQueue(label: "zoom-audio.screen")
    let track: ScreenTrack
    /// Host time of the session timeline's start, once the first audio placed it.
    private let origin: () -> Double?
    private let directory: URL
    /// The stream frames are taken from; read on `queue`.
    private var current: SCStream?
    private let broken = Locked(false)
    /// The window is there but shows nothing, as while Zoom is hidden or minimized.
    private let hidden = Locked(false)
    /// Host time of the stream's last delivery of any kind.
    private let lastDelivery = Locked(0.0)
    /// Recording the screen was on at some point.
    private(set) var wanted = false

    init(directory: URL, origin: @escaping () -> Double?) {
        self.directory = directory
        self.origin = origin
        track = ScreenTrack(directory: directory)
    }

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func position(at time: Double) -> Int64? {
        origin().map { Int64(((time - $0) * AudioTrack.rate).rounded()) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === current, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? Int).flatMap({ SCFrameStatus(rawValue: $0) }) else { return }
        let now = Self.now()
        lastDelivery.current = now
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Frames carry the host time they were captured at; one that does not is placed by arrival.
        let time = pts.isNumeric && abs(pts.seconds - now) < 5 ? pts.seconds : now
        guard let position = position(at: time) else { return }
        switch status {
        case .complete, .started:
            hidden.current = false
            if CMSampleBufferGetImageBuffer(sample) != nil { track.append(sample, at: position) }
        case .idle:
            // Nothing changed: the picture goes on. Placed by its own capture time, in order with the frames.
            hidden.current = false
            track.hold(at: position)
        case .blank, .suspended, .stopped:
            // The window is hidden or gone: its last picture does not stand in for what follows.
            hidden.current = true
            track.close(at: position)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.current else { return }
            recorderLog.error("Screen stream stopped: \(error.localizedDescription, privacy: .public)")
            self.broken.current = true
        }
    }

    /// Records the meeting window whenever `wanted` is on, until `stop`, then closes the track.
    /// `found` tells whether the window is being recorded while it is wanted.
    func run(wanted: Locked<Bool>, stop: StopRequest, found: @escaping (Bool) -> Void) async {
        var stream: SCStream?
        var window: (id: CGWindowID, frame: CGRect)?
        var nextLook = Date.distantPast
        var startDelay = 5.0
        var lastSync = Date()
        var lastSpaceCheck = Date.distantPast
        var lowSpace = false
        var reported: Bool?
        var writingAt = Self.now()
        func end() async {
            if let stream { await waitAtMost(5) { try? await stream.stopCapture() } }
            stream = nil
            window = nil
            let position = position(at: Self.now())
            queue.sync {
                current = nil
                track.close(at: position)
            }
            broken.current = false
            hidden.current = false
        }
        while !stop.isRequested {
            if Date().timeIntervalSince(lastSpaceCheck) >= 30 {
                lastSpaceCheck = Date()
                let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? .max
                lowSpace = free < Self.minimumSpace
            }
            if !wanted.current || lowSpace {
                if stream != nil { await end() }
                nextLook = .distantPast
            } else {
                self.wanted = true
                // A stream that went quiet while its window is visible, as after the Mac sleeps, starts again.
                if stream != nil, !hidden.current, Self.now() - lastDelivery.current > Self.silence {
                    recorderLog.error("Screen stream went quiet; restarting")
                    broken.current = true
                }
                if broken.current {
                    await end()
                    nextLook = .distantPast
                }
                if Date() >= nextLook, let app = ZoomAudio.runningZoom() {
                    nextLook = Date().addingTimeInterval(5)
                    // Accessibility names the meeting window cheaply; the system's window list is asked only
                    // when it names one other than the window recorded. No answer, as from a busy Zoom or a
                    // window on another desktop, keeps the window recorded.
                    let pid = app.processIdentifier
                    if let frame = ZoomMeetingWindow.frame(pid: pid),
                       window.map({ ZoomMeetingWindow.match(frame, in: [$0]) == nil }) ?? true,
                       let content = try? await bounded(stop, timeout: 10, {
                           try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                       }),
                       let meeting = ZoomMeetingWindow.find(in: content, frame: frame, pid: pid) {
                        if let running = stream, meeting.windowID != window?.id {
                            // Another meeting window: the same stream and part go on with it.
                            do {
                                try await bounded(stop, timeout: 10) {
                                    try await running.updateContentFilter(SCContentFilter(desktopIndependentWindow: meeting))
                                }
                            } catch {
                                await end()
                            }
                        }
                        if stream == nil, !stop.isRequested {
                            stream = await start(meeting, stop: stop)
                            if stream == nil {
                                nextLook = Date().addingTimeInterval(startDelay)
                                startDelay = min(startDelay * 2, 60)
                            } else {
                                startDelay = 5
                            }
                        }
                        if stream != nil { window = (meeting.windowID, meeting.frame) }
                    }
                }
            }
            // Recorded means written: frames before the timeline starts, a failing encoder or a hidden
            // window write nothing. Low disk space has a warning of its own.
            if !wanted.current || lowSpace || queue.sync(execute: { track.currentPart != nil }) { writingAt = Self.now() }
            if !stop.isRequested {
                let value = Self.now() - writingAt < 3
                if value != reported { found(value) }
                reported = value
            }
            if Date().timeIntervalSince(lastSync) >= 10 {
                lastSync = Date()
                queue.sync { track.currentPart }.map(syncToStorage)
            }
            await stop.wait(timeout: 1)
        }
        // The part is closed on the queue; no frame reaches the track after this.
        await end()
        await track.finish(at: nil)
    }

    private func start(_ window: SCWindow, stop: StopRequest) async -> SCStream? {
        let config = SCStreamConfiguration()
        config.width = ScreenTrack.width
        config.height = ScreenTrack.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreenTrack.frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.queueDepth = 6
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync {
                current = stream
                broken.current = false
                hidden.current = false
                lastDelivery.current = Self.now()
            }
            try await bounded(stop, timeout: 10, onLateResult: { _ in
                // startCapture can finish after cancellation and after the first stop attempt.
                try? await stream.stopCapture()
            }) { try await stream.startCapture() }
            recorderLog.notice("Recording Zoom's meeting window \(window.windowID)")
            return stream
        } catch {
            recorderLog.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            let position = position(at: Self.now())
            // Frames may have come before the start gave up: their part ends here.
            queue.sync {
                current = nil
                track.close(at: position)
            }
            Task { try? await stream.stopCapture() }
            return nil
        }
    }
}
