import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

// macOS 15+. Record Zoom's output plus the default microphone while Zoom is unmuted.
// Build with build.sh so macOS sees the privacy descriptions in Info.plist.

let recorderLog = Logger(subsystem: "local.zoom-audio-recorder", category: "capture")

enum RecorderError: Error, LocalizedError {
    case message(String)
    case noAudio
    var errorDescription: String? {
        switch self {
        case let .message(value): return value
        case .noAudio: return "Звук не получен. Войдите в созвон Zoom и проверьте индикатор микрофона."
        }
    }
}

private let screenAccessHint = "Разрешите Zoom Audio Recorder «Запись экрана и системного звука» в Системных настройках и перезапустите приложение."

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.withLock { done } }
    @discardableResult
    func run(_ body: () -> Void) -> Bool {
        let first = lock.withLock { defer { done = true }; return !done }
        if first { body() }
        return first
    }
}

/// Waits for `operation`, but never longer than `seconds`: a hung system service
/// must not keep captured audio from being saved.
func waitAtMost(_ seconds: Double, _ operation: @escaping () async -> Void) async {
    let once = Once()
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        Task {
            await operation()
            once.run { finished.resume() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.run { finished.resume() } }
    }
}

/// Runs `operation`, but gives up when Stop is pressed or after `timeout`, so a hung
/// ScreenCaptureKit call can never block stopping and saving.
func bounded<T>(_ stop: StopRequest, timeout: TimeInterval? = nil,
                onLateResult: @escaping (T) async -> Void = { _ in },
                _ operation: @escaping () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (result: CheckedContinuation<T, Error>) in
        Task {
            do {
                let value = try await operation()
                if !once.run({ result.resume(returning: value) }) { await onLateResult(value) }
            } catch {
                once.run { result.resume(throwing: error) }
            }
        }
        let begun = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler {
            if stop.isRequested {
                once.run { result.resume(throwing: CancellationError()) }
            } else if let timeout, Date().timeIntervalSince(begun) > timeout {
                once.run { result.resume(throwing: RecorderError.message("Zoom не отвечает")) }
            }
            if once.isDone { timer.cancel() }
        }
        timer.resume()
    }
}

/// Flushes a file to permanent storage, so it survives power loss.
func syncToStorage(_ url: URL) {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
    close(descriptor)
}

extension AVAudioPCMBuffer {
    /// The frames after the first `count`, or nil when nothing is left.
    func dropping(frames count: Int64) -> AVAudioPCMBuffer? {
        guard count < Int64(frameLength) else { return nil }
        let rest = AVAudioFrameCount(Int64(frameLength) - count)
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: rest) else { return nil }
        copy.frameLength = rest
        let frameBytes = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let from = from.mData, let to = to.mData else { return nil }
            memcpy(to, from + Int(count) * frameBytes, Int(rest) * frameBytes)
        }
        return copy
    }

    func silence() {
        for buffer in UnsafeMutableAudioBufferListPointer(mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}

/// Converts any linear PCM buffer to one fixed format, so switching microphones or
/// a sample-rate change in the middle of a meeting never breaks the encoder.
final class PCMNormalizer {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(channels: AVAudioChannelCount) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioTrack.rate,
                               channels: channels, interleaved: true)!
    }

    func convert(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample),
              var stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM, stream.mChannelsPerFrame > 0,
              let source = Self.format(&stream),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
            throw RecorderError.message("Неизвестный формат звука")
        }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: input.mutableAudioBufferList) == noErr else {
            throw RecorderError.message("Не удалось прочитать звуковой буфер")
        }
        guard let output = mix(try resample(input)) else { throw RecorderError.message("Не удалось преобразовать звук") }
        return output
    }

    /// The sample's own format. Its channel layout is ignored on purpose: devices often
    /// describe inputs as discrete or unknown, and AVAudioConverter mixes those to silence.
    private static func format(_ stream: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        guard stream.mChannelsPerFrame > 2 else { return AVAudioFormat(streamDescription: &stream) }
        return AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stream.mChannelsPerFrame)
            .flatMap { AVAudioFormat(streamDescription: &stream, channelLayout: $0) }
    }

    /// 48 kHz planar Float32, every channel kept one to one.
    private func resample(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        var planar = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: input.format.channelCount, mBitsPerChannel: 32, mReserved: 0)
        guard let target = Self.format(&planar) else { throw RecorderError.message("Неизвестный формат звука") }
        if input.format == target { return input }
        if converter?.inputFormat != input.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw RecorderError.message("Не удалось преобразовать звук")
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed {
                state.pointee = .noDataNow
                return nil
            }
            consumed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error else { throw error ?? RecorderError.message("Не удалось преобразовать звук") }
        return output
    }

    /// Mono takes the average of the first two channels, so a microphone on either input
    /// is heard; stereo takes the first two channels, a mono source on both.
    private func mix(_ planar: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(planar.frameLength)
        let sources = Int(planar.format.channelCount)
        let targets = Int(format.channelCount)
        guard let input = planar.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let mixed = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        if targets == 1 {
            let used = min(sources, 2)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += input[channel][frame] }
                mixed[frame] = sum / Float(used)
            }
        } else {
            for frame in 0..<frames {
                for channel in 0..<targets { mixed[frame * targets + channel] = input[min(channel, sources - 1)][frame] }
            }
        }
        return output
    }

    /// Silence as long as `sample`. The sample's audio is never read.
    func silence(like sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Drop resampler history so muted speech cannot leak into the next audible buffer.
        converter?.reset()
        let rate = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? format.sampleRate
        let frames = (Double(CMSampleBufferGetNumSamples(sample)) * format.sampleRate / max(rate, 1)).rounded()
        return Self.silence(format: format, frames: Int64(frames))
    }

    static func silence(format: AVAudioFormat, frames: Int64) -> AVAudioPCMBuffer? {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.silence()
        return buffer
    }
}

struct TrackPart: Equatable {
    let url: URL
    /// Offset on the session timeline, in 48 kHz frames.
    let start: Int64
}

/// One recorded track, written as crash-safe fragmented M4A parts.
/// Positions are 48 kHz frames on the session timeline. AAC encoding collapses missing
/// time, so short gaps are filled with silence and long gaps start a new part at its
/// offset: the tracks never drift apart. After a crash every part stays readable up
/// to its last one-second fragment.
final class AudioTrack {
    static let rate = 48_000.0
    static let tolerance: Int64 = 960
    static let longGap: Int64 = 480_000
    static let maxParts = 10_000
    let name: String
    let directory: URL
    let format: AVAudioFormat
    private let bitRate: Int
    private let realtime: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var start: Int64 = 0
    private var length: Int64 = 0
    private var pending: [(buffer: AVAudioPCMBuffer, frame: Int64)] = []
    private var pendingFrames: Int64 = 0
    private let closing = DispatchGroup()
    private var retryAt = Date.distantPast
    private var retryDelay = 5.0
    private(set) var parts: [URL] = []
    private(set) var failure: Error?
    private(set) var failures = 0

    var currentPart: URL? { writer == nil ? nil : parts.last }
    var end: Int64? { writer == nil ? nil : start + length }

    init(name: String, directory: URL, channels: AVAudioChannelCount, bitRate: Int = 128_000, realtime: Bool = true) {
        self.name = name
        self.directory = directory
        self.bitRate = bitRate
        self.realtime = realtime
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
                               channels: channels, interleaved: true)!
    }

    static func parts(named name: String, in directory: URL) -> [TrackPart] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> TrackPart? in
            let fields = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard url.pathExtension == "m4a", fields.count == 3, fields[0] == name,
                  Int(fields[1]) != nil, let start = Int64(fields[2]) else { return nil }
            return TrackPart(url: url, start: start)
        }.sorted { $0.start < $1.start }
    }

    /// Appends normalized PCM at an absolute timeline position. Use one serial queue.
    func append(_ buffer: AVAudioPCMBuffer, at position: Int64) {
        guard buffer.frameLength > 0 else { return }
        var buffer = buffer
        var position = position
        if let end {
            let gap = position - end
            if gap > Self.longGap {
                closePart()
            } else if gap > Self.tolerance {
                var left = gap
                while left > 0, let quiet = PCMNormalizer.silence(format: format, frames: min(left, 48_000)) {
                    enqueue(quiet)
                    left -= Int64(quiet.frameLength)
                }
            } else if gap < -Self.tolerance {
                guard let rest = buffer.dropping(frames: -gap) else { return }
                buffer = rest
            }
        }
        if writer == nil {
            if position < 0 {
                guard let rest = buffer.dropping(frames: -position) else { return }
                buffer = rest
                position = 0
            }
            guard openPart(at: position) else { return }
        }
        enqueue(buffer)
        drain()
    }

    /// Writes everything still queued, closes every part and flushes the files to
    /// storage. Call after the last append.
    func finish() async {
        closePart()
        let closing = closing
        await waitAtMost(120) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                closing.notify(queue: .global()) { done.resume() }
            }
        }
        // finishWriting rewrites each file's header in place; persist it.
        parts.forEach(syncToStorage)
    }

    private func openPart(at position: Int64) -> Bool {
        // A failing disk must not produce a new empty file for every buffer.
        guard Date() >= retryAt else { return false }
        guard parts.count < Self.maxParts else {
            if retryAt != .distantFuture {
                retryAt = .distantFuture
                record(RecorderError.message("Слишком много ошибок записи — дорожка «\(name)» остановлена"))
            }
            return false
        }
        let url = directory.appendingPathComponent("\(name)-\(parts.count + 1)-\(position).m4a")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.rate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: bitRate
            ], sourceFormatHint: format.formatDescription)
            input.expectsMediaDataInRealTime = realtime
            guard writer.canAdd(input) else { throw RecorderError.message("Не удалось добавить звуковую дорожку") }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? RecorderError.message("Не удалось начать запись звука")
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            parts.append(url)
            start = position
            length = 0
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        pending.append((buffer, length))
        pendingFrames += Int64(buffer.frameLength)
        length += Int64(buffer.frameLength)
    }

    private func drain() {
        guard let writer, let input else { return }
        while let next = pending.first, writer.status == .writing, input.isReadyForMoreMediaData {
            pending.removeFirst()
            pendingFrames -= Int64(next.buffer.frameLength)
            do {
                guard input.append(try sampleBuffer(next.buffer, at: next.frame)) else {
                    throw writer.error ?? RecorderError.message("Не удалось записать звук")
                }
            } catch {
                return fail(error)
            }
            // Only a part that has really been writing resets the back-off.
            if next.frame >= Int64(Self.rate * 10) { retryDelay = 5 }
        }
        if writer.status == .failed {
            fail(writer.error ?? RecorderError.message("Не удалось записать звук"))
        } else if pendingFrames > Int64(Self.rate * 30) {
            fail(RecorderError.message("Кодировщик звука перестал принимать данные"))
        }
    }

    private func record(_ error: Error) {
        recorderLog.error("\(self.name, privacy: .public) track: \(error.localizedDescription, privacy: .public)")
        failure = error
        failures += 1
    }

    private func fail(_ error: Error) {
        record(error)
        // Back off: a full disk or a broken encoder would fail again right away.
        retryAt = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 60)
        // Fragments already on disk stay readable; the next buffer starts a new part.
        closePart(keepingQueued: false)
    }

    /// Closes the current part. Audio still queued for it is handed over and written in
    /// the background before the file is finished, so closing never drops audio.
    private func closePart(keepingQueued: Bool = true) {
        if let writer, let input, writer.status == .writing {
            let queued = Queue(keepingQueued ? pending.compactMap { try? sampleBuffer($0.buffer, at: $0.frame) } : [])
            closing.enter()
            input.requestMediaDataWhenReady(on: Self.finishing) { [closing] in
                while input.isReadyForMoreMediaData, writer.status == .writing, let next = queued.next() {
                    if !input.append(next) { break }
                }
                guard queued.isEmpty || writer.status != .writing, queued.close() else { return }
                input.markAsFinished()
                if writer.status == .writing {
                    writer.finishWriting { closing.leave() }
                } else {
                    closing.leave()
                }
            }
        }
        writer = nil
        input = nil
        pending.removeAll()
        pendingFrames = 0
    }

    private static let finishing = DispatchQueue(label: "zoom-audio.finishing")

    /// Samples handed over to a closing part; closed exactly once.
    private final class Queue: @unchecked Sendable {
        private var samples: ArraySlice<CMSampleBuffer>
        private var closed = false
        init(_ samples: [CMSampleBuffer]) { self.samples = samples[...] }
        var isEmpty: Bool { samples.isEmpty }
        func next() -> CMSampleBuffer? { samples.popFirst() }
        func close() -> Bool {
            defer { closed = true }
            return !closed
        }
    }

    private func sampleBuffer(_ buffer: AVAudioPCMBuffer, at frame: Int64) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(Self.rate)),
                                        presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(Self.rate)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buffer.audioBufferList) == noErr else {
            throw RecorderError.message("Не удалось подготовить звуковой буфер")
        }
        return sample
    }
}

/// Wakes the recording loop: the user pressed Stop, the stream broke, or a timeout passed.
/// Spurious wake-ups are harmless because the loop re-checks its state.
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested = false
    private var signaled = false
    private var generation: UInt64 = 0

    var isRequested: Bool { lock.withLock { requested } }

    func wait(timeout: TimeInterval? = nil) async {
        await withCheckedContinuation { next in
            lock.lock()
            generation &+= 1
            let waiting = generation
            if requested || signaled {
                signaled = false
                lock.unlock()
                next.resume()
            } else {
                continuation = next
                lock.unlock()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.timeout(waiting)
                    }
                }
            }
        }
    }

    /// An old deadline must never wake a later wait after a stream error woke this one.
    private func timeout(_ waiting: UInt64) {
        lock.lock()
        guard generation == waiting, let next = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        next.resume()
    }

    func stop() {
        lock.lock()
        requested = true
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume()
    }

    func signal() {
        lock.lock()
        let next = continuation
        continuation = nil
        signaled = next == nil
        lock.unlock()
        next?.resume()
    }
}

// Zoom has no public mute-state API for an external recorder. Read the action
// of its own mute button through macOS Accessibility. Unknown means muted.
enum ZoomMuteState { case muted, unmuted, unavailable }

struct ZoomMuteLabels {
    var mute = ["mute my audio", "выключить мой звук"]
    var unmute = ["unmute my audio", "включить мой звук"]
    var shortMute = ["mute"]
    var shortUnmute = ["unmute"]
    var ambiguous = ["mute/unmute my audio"]
    var ownActionMute = ["mute audio"]
    var ownActionUnmute = ["unmute audio"]
    /// The muted button's tooltip, split at its hotkey placeholders.
    var unmuteTips = ["Press (%1$@) to unmute or hold (%2$@) to temporarily unmute.",
                      "Press %@ to unmute or hold space bar to temporarily unmute."].map(Self.fragments)

    /// Adds one of Zoom's localizations. A long label that equals the short Mute or
    /// Unmute word (as in Chinese) would match participant buttons, so it stays short.
    mutating func add(localization strings: [String: String]) {
        func value(_ key: String) -> String? {
            strings[key].map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let text = value("Mute") { shortMute.append(text) }
        if let text = value("Unmute") { shortUnmute.append(text) }
        let short = Set(shortMute + shortUnmute)
        if let text = value("Mute My Audio"), !short.contains(text) { mute.append(text) }
        if let text = value("Unmute My Audio"), !short.contains(text) { unmute.append(text) }
        if let text = value("LN_Hotkey_Mute_Audio_123974") { ambiguous.append(text) }
        if let text = value("Mute Audio") { ownActionMute.append(text) }
        if let text = value("Unmute Audio") { ownActionUnmute.append(text) }
        for key in ["LN_Unmute_Audio_Tip_803981", "LN_Unmute_Audio_Button_Tip_542"] {
            if let text = value(key) { unmuteTips.append(Self.fragments(text)) }
        }
    }

    /// The state shown by the tooltip of the user's own mute button, which Zoom updates
    /// about 0.1 s after a click, long before the button's label: "Noise removal is on.
    /// Mute my audio (⇧⌘A)" or "Press (⇧⌘A) to unmute or hold (Space) to temporarily unmute."
    func tipState(_ help: String) -> ZoomMuteState? {
        let text = help.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if unmuteTips.contains(where: { Self.follows(text, $0) }) { return .muted }
        // Otherwise the last sentence names the action, optionally followed by its hotkey.
        var action = Substring(text)
        if action.hasSuffix(")"), let hotkey = action.range(of: " (", options: .backwards) {
            action = action[..<hotkey.lowerBound]
        }
        func names(_ label: String) -> Bool {
            action.hasSuffix(label) && action.dropLast(label.count).last.map { !$0.isLetter && !$0.isNumber } != false
        }
        if ambiguous.contains(where: names) { return nil }
        if unmute.contains(where: names) { return .muted }
        if mute.contains(where: names) { return .unmuted }
        return nil
    }

    static func fragments(_ format: String) -> [String] {
        format.lowercased().replacingOccurrences(of: "%\\d+\\$@", with: "%@", options: .regularExpression)
            .components(separatedBy: "%@")
    }

    /// Whether `text` is `fragments` with anything in place of the placeholders.
    static func follows(_ text: String, _ fragments: [String]) -> Bool {
        guard fragments.joined().count >= 12, let first = fragments.first, let last = fragments.last,
              text.count >= first.count + last.count, text.hasPrefix(first), text.hasSuffix(last) else { return false }
        var rest = text.dropFirst(first.count).dropLast(last.count)
        for fragment in fragments.dropFirst().dropLast() {
            guard let range = rest.range(of: fragment) else { return false }
            rest = rest[range.upperBound...]
        }
        return fragments.count > 1 || text == first
    }

    func state(labels: [String], role: String, enabled: Bool,
               inToolbar: Bool = false, identifier: String = "") -> ZoomMuteState? {
        guard enabled, ["AXButton", "AXCheckBox", "AXMenuItem"].contains(role) else { return nil }
        let texts = labels.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { text in !ambiguous.contains { Self.matches(text, $0) } }
        let ownAudioCommand = identifier == "onMuteAudio:"
        // Menu command selectors identify the user's microphone across localizations.
        // Exclude participant commands and recent-file entries with similar titles.
        if role == "AXMenuItem", !identifier.isEmpty, !ownAudioCommand { return nil }
        if ownAudioCommand, let state = Self.state(texts, mute: ownActionMute, unmute: ownActionUnmute) { return state }
        // Prefer the current action title over a generic shortcut/help description.
        if let state = Self.state(texts, mute: mute, unmute: unmute) { return state }
        // A generic participant button must never enable our own microphone.
        guard inToolbar, role != "AXMenuItem" else { return nil }
        return Self.state(texts, mute: shortMute, unmute: shortUnmute)
    }

    /// Whole labels only, optionally followed by a hotkey: in some languages the
    /// Mute title contains the Unmute title ("disattiva audio" ⊃ "attiva audio").
    static func matches(_ text: String, _ label: String) -> Bool {
        text == label || text.hasPrefix(label + " (") || text.hasPrefix(label + " [") || text.hasPrefix(label + "\t")
    }

    private static func state(_ texts: [String], mute: [String], unmute: [String]) -> ZoomMuteState? {
        for text in texts {
            if unmute.contains(where: { matches(text, $0) }) { return .muted }
            if mute.contains(where: { matches(text, $0) }) { return .unmuted }
        }
        return nil
    }
}

/// Zoom refreshes each of its mute indicators on its own schedule. After a click the
/// button's tooltip changes within 0.15 s, the menu command within a second (at once for
/// its hotkey), the button's label after about a second. Each refresh shows the current
/// state, so the newest change is the state. An indicator that has not changed may be
/// stale: the tooltip, for instance, only refreshes while the pointer is on the button.
struct MuteIndicators {
    /// Freshest first.
    enum Kind: CaseIterable { case tip, menu, label }
    /// Longer than the menu command and the label take to refresh.
    static let staleness = 2.0
    private var shown: [Kind: ZoomMuteState] = [:]
    private var state: ZoomMuteState?
    private var disagreeing: Double?

    mutating func update(_ now: [Kind: ZoomMuteState], at time: Double) -> ZoomMuteState {
        defer { shown = now }
        if let changed = Kind.allCases.first(where: { now[$0] != nil && shown[$0] != nil && now[$0] != shown[$0] }) {
            state = now[changed]
        } else if let state, now.isEmpty || now.values.contains(state) {
            // Unchanged; an indicator still showing the previous state is stale.
        } else {
            // A first reading, controls that came back showing another state, or every
            // indicator disagreeing for too long: trust the ones that are never stale for long.
            let since = disagreeing ?? time
            if state == nil || now.keys.contains(where: { shown[$0] == nil }) || time - since > Self.staleness {
                state = [Kind.menu, .label, .tip].lazy.compactMap { now[$0] }.first
            }
        }
        if now.isEmpty { state = nil }
        disagreeing = state.map(now.values.contains) == false ? disagreeing ?? time : nil
        return state ?? .unavailable
    }
}

private final class ZoomMuteWatcher {
    private enum Reading { case found(label: ZoomMuteState, tip: ZoomMuteState?), none, busy }
    private struct Control {
        let element: AXUIElement
        let inToolbar: Bool
        let isMenu: Bool
    }
    private enum Search { case found(Control, label: ZoomMuteState, tip: ZoomMuteState?), none, busy }
    private static let attributes = [kAXRoleAttribute, kAXEnabledAttribute, kAXTitleAttribute,
                                     kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] as CFArray
    private let application: AXUIElement
    private let queue = DispatchQueue(label: "zoom-audio.mute")
    private let lock = NSLock()
    private var history: [(time: Double, unmuted: Bool)] = []
    private var lastScan = -Double.infinity
    private var lastReported: ZoomMuteState?
    private var controlSeen = false
    private var timer: DispatchSourceTimer?
    private let onChange: (ZoomMuteState) -> Void
    private var labels = ZoomMuteLabels()
    /// Zoom's own menu command and meeting button, once found.
    private var controls: [Control] = []
    private var indicators = MuteIndicators()

    init(pid: pid_t, bundleURL: URL?, onChange: @escaping (ZoomMuteState) -> Void) {
        application = AXUIElementCreateApplication(pid)
        self.onChange = onChange
        // Child elements use the process-wide timeout: a hung Zoom must not stall polling.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        AXUIElementSetMessagingTimeout(application, 0.2)
        if let bundleURL, let bundle = Bundle(url: bundleURL) {
            for language in bundle.localizations {
                guard let path = bundle.path(forResource: "Localizable", ofType: "strings",
                                              inDirectory: nil, forLocalization: language),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
                labels.add(localization: strings)
            }
        }
    }

    /// Whether Zoom's microphone control has been found, and whether it is missing now.
    var control: (seen: Bool, missing: Bool) { lock.withLock { (controlSeen, lastReported == .unavailable) } }

    /// Readings from just before `time` on, for deciding captured microphone audio.
    func timeline(from time: Double) -> MuteTimeline {
        lock.withLock {
            let first = history.lastIndex { $0.time < time } ?? history.startIndex
            return MuteTimeline(readings: Array(history[first...]))
        }
    }

    private static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Polls every 20 ms: each known control is read in a single round trip, so a change
    /// is seen within one polling interval of Zoom showing it.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    /// One last reading after any poll still in flight, so the final moments of
    /// speech are decided before the recording closes.
    func finalReading() {
        timer?.cancel()
        queue.sync { refresh() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh() {
        let begun = Self.now()
        // No answer means Zoom's main thread is busy, and its mute state cannot change
        // until it answers again: the previous reading still holds.
        guard let next = currentState() else { return }
        // The state was seen somewhere during the read: "on" counts from its start and
        // "off" from its end, so a slow answer never shortens the user's voice.
        let time = next == .unmuted ? begun : Self.now()
        lock.lock()
        history.append((time, next == .unmuted))
        if history.count > 6_000 { history.removeFirst(3_000) }
        let changed = next != lastReported
        lastReported = next
        controlSeen = controlSeen || next != .unavailable
        lock.unlock()
        if changed { onChange(next) }
    }

    /// nil when Zoom did not answer in time.
    private func currentState() -> ZoomMuteState? {
        var shown: [MuteIndicators.Kind: ZoomMuteState] = [:]
        let previous = controls.count
        var kept: [Control] = []
        for control in controls {
            switch reading(of: control.element, inToolbar: control.inToolbar) {
            case let .found(label, tip):
                kept.append(control)
                shown[control.isMenu ? .menu : .label] = label
                if let tip { shown[.tip] = tip }
            case .busy: return nil
            case .none: continue
            }
        }
        controls = kept
        // Look for a missing control at once when the last one vanished, every second while
        // none is found, and otherwise every ten seconds: a scan loads Zoom's main thread.
        let time = Self.now()
        let missingMenu = !controls.contains(where: \.isMenu)
        let missingButton = !controls.contains { !$0.isMenu }
        if missingMenu || missingButton,
           (previous > 0 && controls.isEmpty) || time - lastScan >= (controls.isEmpty ? 1 : 10) {
            lastScan = time
            var budget = 2000
            var roots: [AXUIElement] = []
            // The own-audio menu command is available even when meeting controls are hidden.
            if missingMenu, let menu = attribute(kAXMenuBarAttribute as CFString, of: application),
               CFGetTypeID(menu) == AXUIElementGetTypeID() {
                roots.append(unsafeBitCast(menu, to: AXUIElement.self))
            }
            if missingButton {
                roots += attribute(kAXWindowsAttribute as CFString, of: application) as? [AXUIElement] ?? []
            }
            for root in roots {
                switch findMuteControl(in: root, depth: 0, inToolbar: false, remaining: &budget) {
                case let .found(control, label, tip):
                    guard control.isMenu ? missingMenu : missingButton, shown[control.isMenu ? .menu : .label] == nil else { continue }
                    controls.append(control)
                    shown[control.isMenu ? .menu : .label] = label
                    if let tip { shown[.tip] = tip }
                case .busy: return nil
                case .none: continue
                }
            }
        }
        return indicators.update(shown, at: time)
    }

    /// Reads one control in a single round trip: its label, and a button's tooltip.
    private func reading(of element: AXUIElement, inToolbar: Bool) -> Reading {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if error == .cannotComplete { return .busy }
        guard error == .success, let array = values as? [AnyObject], array.count == 6 else { return .none }
        // Attributes a control lacks come back as error values.
        let value = { (index: Int) -> AnyObject? in
            CFGetTypeID(array[index]) == AXValueGetTypeID() ? nil : array[index]
        }
        let role = value(0) as? String ?? ""
        guard ["AXButton", "AXCheckBox", "AXMenuItem"].contains(role) else { return .none }
        // Disabled menu items exist before joining a meeting and must be ignored.
        let enabled = value(1) as? Bool
        guard enabled != false, role != "AXMenuItem" || enabled == true else { return .none }
        let text = [2, 3, 4].compactMap { value($0) as? String }
        let identifier = value(5) as? String ?? ""
        guard let label = labels.state(labels: text, role: role, enabled: true, inToolbar: inToolbar, identifier: identifier) else {
            return .none
        }
        let tip = role == "AXMenuItem" ? nil : (value(4) as? String).flatMap(labels.tipState)
        return .found(label: label, tip: tip)
    }

    private func findMuteControl(in element: AXUIElement, depth: Int, inToolbar: Bool,
                                 remaining: inout Int) -> Search {
        guard depth < 24, remaining > 0 else { return .none }
        remaining -= 1
        let role = attribute(kAXRoleAttribute as CFString, of: element) as? String ?? ""
        let toolbar = inToolbar || role == "AXToolbar"
        switch reading(of: element, inToolbar: toolbar) {
        case let .found(label, tip):
            return .found(Control(element: element, inToolbar: toolbar, isMenu: role == "AXMenuItem"), label: label, tip: tip)
        case .busy:
            return .busy
        case .none:
            break
        }
        guard let children = attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] else {
            return .none
        }
        for child in children {
            let found = findMuteControl(in: child, depth: depth + 1, inToolbar: toolbar, remaining: &remaining)
            if case .none = found {
                if remaining <= 0 { break }
                continue
            }
            return found
        }
        return .none
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    func diagnosticSnapshot() -> [String: Any] {
        var controls = [[String: Any]]()
        var budget = 1500
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 24, budget > 0 else { return }
            budget -= 1
            let role = attribute(kAXRoleAttribute as CFString, of: element) as? String ?? ""
            if ["AXButton", "AXCheckBox", "AXMenuItem"].contains(role) {
                let title = attribute(kAXTitleAttribute as CFString, of: element) as? String ?? ""
                let description = attribute(kAXDescriptionAttribute as CFString, of: element) as? String ?? ""
                let help = attribute(kAXHelpAttribute as CFString, of: element) as? String ?? ""
                let text = (title + " " + description + " " + help).lowercased()
                if ["audio", "mute", "микроф", "мой звук"].contains(where: text.contains) {
                    controls.append(["role": role, "title": title, "description": description,
                        "help": help, "enabled": attribute(kAXEnabledAttribute as CFString, of: element) as? Bool ?? false,
                        "identifier": attribute(kAXIdentifierAttribute as CFString, of: element) as? String ?? "",
                        "value": String(describing: attribute(kAXValueAttribute as CFString, of: element) ?? "" as CFString)])
                }
            }
            let children = attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] ?? []
            for child in children { visit(child, depth: depth + 1) }
        }
        if let menu = attribute(kAXMenuBarAttribute as CFString, of: application),
           CFGetTypeID(menu) == AXUIElementGetTypeID() { visit(unsafeBitCast(menu, to: AXUIElement.self), depth: 0) }
        for window in attribute(kAXWindowsAttribute as CFString, of: application) as? [AXUIElement] ?? [] {
            visit(window, depth: 0)
        }
        return ["state": String(describing: observedState()), "controls": controls]
    }
    func observedState() -> ZoomMuteState { currentState() ?? .unavailable }
}

func zoomMicrophoneDiagnostics(observations: Int = 1) async -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["accessAllowed": false] }
    guard let zoom = ZoomAudio.runningZoom() else {
        return ["accessAllowed": true, "zoomRunning": false]
    }
    let watcher = ZoomMuteWatcher(pid: zoom.processIdentifier, bundleURL: zoom.bundleURL, onChange: { _ in })
    var result = watcher.diagnosticSnapshot()
    result["accessAllowed"] = true
    result["zoomRunning"] = true
    result["zoomPID"] = zoom.processIdentifier
    if CGPreflightScreenCaptureAccess(),
       let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
        if let target = ZoomAudio.captureApplication(in: content, pid: zoom.processIdentifier) {
            result["captureApplication"] = target.bundleIdentifier
            result["capturePID"] = target.processID
        } else {
            result["captureApplication"] = "unavailable"
        }
    }
    if observations > 1 {
        let start = Date()
        var readings = [[String: Any]]()
        for _ in 0..<min(observations, 150) {
            readings.append(["seconds": Date().timeIntervalSince(start),
                "state": String(describing: watcher.observedState())])
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        result["observations"] = readings
    }
    return result
}

/// Zoom mute readings on the host clock, and the rule that turns them into the parts of
/// the microphone recording that are the user's voice. Between two readings that agree,
/// their state holds: a gap between readings means Zoom was busy. Zoom shows a change
/// a little after the click, so voice runs on up to a mute reading and starts `lead`
/// before an unmute reading. No speech is lost at either edge; a little of the muted side
/// is kept instead.
struct MuteTimeline {
    /// Measured from the press to the change being read: up to 0.31 s for a click on
    /// Zoom's button, 0.02 s for its hotkey, 0.38 s for holding Space.
    static let lead = 0.5
    /// Slack between the microphone's clock and Zoom's label.
    static let pad = 0.03
    /// When each poll began, and whether it saw Zoom's microphone on.
    var readings: [(time: Double, unmuted: Bool)] = []

    /// The voice parts of [start, end), or nil while the readings that decide them are
    /// not in yet. `final` decides now and carries the last reading forward.
    func voice(from start: Double, to end: Double, final: Bool = false) -> [Range<Double>]? {
        if !final, (readings.last?.time ?? -.infinity) < end + Self.lead + Self.pad { return nil }
        var spans: [Range<Double>] = []
        var previous: (time: Double, unmuted: Bool)?
        for reading in readings {
            if reading.unmuted {
                let from = previous.flatMap { $0.unmuted ? $0.time : nil } ?? reading.time - Self.lead
                spans.append(from..<reading.time)
            } else if let previous, previous.unmuted {
                spans.append(previous.time..<max(previous.time, reading.time))
            }
            previous = reading
        }
        if final, let last = readings.last, last.unmuted {
            spans.append(last.time..<max(last.time, end))
        }
        var ranges: [Range<Double>] = []
        for span in spans {
            let lower = max(start, span.lowerBound - Self.pad)
            let upper = min(end, span.upperBound + Self.pad)
            guard lower < upper else { continue }
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }
}

/// Receives Zoom audio and the microphone on one serial queue and places both on a
/// shared timeline. Microphone audio is held in memory until the mute readings around
/// the moment it was captured are in; only the frames they place in a period with
/// Zoom's microphone on are written, the rest become silence.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Longest wait for Zoom to answer before held audio is decided anyway.
    static let voiceHold = 10.0
    /// Microphone RMS above this, held for `speechRun`, counts as speech for the safety copy.
    static let speechLevel: Float = 0.02
    static let speechRun = 0.5
    let queue = DispatchQueue(label: "zoom-audio.samples")
    let zoom: AudioTrack
    let mic: AudioTrack
    /// The whole microphone, unmuted: a safety copy in case mute detection fails.
    let raw: AudioTrack
    /// Mute readings from just before the given host time on.
    var muteTimeline: (Double) -> MuteTimeline = { _ in MuteTimeline() }
    /// Whether Zoom's microphone control has been found, and whether it is missing now.
    var control: () -> (seen: Bool, missing: Bool) = { (false, false) }
    /// Speech was silenced while Zoom's control was missing in the middle of a meeting.
    var onUncertainVoice: () -> Void = {}
    /// Zoom's microphone control was found for the first time.
    var onControlSeen: () -> Void = {}
    var onVoice: () -> Void = {}
    var onProblem: (String) -> Void = { _ in }
    weak var wake: StopRequest?
    var current: SCStream?
    /// Host clock; tests substitute a simulated one.
    var now: () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    private let zoomPCM = PCMNormalizer(channels: 2)
    private let micPCM = PCMNormalizer(channels: 1)
    private var origin: (pts: CMTime, host: CMTime)?
    private var anchors: [SCStreamOutputType: Int64] = [:]
    private var expected: [SCStreamOutputType: Int64] = [:]
    private var voice: [(buffer: AVAudioPCMBuffer, position: Int64, captured: Double, arrival: Double, speech: Bool)] = []
    private var speechSeconds = 0.0
    private var speechRun = 0.0
    private var missingSpeech = 0.0
    private var uncertainSeconds = 0.0
    private(set) var uncertainVoice = false
    private(set) var controlSeen = false
    private var streamError: Error?
    private var reportedFailures = (zoom: 0, mic: 0)
    private var lastProblem: String?
    private(set) var hadVoice = false
    /// Whether Zoom audio has arrived since the current stream started.
    private(set) var receivingZoom = false

    init(directory: URL, realtime: Bool = true) {
        zoom = AudioTrack(name: "zoom", directory: directory, channels: 2, realtime: realtime)
        mic = AudioTrack(name: "mic", directory: directory, channels: 1, bitRate: 96_000, realtime: realtime)
        raw = AudioTrack(name: "raw", directory: directory, channels: 1, bitRate: 64_000, realtime: realtime)
    }

    /// Speech that may be the user's voice did not reach the recording: Zoom's control
    /// vanished mid-meeting while they talked, or was never found at all.
    var needsSafetyCopy: Bool { uncertainVoice || (!controlSeen && speechSeconds > 10) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === current else { return }
        receive(sampleBuffer, of: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.current else { return }
            recorderLog.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
            self.streamError = error
            self.wake?.signal()
        }
    }

    func receive(_ sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        let position = position(of: sample, type: type)
        switch type {
        case .audio:
            receivingZoom = true
            do { zoom.append(try zoomPCM.convert(sample), at: position) }
            catch { report("Звук Zoom: \(error.localizedDescription)") }
        case .microphone:
            receiveVoice(sample, at: position)
        default:
            return
        }
        if zoom.failures > reportedFailures.zoom {
            reportedFailures.zoom = zoom.failures
            report("Ошибка записи звука Zoom: \(zoom.failure?.localizedDescription ?? "неизвестно")")
        }
        if mic.failures + raw.failures > reportedFailures.mic {
            reportedFailures.mic = mic.failures + raw.failures
            report("Ошибка записи микрофона: \((mic.failure ?? raw.failure)?.localizedDescription ?? "неизвестно")")
        }
    }

    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        onProblem(problem)
    }

    /// Writes held microphone audio in order, each buffer once the readings around it
    /// are in. Frames outside the user's voice are silenced first.
    func releaseVoice(flushing: Bool = false) {
        guard let first = voice.first else { return }
        let now = now().seconds
        let timeline = muteTimeline(first.captured - 1)
        while let entry = voice.first {
            let length = Double(entry.buffer.frameLength) / AudioTrack.rate
            let late = flushing || now - entry.arrival > Self.voiceHold
            guard let ranges = timeline.voice(from: entry.captured, to: entry.captured + length, final: late) else { break }
            voice.removeFirst()
            let kept = keep(ranges, of: entry.buffer, capturedAt: entry.captured)
            if kept, !hadVoice {
                hadVoice = true
                onVoice()
            }
            track(speech: entry.speech, kept: kept, length: length)
            mic.append(entry.buffer, at: entry.position)
        }
    }

    /// Counts sustained speech the mute decision silenced. Speech while the control was
    /// missing counts only once the control returns, so recording before joining or
    /// after leaving a meeting does not ask for the safety copy.
    private func track(speech: Bool, kept: Bool, length: Double) {
        let status = control()
        if status.seen, !controlSeen {
            controlSeen = true
            onControlSeen()
        }
        if !status.missing {
            uncertainSeconds += missingSpeech
            missingSpeech = 0
        }
        speechRun = speech ? speechRun + length : 0
        guard speechRun >= Self.speechRun else { return }
        // A run just long enough counts in full.
        let counted = speechRun - length < Self.speechRun ? speechRun : length
        speechSeconds += counted
        if !kept, status.missing, controlSeen { missingSpeech += counted }
        if uncertainSeconds > 3, !uncertainVoice {
            uncertainVoice = true
            onUncertainVoice()
        }
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        return (sum / Float(count)).squareRoot()
    }

    /// Silences every frame outside `ranges`; true when some voice remains.
    private func keep(_ ranges: [Range<Double>], of buffer: AVAudioPCMBuffer, capturedAt start: Double) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        func clear(_ from: Int, _ to: Int) {
            if to > from { memset(samples + from * channels, 0, (to - from) * channels * MemoryLayout<Float>.size) }
        }
        var cursor = 0
        var kept = false
        for range in ranges {
            let from = min(frames, max(cursor, Int(((range.lowerBound - start) * AudioTrack.rate).rounded(.down))))
            let to = min(frames, max(from, Int(((range.upperBound - start) * AudioTrack.rate).rounded(.up))))
            clear(cursor, from)
            kept = kept || to > from
            cursor = max(cursor, to)
        }
        clear(cursor, frames)
        return kept
    }

    func takeStreamError() -> Error? {
        let error = streamError
        streamError = nil
        return error
    }

    /// Prepares for a new stream: its clock may differ from the previous one.
    func attach(_ stream: SCStream?) {
        releaseVoice(flushing: true)
        anchors.removeAll()
        expected.removeAll()
        streamError = nil
        lastProblem = nil
        receivingZoom = false
        current = stream
        if stream == nil {
            muteTimeline = { _ in MuteTimeline() }
            control = { (false, false) }
        }
    }

    private func receiveVoice(_ sample: CMSampleBuffer, at position: Int64) {
        let buffer: AVAudioPCMBuffer
        do {
            buffer = try micPCM.convert(sample)
        } catch {
            report("Микрофон: \(error.localizedDescription)")
            guard let quiet = micPCM.silence(like: sample) else { return }
            buffer = quiet
        }
        if let copy = buffer.dropping(frames: 0) { raw.append(copy, at: position) }
        // Decided by when the audio was captured, never by when it arrived.
        let captured = (origin?.host.seconds ?? now().seconds) + Double(position) / AudioTrack.rate
        voice.append((buffer, position, captured, now().seconds, Self.level(of: buffer) > Self.speechLevel))
        releaseVoice()
    }

    /// Timeline position in 48 kHz frames. Sample clocks are trusted while they run
    /// continuously; only a real clock jump, or a clock ahead of arrival, re-anchors a
    /// stream by arrival time. Late delivery alone never moves audio.
    private func position(of sample: CMSampleBuffer, type: SCStreamOutputType) -> Int64 {
        let rate = AudioTrack.rate
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let sourceRate = CMSampleBufferGetFormatDescription(sample)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? rate
        let duration = Double(CMSampleBufferGetNumSamples(sample)) / max(sourceRate, 1)
        // The origin pairs the first sample's clock with the host time it was captured:
        // the timestamp itself when it is on the host clock, else an estimate from arrival.
        let captured = now() - CMTime(seconds: duration, preferredTimescale: CMTimeScale(rate))
        // Delivery can only lag, so a host-clock timestamp is at most a little ahead of
        // arrival and may be well behind it.
        let hostClock = pts.isNumeric && (pts - captured).seconds < 0.5 && (captured - pts).seconds < 30
        let origin = self.origin ?? (pts.isNumeric ? pts : captured, hostClock ? pts : captured)
        self.origin = origin
        let byArrival = Int64(((captured - origin.host).seconds) * rate)
        guard pts.isNumeric else { return byArrival }
        let byClock = Int64(((pts - origin.pts).seconds * rate).rounded())
        let limit = Int64(2 * rate)
        defer { expected[type] = byClock + Int64((duration * rate).rounded()) }
        if let anchor = anchors[type] {
            let position = byClock + anchor
            if expected[type].map({ abs(byClock - $0) <= limit }) == true {
                // A running clock is trusted: arrival can only lag behind it. A clock ahead
                // of arrival means the origin itself arrived late, so move the origin.
                if position > byArrival + limit {
                    self.origin = (origin.pts, origin.host - CMTime(value: position - byArrival, timescale: CMTimeScale(rate)))
                }
                return position
            }
            if abs(position - byArrival) <= limit { return position }
        }
        // A new stream, or its clock jumped. A clock somewhat behind arrival is late
        // delivery, not a different clock.
        let behind = byArrival - byClock
        let anchor = (-limit...Int64(30 * rate)).contains(behind) ? 0 : behind
        if anchors[type] != nil { recorderLog.notice("Re-anchored \(type.rawValue) clock by \(anchor) frames") }
        anchors[type] = anchor
        return byClock + anchor
    }

    /// Flushes the files being written to permanent storage (survives power loss).
    func syncToDisk() {
        queue.sync { [zoom.currentPart, mic.currentPart, raw.currentPart].compactMap { $0 } }.forEach(syncToStorage)
    }
}

enum RecorderEvent {
    case started
    case reconnecting
    case connected
    case microphone(ZoomMuteState)
    case problem(String)
    case lowDiskSpace(Bool)
    /// False when no Zoom audio arrived for a while after connecting.
    case zoomAudio(Bool)
}

struct RecordingSummary {
    /// Capture actually started (false when cancelled while connecting).
    let started: Bool
    let hasAudio: Bool
    let hasZoom: Bool
    let hasVoice: Bool
    /// Times the connection to Zoom broke and was restored.
    let interruptions: Int
    /// Zoom quit and did not come back, so the recording stopped by itself.
    let zoomQuit: Bool
    /// Deliver the whole microphone too: mute detection may have failed.
    let needsSafetyCopy: Bool
}

struct ZoomAudio {
    /// How long a recording waits for Zoom to come back after it quits or crashes.
    static let zoomReturnTimeout: TimeInterval = 600

    static func captureApplication(in content: SCShareableContent, pid: pid_t) -> SCRunningApplication? {
        // The recorder's own name also contains "Zoom". Never select by display name.
        content.applications.first { $0.bundleIdentifier == "us.zoom.xos" && $0.processID == pid }
    }

    static func runningZoom() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first { !$0.isTerminated }
    }

    /// Checks everything a recording needs before any file is created.
    static func prepare() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecorderError.message(screenAccessHint)
        }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw RecorderError.message("Разрешите Zoom Audio Recorder доступ в «Универсальный доступ» (в macOS 27 — «Управление устройством и доступ к данным»).")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.message("Разрешите Zoom Audio Recorder доступ к микрофону в Системных настройках.")
        }
        guard runningZoom() != nil else {
            throw RecorderError.message("Откройте Zoom и войдите в созвон")
        }
    }

    /// Records into `directory` until `stop` is requested. A broken stream or a Zoom
    /// restart reconnects automatically; the parts on disk stay aligned throughout.
    static func record(into directory: URL, stop: StopRequest, events: @escaping (RecorderEvent) -> Void,
                       onVoice: @escaping () -> Void, onUncertainVoice: @escaping () -> Void,
                       onControlSeen: @escaping () -> Void) async throws -> RecordingSummary {
        let capture = Capture(directory: directory)
        capture.wake = stop
        capture.onVoice = onVoice
        capture.onUncertainVoice = onUncertainVoice
        capture.onControlSeen = onControlSeen
        capture.onProblem = { events(.problem($0)) }
        var stream: SCStream?
        var watcher: ZoomMuteWatcher?
        var zoom: NSRunningApplication?
        var started = false
        var lostSince: Date?
        var lastSync = Date()
        var lastSpaceCheck = Date.distantPast
        var lowSpace = false
        var interruptions = 0
        var zoomQuit = false
        var connectedAt = Date()
        var zoomAudio = true

        func disconnect() async {
            if let stream { await waitAtMost(5) { try? await stream.stopCapture() } }
            stream = nil
            // Confirm or reject the last moments of speech before the held audio is written.
            watcher?.finalReading()
            capture.queue.sync { capture.attach(nil) }
            watcher?.stop()
            watcher = nil
        }

        while !stop.isRequested {
            if stream == nil {
                do {
                    guard let app = runningZoom() else { throw RecorderError.message("Zoom закрыт") }
                    let connection = try await connect(to: app, capture: capture, stop: stop,
                                                       reconnecting: started, events: events)
                    stream = connection.stream
                    watcher = connection.watcher
                    zoom = app
                    // Cancelled while connecting: nothing was meant to be recorded.
                    if stop.isRequested && !started { break }
                    lostSince = nil
                    if started { interruptions += 1 }
                    events(started ? .connected : .started)
                    started = true
                    connectedAt = Date()
                } catch {
                    recorderLog.error("Connect failed: \(error.localizedDescription, privacy: .public)")
                    guard started else { throw error }
                    let since = lostSince ?? Date()
                    lostSince = since
                    if runningZoom() == nil, Date().timeIntervalSince(since) > zoomReturnTimeout {
                        zoomQuit = true
                        break
                    }
                    await stop.wait(timeout: 2)
                    continue
                }
                continue
            }
            await stop.wait(timeout: 2)
            if stop.isRequested { break }
            if Date().timeIntervalSince(lastSync) >= 10 {
                lastSync = Date()
                capture.syncToDisk()
            }
            if Date().timeIntervalSince(lastSpaceCheck) >= 30 {
                lastSpaceCheck = Date()
                let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? .max
                if (free < 300_000_000) != lowSpace {
                    lowSpace.toggle()
                    events(.lowDiskSpace(lowSpace))
                }
            }
            let receiving = capture.queue.sync { capture.receivingZoom }
            if receiving != zoomAudio, receiving || Date().timeIntervalSince(connectedAt) > 15 {
                zoomAudio = receiving
                events(.zoomAudio(receiving))
            }
            let broken = capture.queue.sync { capture.takeStreamError() } != nil
            if broken || zoom?.isTerminated == true {
                recorderLog.notice("Capture interrupted; reconnecting")
                await disconnect()
                events(.microphone(.unavailable))
                events(.reconnecting)
                lostSince = Date()
            }
        }
        await disconnect()
        async let zoomClosed: Void = capture.zoom.finish()
        async let micClosed: Void = capture.mic.finish()
        async let rawClosed: Void = capture.raw.finish()
        _ = await (zoomClosed, micClosed, rawClosed)
        let hasZoom = !capture.zoom.parts.isEmpty
        let needsSafetyCopy = capture.queue.sync { capture.needsSafetyCopy }
        return RecordingSummary(started: started, hasAudio: hasZoom || capture.hadVoice || needsSafetyCopy, hasZoom: hasZoom,
                                hasVoice: capture.hadVoice, interruptions: interruptions, zoomQuit: zoomQuit,
                                needsSafetyCopy: needsSafetyCopy)
    }

    private static func connect(to app: NSRunningApplication, capture: Capture, stop: StopRequest, reconnecting: Bool,
                                events: @escaping (RecorderEvent) -> Void) async throws -> (stream: SCStream, watcher: ZoomMuteWatcher) {
        // The first connection may wait on a system consent prompt; reconnections may not hang.
        let timeout: TimeInterval? = reconnecting ? 15 : nil
        let content: SCShareableContent
        do {
            content = try await bounded(stop, timeout: timeout) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RecorderError.message("\(screenAccessHint) Системная ошибка: \(error.localizedDescription)")
        }
        guard let zoom = captureApplication(in: content, pid: app.processIdentifier) else {
            throw RecorderError.message("Откройте Zoom и войдите в созвон")
        }
        recorderLog.notice("Recording target: \(zoom.bundleIdentifier, privacy: .public), pid \(zoom.processID)")
        let watcher = ZoomMuteWatcher(pid: app.processIdentifier, bundleURL: app.bundleURL) { state in
            recorderLog.notice("Zoom microphone: \(String(describing: state), privacy: .public)")
            events(.microphone(state))
        }
        // App audio does not depend on the display. Prefer the built-in one, so
        // unplugging an external monitor mid-meeting does not stop the stream.
        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw RecorderError.message("Не найден экран для фильтра ScreenCaptureKit")
        }
        let filter = SCContentFilter(display: display, including: [zoom], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true

        let stream = SCStream(filter: filter, configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.queue)
        try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: capture.queue)
        capture.queue.sync {
            capture.muteTimeline = { watcher.timeline(from: $0) }
            capture.control = { watcher.control }
            capture.attach(stream)
        }
        watcher.start()
        do {
            try await bounded(stop, timeout: timeout, onLateResult: { _ in
                // startCapture can finish after cancellation and after the first stop attempt.
                try? await stream.stopCapture()
            }) { try await stream.startCapture() }
        } catch {
            watcher.stop()
            capture.queue.sync { capture.attach(nil) }
            // A start that finishes late must not leave an orphaned capture running.
            Task { try? await stream.stopCapture() }
            throw error
        }
        return (stream, watcher)
    }
}
