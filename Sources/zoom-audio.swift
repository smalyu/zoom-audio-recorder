import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

// macOS 15+. Record Zoom's output plus the default microphone while Zoom is unmuted.
// Build with build.sh so macOS sees the privacy descriptions in Info.plist.

final class AudioFile {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstTime: CMTime?
    private(set) var failure: Error?
    private let realtime: Bool
    var canAcceptSample: Bool { writer == nil || input?.isReadyForMoreMediaData == true }

    init(url: URL, realtime: Bool = true) { self.url = url; self.realtime = realtime }

    func append(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), failure == nil else { return }
        do {
            if writer == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
                    throw RecorderError.message("Не удалось определить формат звука")
                }
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.pointee.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.pointee.mChannelsPerFrame),
                    AVEncoderBitRateKey: 128_000
                ]
                let newWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
                let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                                                  sourceFormatHint: format)
                newInput.expectsMediaDataInRealTime = realtime
                guard newWriter.canAdd(newInput) else {
                    throw RecorderError.message("Не удалось добавить звуковую дорожку")
                }
                newWriter.add(newInput)
                guard newWriter.startWriting() else {
                    throw newWriter.error ?? RecorderError.message("Не удалось начать запись звука")
                }
                let start = CMSampleBufferGetPresentationTimeStamp(sample)
                newWriter.startSession(atSourceTime: start)
                firstTime = start
                writer = newWriter
                input = newInput
            }
            if let input, input.isReadyForMoreMediaData, !input.append(sample) {
                throw writer?.error ?? RecorderError.message("Не удалось записать звуковой буфер")
            }
        } catch {
            failure = error
        }
    }

    func finish() async throws -> Bool {
        if let failure { throw failure }
        guard let writer, let input else { return false }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.message("Не удалось завершить запись звука")
        }
        return true
    }
}

private enum RecorderError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

private let screenAccessHint = "Разрешите запись экрана и системного аудио для Zoom Audio Recorder: System Settings → Privacy & Security → Screen & System Audio Recording. Затем закройте и откройте приложение заново."

final class StopRequest {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested = false

    func wait() async {
        await withCheckedContinuation { next in
            lock.lock()
            if requested {
                lock.unlock()
                next.resume()
            } else {
                continuation = next
                lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        requested = true
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume()
    }
}

// Zoom has no public mute-state API for an external recorder. Read the action
// of its own mute button through macOS Accessibility. Unknown means muted.
enum ZoomMuteState { case muted, unmuted, unavailable }

private final class ZoomMuteWatcher {
    private let application: AXUIElement
    private let lock = NSLock()
    private var unmuted = false
    private var lastReported: ZoomMuteState?
    private var hasReported = false
    private var timer: DispatchSourceTimer?
    private let onChange: (ZoomMuteState) -> Void
    private var muteLabels = ["mute my audio", "выключить мой звук"]
    private var unmuteLabels = ["unmute my audio", "включить мой звук"]

    init(pid: pid_t, bundleURL: URL?, onChange: @escaping (ZoomMuteState) -> Void) {
        application = AXUIElementCreateApplication(pid)
        self.onChange = onChange
        AXUIElementSetMessagingTimeout(application, 0.2)
        if let bundleURL, let bundle = Bundle(url: bundleURL) {
            for language in bundle.localizations {
                guard let path = bundle.path(forResource: "Localizable", ofType: "strings",
                                              inDirectory: nil, forLocalization: language),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
                if let value = strings["Mute My Audio"] { muteLabels.append(value.lowercased()) }
                if let value = strings["Unmute My Audio"] { unmuteLabels.append(value.lowercased()) }
            }
        }
    }

    var isUnmuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unmuted
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zoom-audio.mute"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh() {
        var budget = 1500
        let next = findMuteAction(in: application, depth: 0, remaining: &budget) ?? .unavailable
        lock.lock()
        unmuted = (next == .unmuted)
        let changed = !hasReported || next != lastReported
        lastReported = next
        hasReported = true
        lock.unlock()
        if changed { onChange(next) }
    }

    private func findMuteAction(in element: AXUIElement, depth: Int, remaining: inout Int) -> ZoomMuteState? {
        guard depth < 12, remaining > 0 else { return nil }
        remaining -= 1
        let role = attribute(kAXRoleAttribute as CFString, of: element) as? String ?? ""
        if role == (kAXButtonRole as String) {
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { attribute($0 as CFString, of: element) as? String }
                .joined(separator: " ").lowercased()
            // The button names the action that a click would perform.
            if unmuteLabels.contains(where: labels.contains) {
                return .muted
            }
            if muteLabels.contains(where: labels.contains) {
                return .unmuted
            }
        }
        guard let children = attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let state = findMuteAction(in: child, depth: depth + 1, remaining: &remaining) { return state }
            if remaining <= 0 { break }
        }
        return nil
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

func silence(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
    guard let source = CMSampleBufferGetDataBuffer(sample),
          let format = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
          asbd.pointee.mFormatID == kAudioFormatLinearPCM else {
        throw RecorderError.message("Не удалось заглушить микрофон: неизвестный формат звука")
    }
    let length = CMBlockBufferGetDataLength(source)
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: length,
        flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw RecorderError.message("Не удалось создать тишину для микрофона") }
    let flags = asbd.pointee.mFormatFlags
    let fill: UInt8 = asbd.pointee.mBitsPerChannel == 8 &&
        flags & (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsFloat) == 0 ? 128 : 0
    status = CMBlockBufferFillDataBytes(with: Int8(bitPattern: fill), blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    guard status == noErr else { throw RecorderError.message("Не удалось заглушить микрофон") }
    var result: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
        dataBuffer: block, formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(sample),
        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
        packetDescriptions: nil, sampleBufferOut: &result)
    guard status == noErr, let result else { throw RecorderError.message("Не удалось сохранить временную шкалу микрофона") }
    return result
}

private final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "zoom-audio.samples")
    let zoom: AudioFile
    let mic: AudioFile
    var muteWatcher: ZoomMuteWatcher?
    var stopRequest: StopRequest?
    private(set) var streamError: Error?
    private(set) var hadUnmutedMicrophone = false

    init(directory: URL) {
        zoom = AudioFile(url: directory.appendingPathComponent("zoom.m4a"))
        mic = AudioFile(url: directory.appendingPathComponent("mic.m4a"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio: zoom.append(sampleBuffer)
        case .microphone:
            if muteWatcher?.isUnmuted == true {
                hadUnmutedMicrophone = true
                mic.append(sampleBuffer)
            } else {
                do { mic.append(try silence(sampleBuffer)) }
                catch {
                    streamError = error
                    stopRequest?.stop()
                }
            }
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamError = error }
        stopRequest?.stop()
    }
}

func saveAudio(zoom: URL, mic: URL?, output: URL, delayMilliseconds: Int) async throws {
    guard let mic else {
        try FileManager.default.copyItem(at: zoom, to: output)
        return
    }
    let composition = AVMutableComposition()
    func insert(_ url: URL, at offsetMilliseconds: Int) async throws -> AVMutableCompositionTrack {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let destination = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.message("Не удалось открыть аудиодорожку для сведения")
        }
        let duration = try await asset.load(.duration)
        let offset = CMTime(value: Int64(offsetMilliseconds), timescale: 1000)
        try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                        of: source, at: offset)
        return destination
    }
    let zoomTrack = try await insert(zoom, at: max(0, -delayMilliseconds))
    let micTrack = try await insert(mic, at: max(0, delayMilliseconds))
    guard let exporter = AVAssetExportSession(asset: composition,
                                              presetName: AVAssetExportPresetAppleM4A) else {
        throw RecorderError.message("Не удалось создать экспорт M4A")
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = [zoomTrack, micTrack].map { track in
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(0.7, at: .zero)
        return parameters
    }
    exporter.audioMix = mix
    try await exporter.export(to: output, as: .m4a)
}

struct RecordingResult {
    let hasMicrophone: Bool
    let warning: String?
}

struct ZoomAudio {

    static func record(stop: StopRequest, output: URL,
                       onStarted: @escaping () -> Void,
                       onMicrophone: @escaping (ZoomMuteState) -> Void) async throws -> RecordingResult {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecorderError.message(screenAccessHint)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let capture = Capture(directory: temporary)
        capture.stopRequest = stop

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw RecorderError.message("\(screenAccessHint) Системная ошибка: \(error.localizedDescription)")
        }
        guard let zoom = content.applications.first(where: {
            $0.bundleIdentifier == "us.zoom.xos" || $0.applicationName.localizedCaseInsensitiveContains("zoom")
        }) else {
            throw RecorderError.message("Откройте Zoom и войдите в созвон перед запуском")
        }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw RecorderError.message("Разрешите доступ для Zoom Audio Recorder: System Settings → Privacy & Security → Accessibility (в новых версиях: Device Control and Data Access). Если приложения нет в списке, нажмите «+» и выберите Zoom Audio Recorder.app.")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.message("Разрешите микрофон для Zoom Audio Recorder в Системных настройках")
        }
        guard let runningZoom = NSRunningApplication.runningApplications(withBundleIdentifier: zoom.bundleIdentifier).first else {
            throw RecorderError.message("Не удалось найти процесс Zoom")
        }
        let watcher = ZoomMuteWatcher(pid: runningZoom.processIdentifier,
                                      bundleURL: runningZoom.bundleURL, onChange: onMicrophone)
        capture.muteWatcher = watcher
        defer { watcher.stop() }
        watcher.start()
        let meetingWindow = content.windows
            .filter { $0.owningApplication?.bundleIdentifier == zoom.bundleIdentifier }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let display = content.displays.first(where: {
            guard let meetingWindow else { return false }
            return $0.frame.intersects(meetingWindow.frame)
        }) ?? content.displays.first else {
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

        try await stream.startCapture()
        onStarted()
        await stop.wait()
        var stopError: Error?
        do { try await stream.stopCapture() }
        catch { stopError = error }
        capture.muteWatcher?.stop()
        // All pending sample callbacks use the same serial queue.
        capture.queue.sync {}
        let interrupted = capture.streamError ?? stopError
        let hasZoom = try await capture.zoom.finish()
        let hasMic = try await capture.mic.finish()
        guard hasZoom else { throw RecorderError.message("Zoom не выдал звук: проверьте вывод аудио и разрешение записи экрана") }
        let difference = hasMic ? Int(((capture.mic.firstTime! - capture.zoom.firstTime!).seconds * 1000).rounded()) : 0
        let completed = output.deletingLastPathComponent()
            .appendingPathComponent(".zoom-recording-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: completed) }
        try await saveAudio(zoom: capture.zoom.url, mic: hasMic ? capture.mic.url : nil,
                            output: completed, delayMilliseconds: difference)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: completed)
        } else {
            try FileManager.default.moveItem(at: completed, to: output)
        }
        return RecordingResult(hasMicrophone: capture.hadUnmutedMicrophone,
            warning: interrupted.map { "Запись прервалась, но полученный звук сохранён. \($0.localizedDescription)" })
    }
}
