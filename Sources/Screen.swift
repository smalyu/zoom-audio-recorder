import AVFoundation
import AppKit
import ApplicationServices
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the meeting shows, written as crash-safe fragmented MP4 parts on the session timeline
/// like the audio tracks: a part is named after its first frame's position in 48 kHz frames.
/// A part ends where the picture does, when the window goes away or recording it is turned
/// off, so a gap is black in the saved video instead of holding a stale picture.
final class ScreenTrack {
    static let width = 1920
    static let height = 1080
    static let frameRate = 10
    /// A still picture is written again every second, so a part cut short by a crash still
    /// plays to its last moment.
    static let hold: Int64 = 48_000
    /// A picture that keeps above this many bits a second, as grainy video does, is written at a
    /// fixed bit rate from its next part on.
    static let heavy = 1_500_000.0
    private static let rate = CMTimeScale(AudioTrack.rate)
    let directory: URL
    private let width: Int
    private let height: Int
    private let realtime: Bool
    /// Later parts keep to a fixed bit rate.
    var capped = false
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
            // An encoder that stops taking frames fails the part rather than holding up its writer.
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            guard input.isReadyForMoreMediaData else { return fail(RecorderError.message("Кодировщик видео не отвечает")) }
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
        // Encoded for quality, not to a bit rate: text is sharp from a part's first frame and a still
        // picture costs next to nothing, 25 to 220 MB an hour in tests. A keyframe every 10 s: more
        // often costs text its sharpness. A picture that turns out heavy is capped from its next part.
        let rate: [String: Any] = capped ? [AVVideoAverageBitRateKey: 1_000_000] : [AVVideoQualityKey: 0.6]
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
                AVVideoCompressionPropertiesKey: rate.merging([
                    AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                    AVVideoMaxKeyFrameIntervalDurationKey: 10,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]) { $1 }
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

extension ScreenTrack {
    /// How long the black part lasts; a longer stretch without a picture repeats it.
    static let blackLength = CMTime(value: 10, timescale: 1)

    /// Ten seconds of black picture as one part in `directory`, a single keyframe, in the size of
    /// the screen parts it goes between.
    static func black(width: Int, height: Int, in directory: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var buffer: CVPixelBuffer?
        guard width > 0, height > 0,
              CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixels = buffer else { throw RecorderError.message("Не удалось подготовить видео") }
        CVPixelBufferLockBaseAddress(pixels, [])
        for (plane, value) in [(0, Int32(16)), (1, Int32(128))] {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) {
                memset(base, value, CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr, let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw RecorderError.message("Не удалось подготовить видео") }
        let track = ScreenTrack(directory: directory, width: width, height: height, realtime: false)
        track.append(sample, at: 0)
        await track.finish(at: Int64(blackLength.seconds * AudioTrack.rate))
        guard let part = track.parts.first, track.failure == nil else {
            throw track.failure ?? RecorderError.message("Не удалось подготовить видео")
        }
        return part
    }
}

/// One of Zoom's windows on the screen, from the system's window list.
struct ZoomWindow: Equatable {
    let id: CGWindowID
    let title: String
    let layer: Int
    let frame: CGRect
}

/// Finds what to record of Zoom. Accessibility knows which of Zoom's windows is the meeting; the
/// system's window list knows which are on the screen and where, so the two are matched by where
/// the window is. Both are cheap; ScreenCaptureKit's own list is asked only to start or switch.
enum ZoomMeetingWindow {
    /// What Accessibility says about the meeting window.
    enum Lookup: Equatable {
        /// Its frame in global screen coordinates, top left origin, as in the window list.
        case window(CGRect)
        case minimized
        /// No meeting window, or no answer from a busy Zoom.
        case missing
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return application
    }

    static func lookup(pid: pid_t) -> Lookup {
        guard let windows = attribute(kAXWindowsAttribute, of: application(pid)) as? [AXUIElement],
              let window = windows.first(where: { attribute(kAXIdentifierAttribute, of: $0) as? String == "zm.meeting.window.main" })
        else { return .missing }
        if attribute(kAXMinimizedAttribute, of: window) as? Bool == true { return .minimized }
        guard let position = attribute(kAXPositionAttribute, of: window), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, of: window), CFGetTypeID(size) == AXValueGetTypeID() else { return .missing }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
        return .window(CGRect(origin: origin, size: extent))
    }

    static func frame(pid: pid_t) -> CGRect? {
        if case let .window(frame) = lookup(pid: pid) { return frame }
        return nil
    }

    /// Zoom's windows on the screen, on the current desktop; a hidden, minimized or other-desktop
    /// window is not, and is not recorded: ScreenCaptureKit would show it frozen or blank.
    static func onScreen(pid: pid_t) -> [ZoomWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ZoomWindow(id: CGWindowID(id), title: info[kCGWindowName as String] as? String ?? "",
                              layer: info[kCGWindowLayer as String] as? Int ?? 0, frame: frame)
        }
    }

    /// The active displays and their frames, in the same coordinates as the window list.
    static func displays() -> [(id: CGDirectDisplayID, frame: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
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

    /// Titles of Zoom's own windows while the user shares their screen; Zoom 6 and 7 name them in
    /// English whatever the language.
    static let shareWindows: Set<String> = ["zoom share toolbar window", "zoom share statusbar window"]

    /// Whether the user shares their screen in the meeting, from Zoom's windows on the screen, and
    /// the display they share, which Zoom covers with a window of its own exactly the display's
    /// size; an index into `displays`. A shared window has no such window over a whole display, so
    /// no display is named: what it is cannot be known.
    static func share(windows: [(title: String, layer: Int, frame: CGRect)], displays: [CGRect]) -> (sharing: Bool, display: Int?) {
        guard windows.contains(where: { shareWindows.contains($0.title.lowercased()) }) else { return (false, nil) }
        let overlays = windows.filter { $0.layer > 0 && !shareWindows.contains($0.title.lowercased()) }.map(\.frame)
        let display = displays.firstIndex { frame in
            overlays.contains { abs($0.minX - frame.minX) <= 2 && abs($0.minY - frame.minY) <= 2
                && abs($0.width - frame.width) <= 2 && abs($0.height - frame.height) <= 2 }
        }
        return (true, display)
    }

    /// The Resume Share button's label in each of Zoom's languages, read once per Zoom process.
    private static var resumeLabels: (pid: pid_t, labels: Set<String>)?
    private static let labelsLock = NSLock()

    private static func resumeLabels(pid: pid_t) -> Set<String> {
        if let cached = labelsLock.withLock({ resumeLabels }), cached.pid == pid { return cached.labels }
        var labels: Set<String> = ["resume share"]
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, let bundle = Bundle(url: url) {
            for language in bundle.localizations {
                guard let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                      let label = strings["Resume Share"] else { continue }
                labels.insert(label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        labelsLock.withLock { resumeLabels = (pid, labels) }
        return labels
    }

    /// Whether the user paused their share: Zoom's share toolbar then offers to resume it. The
    /// participants see a frozen picture, so the screen is not recorded meanwhile.
    static func sharePaused(pid: pid_t) -> Bool {
        let labels = resumeLabels(pid: pid)
        guard let windows = attribute(kAXWindowsAttribute, of: application(pid)) as? [AXUIElement] else { return false }
        var queue = windows.filter { (attribute(kAXTitleAttribute, of: $0) as? String).map { shareWindows.contains($0.lowercased()) } == true }
            .map { ($0, 0) }
        var budget = 300
        while let (element, depth) = queue.popLast(), budget > 0 {
            budget -= 1
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                guard let text = (attribute(name, of: element) as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                else { continue }
                if labels.contains(where: { text == $0 || text.hasPrefix($0 + " (") }) { return true }
            }
            guard depth < 8 else { continue }
            queue += (attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []).map { ($0, depth + 1) }
        }
        return false
    }

    /// Zoom's windows in one line for the log, without what may name people or meetings: Zoom's
    /// own window names are kept, others are left out.
    static func describe(_ windows: [ZoomWindow], sharing: Bool) -> String {
        let names = windows.map { window -> String in
            let lower = window.title.lowercased()
            let own = lower.hasPrefix("zoom ") || lower.hasSuffix(" - zoom") || ["", "zoom", "zoom meeting", "zoom workplace"].contains(lower)
            return "\"\(own ? window.title : "…")\" \(window.layer)"
        }
        return (sharing ? "Sharing, no display. " : "") + "Zoom windows on screen: " + names.joined(separator: "; ")
    }
}

/// Records what the meeting shows while the user wants it, on a stream of its own: whatever
/// happens to the picture never touches the sound. Zoom's meeting window is captured on its own,
/// so other windows over it do not hide it; while the user shares a whole display in the meeting,
/// that display is recorded without Zoom's windows, as the participants see it.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Below this much free space the screen pauses, so the sound keeps its room.
    static let minimumSpace: Int64 = 300_000_000
    /// A stream that delivers nothing this long while its window is visible has stopped.
    static let silence = 10.0
    /// Zoom's window shows nothing for a moment when it shows or hides its controls: only a
    /// window that shows nothing this long ends the part.
    static let hiding: Int64 = 3 * 48_000
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
    /// Where the window began to show nothing, until it shows something again; on `queue`.
    private var hiddenAt: Int64?
    /// The shape of the window the picture is fitted to, and the shape the frames show when the
    /// window has changed shape since, for `run` to fit the picture to at once.
    private let fitted = Locked<CGSize?>(nil)
    private let reshaped = Locked<CGSize?>(nil)
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
            shows()
            if let content = (info[.contentRect] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
               let fitted = fitted.current, Self.differs(content.size, from: fitted) {
                reshaped.current = content.size
            }
            if CMSampleBufferGetImageBuffer(sample) != nil { track.append(sample, at: position) }
        case .idle:
            // Nothing changed: the picture goes on. Placed by its own capture time, in order with the frames.
            shows()
            track.hold(at: position)
        case .blank, .suspended, .stopped:
            if hiddenAt == nil { hiddenAt = position }
            checkHidden(at: position)
        @unknown default:
            break
        }
    }

    private func shows() {
        if hidden.current { recorderLog.notice("The recorded picture shows again") }
        hiddenAt = nil
        hidden.current = false
    }

    /// A window that has shown nothing long enough is hidden or gone: its last picture does not
    /// stand in for what follows, so the part ends where it went. On `queue`.
    private func checkHidden(at position: Int64) {
        guard let hiddenAt, position - hiddenAt >= Self.hiding, !hidden.current else { return }
        recorderLog.notice("The recorded picture shows nothing")
        hidden.current = true
        track.close(at: hiddenAt)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.current else { return }
            recorderLog.error("Screen stream stopped: \(error.localizedDescription, privacy: .public)")
            self.broken.current = true
        }
    }

    /// What a stream records: Zoom's meeting window, or the display the user shares in the meeting.
    private enum Target: Equatable {
        case window(CGWindowID)
        case display(CGDirectDisplayID)
    }

    /// What to record now, if anything: the display the user shares, unless the share is paused, or
    /// Zoom's meeting window while it is on the screen. A shared window is not recorded: which one
    /// it is cannot be known.
    private func choose(pid: pid_t, recording: Target?) -> (target: Target?, windows: [ZoomWindow], sharing: Bool) {
        let windows = ZoomMeetingWindow.onScreen(pid: pid)
        let displays = ZoomMeetingWindow.displays()
        let share = ZoomMeetingWindow.share(windows: windows.map { ($0.title, $0.layer, $0.frame) }, displays: displays.map(\.frame))
        if share.sharing {
            guard let index = share.display, !ZoomMeetingWindow.sharePaused(pid: pid) else { return (nil, windows, true) }
            return (.display(displays[index].id), windows, true)
        }
        switch ZoomMeetingWindow.lookup(pid: pid) {
        case let .window(frame):
            let id = ZoomMeetingWindow.match(frame, in: windows.filter { $0.layer == 0 }.map { ($0.id, $0.frame) })
            return (id.map(Target.window), windows, false)
        case .minimized:
            return (nil, windows, false)
        case .missing:
            // No answer, as from a busy Zoom: the window recorded goes on while it is on the screen.
            if case let .window(id)? = recording, windows.contains(where: { $0.id == id }) { return (recording, windows, false) }
            return (nil, windows, false)
        }
    }

    /// The filter, shape and pointer setting for `target`, from ScreenCaptureKit's own list.
    private func filter(for target: Target, pid: pid_t, stop: StopRequest) async -> (filter: SCContentFilter, size: CGSize, cursor: Bool)? {
        guard let content = try? await bounded(stop, timeout: 10, {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }) else { return nil }
        switch target {
        case let .window(id):
            return content.windows.first { $0.windowID == id }.map { (SCContentFilter(desktopIndependentWindow: $0), $0.frame.size, false) }
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // Zoom leaves its own windows out of a share; so does the recording, and this app's too.
            let excluded = content.applications.filter { $0.processID == pid || $0.processID == getpid() }
            return (SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: []), display.frame.size, true)
        }
    }

    /// Records whenever `wanted` is on, until `stop`, then closes the track. `found` tells whether a
    /// picture is being written while it is wanted.
    func run(wanted: Locked<Bool>, stop: StopRequest, found: @escaping (Bool) -> Void) async {
        var stream: SCStream?
        var target: Target?
        var nextLook = Date.distantPast
        var startDelay = 5.0
        var silence = Self.silence
        var started = Date.distantPast
        var lastSync = Date()
        var lastSpaceCheck = Date.distantPast
        var lowSpace = false
        var reported: Bool?
        var writingAt = Self.now()
        var described: String?
        var weighed: (part: URL, bytes: Int, at: Date)?
        var heavy = 0
        func end() async {
            if let stream { await waitAtMost(5) { try? await stream.stopCapture() } }
            stream = nil
            target = nil
            let position = position(at: Self.now())
            queue.sync {
                current = nil
                hiddenAt = nil
                track.close(at: position)
            }
            broken.current = false
            hidden.current = false
        }
        /// Fits the picture to the window's shape when the frames show it changed, as when the
        /// window is resized or another window is recorded.
        func fit(_ running: SCStream, to size: CGSize) async {
            guard let shape = fitted.current, Self.differs(size, from: shape) else { return }
            let cursor = { if case .display = target { return true } else { return false } }()
            if (try? await bounded(stop, timeout: 10, {
                try await running.updateConfiguration(Self.configuration(for: size, cursor: cursor))
            })) != nil {
                fitted.current = size
                reshaped.current = nil
            }
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
                // A stream that went quiet while its picture is visible, as after the Mac sleeps, starts
                // again; one that stays quiet is given longer each time.
                if stream != nil, !hidden.current {
                    let quiet = Self.now() - lastDelivery.current
                    if quiet > silence {
                        recorderLog.error("Screen stream went quiet; restarting")
                        broken.current = true
                        silence = min(silence * 2, 120)
                    } else if quiet < 2, Date().timeIntervalSince(started) > 30 {
                        silence = Self.silence
                    }
                }
                if broken.current {
                    await end()
                    nextLook = .distantPast
                }
                if let running = stream, let size = reshaped.current {
                    reshaped.current = nil
                    await fit(running, to: size)
                }
                // While the user's display is recorded, whether they still share it is checked every second.
                let display = { if case .display = target { return true } else { return false } }()
                if Date() >= nextLook || display {
                    if Date() >= nextLook { nextLook = Date().addingTimeInterval(5) }
                    // No Zoom, no picture: a display is never recorded without Zoom sharing it.
                    let pid = ZoomAudio.runningZoom()?.processIdentifier
                    let choice = pid.map { choose(pid: $0, recording: target) } ?? (target: nil, windows: [], sharing: false)
                    let state = choice.target == nil ? ZoomMeetingWindow.describe(choice.windows, sharing: choice.sharing) : nil
                    if let state, state != described { recorderLog.notice("No picture to record. \(state, privacy: .public)") }
                    described = state
                    if choice.target != target, let pid {
                        if case .window? = choice.target, case .window? = target, let running = stream,
                           let next = await filter(for: choice.target!, pid: pid, stop: stop),
                           (try? await bounded(stop, timeout: 10, { try await running.updateContentFilter(next.filter) })) != nil {
                            // Another meeting window: the same stream and part go on with it.
                            target = choice.target
                            recorderLog.notice("Recording another Zoom meeting window")
                        } else {
                            if stream != nil { await end() }
                            if let next = choice.target, !stop.isRequested {
                                if let setup = await filter(for: next, pid: pid, stop: stop),
                                   let begun = await start(setup.filter, size: setup.size, cursor: setup.cursor, stop: stop) {
                                    stream = begun
                                    target = next
                                    started = Date()
                                    startDelay = 5
                                    recorderLog.notice("Recording \(setup.cursor ? "the display the user shares" : "Zoom's meeting window", privacy: .public)")
                                } else {
                                    nextLook = Date().addingTimeInterval(startDelay)
                                    startDelay = min(startDelay * 2, 60)
                                }
                            }
                        }
                    } else if choice.target == nil, stream != nil {
                        await end()
                    }
                }
            }
            // A picture that stays heavy, as grainy video is, keeps to a fixed bit rate from its next part on.
            if let part = queue.sync(execute: { track.capped ? nil : track.currentPart }),
               let bytes = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) {
                if let last = weighed, last.part == part, Date().timeIntervalSince(last.at) >= 30 {
                    let rate = Double(bytes - last.bytes) * 8 / Date().timeIntervalSince(last.at)
                    heavy = rate > ScreenTrack.heavy ? heavy + 1 : 0
                    weighed = (part, bytes, Date())
                    if heavy >= 2, let position = position(at: Self.now()) {
                        recorderLog.notice("The recorded picture is heavy; capping its bit rate")
                        queue.async {
                            self.track.capped = true
                            self.track.close(at: position)
                        }
                    }
                } else if weighed?.part != part {
                    weighed = (part, bytes, Date())
                    heavy = 0
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
            // A window that went blank may say nothing more until it shows again.
            if let position = position(at: Self.now()) { queue.async { self.checkHidden(at: position) } }
            await stop.wait(timeout: 1)
        }
        // The part is closed on the queue; no frame reaches the track after this.
        await end()
        await track.finish(at: nil)
    }

    /// Whether two shapes differ by more than rounding.
    static func differs(_ size: CGSize, from other: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, other.width > 0, other.height > 0 else { return false }
        let ratio = (size.width / size.height) / (other.width / other.height)
        return abs(ratio - 1) > 0.02
    }

    /// The window as large as the picture allows, in its middle: on its own ScreenCaptureKit puts
    /// a window of another shape in the top left corner.
    static func placement(of size: CGSize, width: Int = ScreenTrack.width, height: Int = ScreenTrack.height) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard size.width > 0, size.height > 0 else { return full }
        let scale = min(Double(width) / size.width, Double(height) / size.height)
        let fitted = CGSize(width: min(Double(width), (size.width * scale / 2).rounded() * 2),
                            height: min(Double(height), (size.height * scale / 2).rounded() * 2))
        return CGRect(x: ((Double(width) - fitted.width) / 2).rounded(), y: ((Double(height) - fitted.height) / 2).rounded(),
                      width: fitted.width, height: fitted.height)
    }

    /// The window, or the shared display with the pointer Zoom sends, as large as the picture allows.
    private static func configuration(for size: CGSize, cursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = ScreenTrack.width
        config.height = ScreenTrack.height
        config.destinationRect = placement(of: size)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreenTrack.frameRate))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black
        config.ignoreShadowsSingleWindow = true
        // A window partly off the screen is recorded whole.
        config.ignoreGlobalClipSingleWindow = true
        config.showsCursor = cursor
        config.queueDepth = 6
        return config
    }

    private func start(_ filter: SCContentFilter, size: CGSize, cursor: Bool, stop: StopRequest) async -> SCStream? {
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: size, cursor: cursor), delegate: self)
        fitted.current = size
        reshaped.current = nil
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync {
                current = stream
                hiddenAt = nil
                broken.current = false
                hidden.current = false
                lastDelivery.current = Self.now()
            }
            try await bounded(stop, timeout: 10, onLateResult: { _ in
                // startCapture can finish after cancellation and after the first stop attempt.
                try? await stream.stopCapture()
            }) { try await stream.startCapture() }
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
