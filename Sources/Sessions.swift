import AVFoundation
import Foundation

/// Opens a recording and checks that it plays: exactly one audio track, no video.
@discardableResult
func verifyRecording(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let video = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration).seconds
    guard audio.count == 1, video.isEmpty, duration.isFinite, duration > 0 else {
        throw RecorderError.message("Сохранённый файл не прошёл проверку")
    }
    return duration
}

enum RecordingStorage {
    /// A missing drive is unavailable; an ordinary missing subfolder can be created.
    static func reachable(_ folder: URL) -> Bool {
        var existing = folder.standardizedFileURL
        var directory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: existing.path, isDirectory: &directory),
              existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        return directory.boolValue && existing.path != "/Volumes"
            && FileManager.default.isWritableFile(atPath: existing.path)
    }

    static func probe(_ folder: URL) -> Bool {
        guard reachable(folder) else { return false }
        let test = folder.appendingPathComponent(".zoom-recorder-probe-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: test, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: test) }
            return true
        } catch { return false }
    }
}

struct ExportResult {
    let duration: Double
    /// Parts AVFoundation could not open.
    let unreadable: [URL]
}

/// Mixes `tracks` into stereo AAC at the bit rate they were recorded with, on a background
/// thread, then calls `done` with whether it worked. A packet the decoder rejects, as a
/// power loss can leave behind, costs a quarter second of silence, not the recording.
private func encodeMix(of composition: AVComposition, range: CMTimeRange, tracks: [AVAssetTrack], mix: AVAudioMix,
                       metadata: [AVMetadataItem], to output: URL, progress: @escaping (Double) -> Void,
                       done: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let rate = CMTimeScale(AudioTrack.rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioTrack.rate, channels: 2, interleaved: true)!
        do {
            let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioTrack.rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000], sourceFormatHint: format.formatDescription)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writer.metadata = metadata
            guard writer.startWriting() else { throw writer.error ?? RecorderError.message("Не удалось подготовить сведение") }
            writer.startSession(atSourceTime: .zero)
            defer { if writer.status == .writing { writer.cancelWriting() } }
            let first = CMTimeConvertScale(range.start, timescale: rate, method: .roundHalfAwayFromZero).value
            let end = CMTimeConvertScale(range.duration, timescale: rate, method: .roundHalfAwayFromZero).value
            var written: Int64 = 0
            var retried = false
            func write(_ buffer: AVAudioPCMBuffer) throws {
                while !input.isReadyForMoreMediaData, writer.status == .writing { Thread.sleep(forTimeInterval: 0.005) }
                guard input.append(try buffer.sampleBuffer(at: written)) else {
                    throw writer.error ?? RecorderError.message("Не удалось сохранить запись")
                }
                written += Int64(buffer.frameLength)
            }
            func silence(until frame: Int64) throws {
                while written < frame, let quiet = PCMNormalizer.silence(format: format, frames: min(frame - written, 48_000)) {
                    try write(quiet)
                }
            }
            while written < end {
                let reader = try AVAssetReader(asset: composition)
                reader.timeRange = CMTimeRange(start: CMTime(value: first + written, timescale: rate), end: range.end)
                let mixed = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: format.settings)
                mixed.audioMix = mix
                reader.add(mixed)
                guard reader.startReading() else { throw reader.error ?? RecorderError.message("Не удалось подготовить сведение") }
                let restart = written
                while let sample = mixed.copyNextSampleBuffer() {
                    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
                    buffer.frameLength = frames
                    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                       into: buffer.mutableAudioBufferList) == noErr else {
                        throw RecorderError.message("Не удалось прочитать звуковой буфер")
                    }
                    // Time the mix leaves out stays on the timeline as silence.
                    let start = CMSampleBufferGetPresentationTimeStamp(sample)
                    try silence(until: CMTimeConvertScale(start, timescale: rate, method: .roundHalfAwayFromZero).value - first)
                    try write(buffer)
                    progress(Double(written) / Double(max(end, 1)))
                }
                if reader.status == .completed { break }
                guard (reader.error as? AVError)?.code == .decodeFailed else {
                    throw reader.error ?? RecorderError.message("Не удалось сохранить запись")
                }
                // The decoder fails ahead of what it delivered, at times before delivering
                // anything: read on, and try once more, up to the damage itself.
                guard written == restart, retried else {
                    retried = written == restart
                    continue
                }
                retried = false
                recorderLog.error("Damaged audio at \(Double(written) / AudioTrack.rate, privacy: .public) s skipped")
                try silence(until: written + Int64(AudioTrack.rate / 4))
            }
            input.markAsFinished()
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Не удалось сохранить запись") }
            done(true)
        } catch {
            recorderLog.error("Mix encoder failed, using the export preset: \(error.localizedDescription, privacy: .public)")
            done(false)
        }
    }
}

/// Where the recording has sound: from a second before the first sound to a second after
/// the last, so the wait before a meeting and the silence after it are left out. Found by
/// reading from each end, not the whole recording; the whole range when unsure.
private func findSoundRange(of composition: AVComposition, tracks: [AVAssetTrack], mix: AVAudioMix?,
                            done: @escaping (CMTimeRange) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { done(soundRange(of: composition, tracks: tracks, mix: mix)) }
}

private func soundRange(of composition: AVComposition, tracks: [AVAssetTrack], mix: AVAudioMix?) -> CMTimeRange {
    let whole = CMTimeRange(start: .zero, duration: composition.duration)
    let rate = 16_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: true)!
    /// Seconds into `range` of each loud 0.1 s window, in order; nil if it cannot be read.
    func loud(in range: CMTimeRange, stopAtFirst: Bool) -> [Double]? {
        guard let reader = try? AVAssetReader(asset: composition) else { return nil }
        reader.timeRange = range
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: format.settings)
        output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { return nil }
        var found: [Double] = []
        var window: (sum: Float, count: Int, start: Double) = (0, 0, 0)
        /// Judges the window so far: above -46 dBFS is quiet speech, not the room behind an open microphone.
        func close() {
            if window.count > 0, (window.sum / Float(window.count)).squareRoot() > 0.005 { found.append(window.start) }
            window = (0, 0, 0)
        }
        var next: Double?
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                               into: buffer.mutableAudioBufferList) == noErr else { return nil }
            let time = (CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds
            // The mix leaves out time with no audio at all: a window does not reach across it.
            if let next, abs(time - next) > 1 / rate { close() }
            next = time + Double(frames) / rate
            for index in 0..<frames {
                if window.count == 0 { window.start = time + Double(index) / rate }
                let value = buffer.floatChannelData![0][index]
                window.sum += value * value
                window.count += 1
                guard window.count == Int(rate / 10) else { continue }
                close()
                if stopAtFirst, !found.isEmpty {
                    reader.cancelReading()
                    return found
                }
            }
        }
        close()
        return reader.status == .completed || reader.status == .cancelled ? found : nil
    }
    guard let first = loud(in: whole, stopAtFirst: true)?.first else { return whole }
    let start = max(0, first - 1)
    var last: Double?
    var stretch = 60.0
    var to = whole.duration.seconds
    // Back from the end, a stretch at a time, until the last sound.
    while last == nil, to > first {
        let from = max(first, to - stretch)
        guard let sounds = loud(in: CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000),
                                                end: CMTime(seconds: to, preferredTimescale: 48_000)), stopAtFirst: false) else { return whole }
        last = sounds.last.map { from + $0 + 0.1 }
        to = from
        stretch *= 2
    }
    let end = min(whole.duration.seconds, (last ?? first + 0.1) + 1)
    return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: end, preferredTimescale: 48_000))
}

/// Mixes the recorded parts into one ordinary M4A file and verifies it. Each track's
/// parts are laid out on one composition track at their offsets. Parts cut short by a
/// crash are used up to their last readable fragment. With `trimmed`, the silence before the
/// first sound and after the last is left out; `description`, given where the file starts and
/// ends in the recording, goes into the file's description tag.
@discardableResult
func exportRecording(zoom: [TrackPart], mic: [TrackPart], to output: URL, trimmed: Bool = true,
                     description: (_ start: Double, _ end: Double) -> String? = { _, _ in nil },
                     progress: @escaping (Double) -> Void = { _ in }) async throws -> ExportResult {
    let composition = AVMutableComposition()
    // Assets stay referenced until the export ends: a track does not keep its asset alive.
    var assets: [AVURLAsset] = []
    var tracks: [AVMutableCompositionTrack] = []
    var unreadable: [URL] = []
    var expected = 0.0
    for parts in [zoom, mic] {
        var target: AVMutableCompositionTrack?
        // An empty composition track reports an invalid time range, so keep the end here.
        var end = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part.url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
                recorderLog.error("Unreadable part \(part.url.lastPathComponent, privacy: .public)")
                unreadable.append(part.url)
                continue
            }
            if target == nil {
                target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                if let target { tracks.append(target) }
            }
            guard let target else { throw RecorderError.message("Не удалось подготовить сведение") }
            let offset = max(CMTime(value: part.start, timescale: CMTimeScale(AudioTrack.rate)), end)
            if offset > end { target.insertEmptyTimeRange(CMTimeRange(start: end, end: offset)) }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: offset)
            end = offset + duration
            assets.append(asset)
            expected = max(expected, (offset + duration).seconds)
        }
    }
    guard !tracks.isEmpty else { throw RecorderError.noAudio }
    let mix = tracks.count > 1 ? AVMutableAudioMix() : nil
    mix?.inputParameters = tracks.map { track in
        let volume = AVMutableAudioMixInputParameters(track: track)
        volume.setVolume(0.7, at: .zero)
        return volume
    }
    let range = trimmed ? await withCheckedContinuation { found in
        findSoundRange(of: composition, tracks: tracks, mix: mix) { found.resume(returning: $0) }
    } : CMTimeRange(start: .zero, duration: composition.duration)
    let metadata = description(range.start.seconds, range.end.seconds).map { text -> [AVMetadataItem] in
        // "desc", unlike the identifier for "©des", is what ffprobe shows as `description`.
        let item = AVMutableMetadataItem()
        item.keySpace = .iTunes
        item.key = "desc" as NSString
        item.value = text as NSString
        return [item]
    } ?? []
    try? FileManager.default.removeItem(at: output)
    // Apple's M4A preset copies a single track unchanged and plays through damaged packets,
    // but encodes a mix of two at twice their bit rate: a mix goes to an encoder at theirs.
    var encoded = false
    if let mix {
        encoded = await withCheckedContinuation { finished in
            encodeMix(of: composition, range: range, tracks: tracks, mix: mix, metadata: metadata, to: output,
                      progress: progress) { finished.resume(returning: $0) }
        }
    }
    if !encoded {
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.message("Не удалось подготовить сведение")
        }
        exporter.audioMix = mix
        exporter.metadata = metadata
        exporter.timeRange = range
        let monitor = Task {
            for await state in exporter.states(updateInterval: 0.25) {
                if case let .exporting(current) = state { progress(current.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await exporter.export(to: output, as: .m4a)
        } catch where !metadata.isEmpty {
            // The speaker timeline is never worth the recording: save without it.
            recorderLog.error("Export with the speaker timeline failed, saving without it: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: output)
            guard let plain = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw error }
            plain.audioMix = mix
            plain.timeRange = range
            try await plain.export(to: output, as: .m4a)
        }
    }
    withExtendedLifetime(assets) {}
    let duration = try await verifyRecording(output)
    guard duration > min(expected, range.end.seconds) - range.start.seconds - 1 else {
        throw RecorderError.message("Сохранённый файл короче записи")
    }
    return ExportResult(duration: duration, unreadable: unreadable)
}

/// Everything recorded for one meeting. Audio stays in this folder until a verified
/// copy reaches the destination, so a crash, a full disk or a missing folder never
/// deletes it. An advisory lock marks the folder as in use; the system releases the
/// lock when the process dies, which is how an interrupted recording is recognized.
final class RecordingSession {
    struct Manifest: Codable {
        var started: Date
        var destination: String
        var name: String
    }

    struct Delivery {
        let url: URL
        let usedFallback: Bool
        let duration: Double
        /// Some parts could not be read; they were kept aside rather than deleted.
        let incomplete: Bool
        let unreadableFolder: URL?
        /// The whole microphone, saved next to the recording when mute detection may have failed.
        let microphone: URL?
    }

    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Zoom Audio Recorder/Recordings", isDirectory: true)

    let folder: URL
    let manifest: Manifest
    private var lock: Int32

    private init(folder: URL, manifest: Manifest, lock: Int32) {
        self.folder = folder
        self.manifest = manifest
        self.lock = lock
    }

    deinit { if lock >= 0 { close(lock) } }

    static func create(destination: URL, name: String, started: Date = Date(),
                       root: URL = root) throws -> RecordingSession {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folderName = "\(formatter.string(from: started)) \(UUID().uuidString.prefix(8))"
        // Prepared under a hidden name and renamed once locked, so recovery never sees
        // a session that is not locked yet.
        let hidden = root.appendingPathComponent("." + folderName, isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let lock = acquireLock(hidden) else {
            throw RecorderError.message("Не удалось подготовить папку записи")
        }
        let manifest = Manifest(started: started, destination: destination.path, name: name)
        do {
            try JSONEncoder().encode(manifest).write(to: hidden.appendingPathComponent("session.json"), options: .atomic)
            try FileManager.default.moveItem(at: hidden, to: folder)
        } catch {
            close(lock)
            try? FileManager.default.removeItem(at: hidden)
            throw error
        }
        return RecordingSession(folder: folder, manifest: manifest, lock: lock)
    }

    /// Recordings left behind by a crash, a forced quit or a failed save.
    /// Folders still locked by a running recorder are skipped.
    static func interrupted(root: URL = root, fallback: URL) -> [RecordingSession] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        return folders.sorted { $0.path < $1.path }.compactMap { folder in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true, let lock = acquireLock(folder) else { return nil }
            if folder.lastPathComponent.hasPrefix(".") {
                // Abandoned before any audio was written.
                try? FileManager.default.removeItem(at: folder)
                close(lock)
                return nil
            }
            let saved = (try? Data(contentsOf: folder.appendingPathComponent("session.json")))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            let started = values?.creationDate ?? Date()
            let manifest = saved ?? Manifest(started: started, destination: fallback.path,
                                             name: RecordingSession.fileName(for: started))
            return RecordingSession(folder: folder, manifest: manifest, lock: lock)
        }
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Zoom \(formatter.string(from: date)).m4a"
    }

    private static func acquireLock(_ folder: URL) -> Int32? {
        let descriptor = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Marks that the user's own voice reached the microphone track.
    func markVoice() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("voice").path, contents: nil)
    }

    var hasVoice: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("voice").path) }

    /// Marks that the whole microphone must be delivered too: mute detection may have failed.
    func markSafetyCopy() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("safety").path, contents: nil)
    }

    /// Marks that Zoom's microphone control was found during the recording.
    func markControlSeen() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("control").path, contents: nil)
    }

    /// Marks that the recording stopped normally and the markers above are final.
    func markFinished() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("finished").path, contents: nil)
    }

    /// The whole microphone is delivered too: requested during the recording, or, for a
    /// recording cut short by a crash, the mute detector never found Zoom's control.
    func needsSafetyCopy(recovering: Bool) -> Bool {
        let marked = { FileManager.default.fileExists(atPath: self.folder.appendingPathComponent($0).path) }
        guard !AudioTrack.parts(named: "raw", in: folder).isEmpty else { return false }
        return marked("safety") || (recovering && !marked("finished") && !marked("control") && !hasVoice)
    }

    /// After a crash, microphone audio still held for Zoom's mute state never reached the
    /// recording. Usually that is a second; when it is more, as when Zoom was busy at the
    /// crash, the whole microphone is delivered too.
    private func microphoneCutShort() async -> Bool {
        guard hasVoice, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("finished").path) else { return false }
        func end(_ name: String) async -> Double {
            var latest = 0.0
            for part in AudioTrack.parts(named: name, in: folder) {
                if let duration = try? await verifyRecording(part.url) {
                    latest = max(latest, Double(part.start) / AudioTrack.rate + duration)
                }
            }
            return latest
        }
        return await end("raw") - end("mic") > 3
    }

    var hasAudio: Bool {
        !AudioTrack.parts(named: "zoom", in: folder).isEmpty || hasVoice || needsSafetyCopy(recovering: true)
            || Self.size(folder.appendingPathComponent("final.m4a")) > 0
    }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Exports, verifies and copies the recording to its folder (or `fallback` when that
    /// folder is unavailable), then deletes the working files. On failure nothing is
    /// deleted, and the next launch tries again.
    func deliver(fallback: URL, recovering: Bool = false,
                 progress: @escaping (Double) -> Void = { _ in }) async throws -> Delivery {
        var wholeMicrophone = needsSafetyCopy(recovering: recovering)
        if !wholeMicrophone, recovering { wholeMicrophone = await microphoneCutShort() }
        let tracks = ["zoom"] + (hasVoice ? ["mic"] : []) + (wholeMicrophone ? ["raw"] : [])
        // Unreadable parts go aside first, so they never decide which tracks are mixed.
        let incomplete = try await keepUnreadableParts(of: tracks)
        let zoomParts = AudioTrack.parts(named: "zoom", in: folder)
        let micParts = tracks.contains("mic") ? AudioTrack.parts(named: "mic", in: folder) : []
        let rawParts = tracks.contains("raw") ? AudioTrack.parts(named: "raw", in: folder) : []
        // Without any Zoom audio or voice, the safety copy is the recording itself.
        let main = try await exported("final", zoom: zoomParts, mic: micParts.isEmpty && zoomParts.isEmpty ? rawParts : micParts,
                                      description: { SpeakerLog.timeline(in: self.folder, from: $0, to: $1) }, progress: progress)
        // A failed safety copy keeps the session for a retry rather than losing the microphone.
        let cachedSafety = Self.size(folder.appendingPathComponent("microphone.m4a")) > 0
        let safety = !cachedSafety && (rawParts.isEmpty || (zoomParts.isEmpty && micParts.isEmpty)) ? nil
            : try await exported("microphone", zoom: [], mic: rawParts, trimmed: false)
        let preferred = URL(fileURLWithPath: manifest.destination, isDirectory: true)
        var failure: Error?
        // A network share that went away must not hold up saving to the fallback folder.
        if await !answers(within: 10, { RecordingStorage.reachable(preferred) }) {
            failure = RecorderError.message("Папка «\(preferred.lastPathComponent)» недоступна")
        }
        for directory in [preferred, fallback] where directory != preferred || failure == nil {
            do {
                let url = try await place(main.file, named: manifest.name, duration: main.duration, in: directory)
                // An earlier attempt may have placed it in the other folder already.
                let placed = url.deletingLastPathComponent()
                var microphone: URL?
                if let safety {
                    do {
                        let base = url.deletingPathExtension().lastPathComponent
                        microphone = try await place(safety.file, named: "\(base) (микрофон).m4a",
                                                     duration: safety.duration, in: placed)
                    } catch {
                        // Both files go to one folder; the next one gets both again.
                        try? FileManager.default.removeItem(at: url)
                        try? FileManager.default.removeItem(at: placement(of: main.file))
                        throw error
                    }
                }
                retire()
                return Delivery(url: url, usedFallback: placed.standardizedFileURL.path != preferred.standardizedFileURL.path,
                                duration: main.duration,
                                incomplete: incomplete, unreadableFolder: incomplete ? unreadableFolder : nil,
                                microphone: microphone)
            } catch {
                recorderLog.error("Save to \(directory.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
        }
        throw failure ?? RecorderError.message("Не удалось сохранить запись")
    }

    /// The mixed file in the session folder, exported once and reused on a retry.
    private func exported(_ name: String, zoom: [TrackPart], mic: [TrackPart], trimmed: Bool = true,
                          description: @escaping (Double, Double) -> String? = { _, _ in nil },
                          progress: @escaping (Double) -> Void = { _ in }) async throws -> (file: URL, duration: Double) {
        let file = folder.appendingPathComponent("\(name).m4a")
        if let duration = try? await verifyRecording(file) { return (file, duration) }
        let partial = folder.appendingPathComponent("\(name).partial.m4a")
        let result = try await exportRecording(zoom: zoom, mic: mic, to: partial, trimmed: trimmed, description: description,
                                               progress: progress)
        syncToStorage(partial)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: partial, to: file)
        return (file, result.duration)
    }

    /// Where an exported file was placed, recorded until the session is retired.
    private func placement(of file: URL) -> URL {
        folder.appendingPathComponent("placed-" + file.deletingPathExtension().lastPathComponent)
    }

    /// Copies under a hidden name, flushes it to storage and checks that it plays,
    /// then renames: a visible file is always complete and nothing is overwritten.
    private func place(_ file: URL, named name: String, duration: Double, in directory: URL) async throws -> URL {
        let manager = FileManager.default
        // A save cut short after the rename, by a crash or a shutdown, already put it in place.
        let record = placement(of: file)
        if let path = try? String(contentsOf: record, encoding: .utf8), Self.size(URL(fileURLWithPath: path)) == Self.size(file) {
            return URL(fileURLWithPath: path)
        }
        // An unmounted drive's path must not be recreated on the startup disk.
        guard RecordingStorage.reachable(directory) else {
            throw RecorderError.message("Папка «\(directory.lastPathComponent)» недоступна")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        // Named after the session, so a copy cut short is replaced by the next attempt.
        let temporary = directory.appendingPathComponent(
            ".zoom-recording-\(folder.lastPathComponent)-\(file.deletingPathExtension().lastPathComponent).partial.m4a")
        try? manager.removeItem(at: temporary)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: file, to: temporary)
        syncToStorage(temporary)
        guard Self.size(temporary) == Self.size(file),
              abs(try await verifyRecording(temporary) - duration) < 0.1 else {
            throw RecorderError.message("Файл скопирован не полностью")
        }
        var target = directory.appendingPathComponent(name)
        var index = 2
        while true {
            if !manager.fileExists(atPath: target.path) {
                // Recorded before the rename, so a save cut short right after it is not repeated.
                try? Data(target.path.utf8).write(to: record, options: .atomic)
                syncToStorage(record)
                // FileManager's existence check and move can race with another save.
                // RENAME_EXCL makes refusing an existing filename part of the rename itself.
                // exFAT and some network shares lack it; there the check above has to do.
                var renamed = renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0
                var code = errno
                if !renamed, code == ENOTSUP || code == EINVAL {
                    renamed = rename(temporary.path, target.path) == 0
                    code = errno
                }
                if renamed {
                    syncToStorage(directory)
                    return target
                }
                guard code == EEXIST else {
                    try? manager.removeItem(at: record)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                  userInfo: [NSFilePathErrorKey: target.path])
                }
            }
            target = directory.appendingPathComponent("\(base) \(index).m4a")
            index += 1
        }
    }

    /// Parts of `tracks` that cannot be opened are moved aside instead of being deleted
    /// with the session. A part cut short before its first fragment holds under a second
    /// that nothing can play, so it is simply dropped.
    private func keepUnreadableParts(of tracks: [String]) async throws -> Bool {
        let aside = unreadableFolder
        // A previous delivery may have moved parts aside before its destination failed.
        var kept = FileManager.default.fileExists(atPath: aside.path)
        for part in tracks.flatMap({ AudioTrack.parts(named: $0, in: folder) }) {
            guard (try? await verifyRecording(part.url)) == nil else { continue }
            if Self.size(part.url) == 0 || Self.beforeFirstFragment(part.url) {
                try FileManager.default.removeItem(at: part.url)
                continue
            }
            // If preservation fails, retain the entire session for a retry.
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: part.url, to: aside.appendingPathComponent(part.url.lastPathComponent))
            kept = true
        }
        return kept
    }

    /// Whether a fragmented M4A was cut off before its header: it starts like one but
    /// holds no movie or fragment header yet, only the first, still open media data.
    static func beforeFirstFragment(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var types: [String] = []
        while (try? handle.seek(toOffset: offset)) != nil, let header = try? handle.read(upToCount: 16), header.count >= 8 {
            let bytes = [UInt8](header)
            types.append(String(decoding: bytes[4..<8], as: UTF8.self))
            var size = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if size == 1, bytes.count == 16 { size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            // Zero: the box runs to the end of the file.
            guard size >= 8 else { break }
            offset += size
        }
        return types.first == "ftyp" && !types.contains("moov") && !types.contains("moof")
    }

    private var unreadableFolder: URL {
        folder.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Unreadable/\(folder.lastPathComponent)", isDirectory: true)
    }

    /// After delivery: one rename marks the session done, so a crash while deleting
    /// cannot deliver it twice (recovery deletes hidden folders it can lock).
    private func retire() {
        let hidden = folder.deletingLastPathComponent().appendingPathComponent("." + folder.lastPathComponent)
        if (try? FileManager.default.moveItem(at: folder, to: hidden)) != nil {
            try? FileManager.default.removeItem(at: hidden)
        }
        remove()
    }

    /// Deletes the working files. Only after a verified delivery, or when nothing was recorded.
    func remove() {
        try? FileManager.default.removeItem(at: folder)
        if lock >= 0 { close(lock) }
        lock = -1
    }
}
