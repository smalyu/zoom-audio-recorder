import AVFoundation
import Foundation

/// Opens a recording and checks that it plays: exactly one audio track, no video.
@discardableResult
func verifyRecording(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let video = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration).seconds
    guard audio.count == 1, video.isEmpty, duration > 0 else {
        throw RecorderError.message("Сохранённый файл не прошёл проверку")
    }
    return duration
}

struct ExportResult {
    let duration: Double
    /// Parts AVFoundation could not open.
    let unreadable: [URL]
}

/// Mixes the recorded parts into one ordinary M4A file and verifies it. Each track's
/// parts are laid out on one composition track at their offsets. Parts cut short by a
/// crash are used up to their last readable fragment.
@discardableResult
func exportRecording(zoom: [TrackPart], mic: [TrackPart], to output: URL,
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
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else {
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
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
        throw RecorderError.message("Не удалось подготовить сведение")
    }
    if tracks.count > 1 {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let volume = AVMutableAudioMixInputParameters(track: track)
            volume.setVolume(0.7, at: .zero)
            return volume
        }
        exporter.audioMix = mix
    }
    try? FileManager.default.removeItem(at: output)
    let monitor = Task {
        for await state in exporter.states(updateInterval: 0.25) {
            if case let .exporting(current) = state { progress(current.fractionCompleted) }
        }
    }
    defer { monitor.cancel() }
    try await exporter.export(to: output, as: .m4a)
    withExtendedLifetime(assets) {}
    let duration = try await verifyRecording(output)
    guard duration > expected - 1 else {
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
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
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

    var hasAudio: Bool {
        !AudioTrack.parts(named: "zoom", in: folder).isEmpty || hasVoice
    }

    private var parts: [TrackPart] {
        AudioTrack.parts(named: "zoom", in: folder) + AudioTrack.parts(named: "mic", in: folder)
    }

    /// Bytes of recorded parts: tells a crash in the first second from real damage.
    var recordedBytes: Int { parts.reduce(0) { $0 + Self.size($1.url) } }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Exports, verifies and copies the recording to its folder (or `fallback` when that
    /// folder is unavailable), then deletes the working files. On failure nothing is
    /// deleted, and the next launch tries again.
    func deliver(fallback: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> Delivery {
        let final = folder.appendingPathComponent("final.m4a")
        let duration: Double
        if let existing = try? await verifyRecording(final) {
            duration = existing
        } else {
            let partial = folder.appendingPathComponent("export.m4a")
            let result = try await exportRecording(zoom: AudioTrack.parts(named: "zoom", in: folder),
                                                   mic: hasVoice ? AudioTrack.parts(named: "mic", in: folder) : [],
                                                   to: partial, progress: progress)
            syncToStorage(partial)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            duration = result.duration
        }
        let preferred = URL(fileURLWithPath: manifest.destination, isDirectory: true)
        var failure: Error?
        let incomplete = await keepUnreadableParts()
        for directory in [preferred, fallback] where directory != preferred || failure == nil {
            do {
                let url = try await place(final, duration: duration, in: directory)
                retire()
                return Delivery(url: url, usedFallback: directory != preferred, duration: duration, incomplete: incomplete)
            } catch {
                recorderLog.error("Save to \(directory.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
        }
        throw failure ?? RecorderError.message("Не удалось сохранить запись")
    }

    /// Copies under a hidden name, flushes it to storage and checks that it plays,
    /// then renames: a visible file is always complete and nothing is overwritten.
    private func place(_ file: URL, duration: Double, in directory: URL) async throws -> URL {
        let manager = FileManager.default
        // An unmounted drive's path must not be recreated on the startup disk.
        var existing = directory
        while !manager.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        guard existing.path != "/Volumes" else {
            throw RecorderError.message("Папка «\(directory.lastPathComponent)» недоступна")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (manifest.name as NSString).deletingPathExtension
        var target = directory.appendingPathComponent(manifest.name)
        var index = 2
        while manager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base) \(index).m4a")
            index += 1
        }
        let temporary = directory.appendingPathComponent(".\(base) \(UUID().uuidString.prefix(8)).partial.m4a")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: file, to: temporary)
        syncToStorage(temporary)
        guard Self.size(temporary) == Self.size(file),
              abs(try await verifyRecording(temporary) - duration) < 0.1 else {
            throw RecorderError.message("Файл скопирован не полностью")
        }
        try manager.moveItem(at: temporary, to: target)
        syncToStorage(directory)
        return target
    }

    /// Parts that cannot be opened are moved aside instead of being deleted with the
    /// session. Tiny ones hold nothing playable (a crash in the first second).
    private func keepUnreadableParts() async -> Bool {
        var kept = false
        for part in parts where Self.size(part.url) > 65_536 {
            let asset = AVURLAsset(url: part.url)
            guard (try? await asset.loadTracks(withMediaType: .audio).first) == nil else { continue }
            let aside = folder.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Unreadable/\(folder.lastPathComponent)", isDirectory: true)
            try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: part.url, to: aside.appendingPathComponent(part.url.lastPathComponent))) != nil {
                kept = true
            }
        }
        return kept
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
