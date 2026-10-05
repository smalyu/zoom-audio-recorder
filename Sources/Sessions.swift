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

    /// The whole microphone is delivered too: requested during the recording, or, for a
    /// recording cut short by a crash, the mute detector never found Zoom's control.
    func needsSafetyCopy(recovering: Bool) -> Bool {
        let marked = { FileManager.default.fileExists(atPath: self.folder.appendingPathComponent($0).path) }
        guard !AudioTrack.parts(named: "raw", in: folder).isEmpty else { return false }
        return marked("safety") || (recovering && !marked("control") && !hasVoice)
    }

    var hasAudio: Bool {
        !AudioTrack.parts(named: "zoom", in: folder).isEmpty || hasVoice || needsSafetyCopy(recovering: true)
            || Self.size(folder.appendingPathComponent("final.m4a")) > 0
    }

    private var parts: [TrackPart] {
        AudioTrack.parts(named: "zoom", in: folder) + AudioTrack.parts(named: "mic", in: folder)
            + AudioTrack.parts(named: "raw", in: folder)
    }

    /// Bytes of all source tracks, including the safety microphone.
    var recordedBytes: Int { parts.reduce(0) { $0 + Self.size($1.url) } }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Exports, verifies and copies the recording to its folder (or `fallback` when that
    /// folder is unavailable), then deletes the working files. On failure nothing is
    /// deleted, and the next launch tries again.
    func deliver(fallback: URL, recovering: Bool = false,
                 progress: @escaping (Double) -> Void = { _ in }) async throws -> Delivery {
        let zoomParts = AudioTrack.parts(named: "zoom", in: folder)
        let micParts = hasVoice ? AudioTrack.parts(named: "mic", in: folder) : []
        let rawParts = needsSafetyCopy(recovering: recovering) ? AudioTrack.parts(named: "raw", in: folder) : []
        // Without any Zoom audio or voice, the safety copy is the recording itself.
        let main = try await exported("final", zoom: zoomParts, mic: micParts.isEmpty && zoomParts.isEmpty ? rawParts : micParts,
                                      progress: progress)
        // A failed safety copy keeps the session for a retry rather than losing the microphone.
        let cachedSafety = Self.size(folder.appendingPathComponent("microphone.m4a")) > 0
        let safety = !cachedSafety && (rawParts.isEmpty || (zoomParts.isEmpty && micParts.isEmpty)) ? nil
            : try await exported("microphone", zoom: [], mic: rawParts)
        let preferred = URL(fileURLWithPath: manifest.destination, isDirectory: true)
        var failure: Error?
        let incomplete = try await keepUnreadableParts()
        for directory in [preferred, fallback] where directory != preferred || failure == nil {
            do {
                let url = try await place(main.file, named: manifest.name, duration: main.duration, in: directory)
                var microphone: URL?
                if let safety {
                    do {
                        let base = url.deletingPathExtension().lastPathComponent
                        microphone = try await place(safety.file, named: "\(base) (микрофон).m4a",
                                                     duration: safety.duration, in: directory)
                    } catch {
                        // Both files go to one folder; the next one gets both again.
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                }
                retire()
                return Delivery(url: url, usedFallback: directory != preferred, duration: main.duration,
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
    private func exported(_ name: String, zoom: [TrackPart], mic: [TrackPart],
                          progress: @escaping (Double) -> Void = { _ in }) async throws -> (file: URL, duration: Double) {
        let file = folder.appendingPathComponent("\(name).m4a")
        if let duration = try? await verifyRecording(file) { return (file, duration) }
        let partial = folder.appendingPathComponent("\(name).partial.m4a")
        let result = try await exportRecording(zoom: zoom, mic: mic, to: partial, progress: progress)
        syncToStorage(partial)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: partial, to: file)
        return (file, result.duration)
    }

    /// Copies under a hidden name, flushes it to storage and checks that it plays,
    /// then renames: a visible file is always complete and nothing is overwritten.
    private func place(_ file: URL, named name: String, duration: Double, in directory: URL) async throws -> URL {
        let manager = FileManager.default
        // An unmounted drive's path must not be recreated on the startup disk.
        guard RecordingStorage.reachable(directory) else {
            throw RecorderError.message("Папка «\(directory.lastPathComponent)» недоступна")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let temporary = directory.appendingPathComponent(".zoom-recording-\(UUID().uuidString).partial.m4a")
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
                // FileManager's existence check and move can race with another save.
                // RENAME_EXCL makes refusing an existing filename part of the rename itself.
                if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                    syncToStorage(directory)
                    return target
                }
                let code = errno
                guard code == EEXIST else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                  userInfo: [NSFilePathErrorKey: target.path])
                }
            }
            target = directory.appendingPathComponent("\(base) \(index).m4a")
            index += 1
        }
    }

    /// Parts that cannot be opened are moved aside instead of being deleted with the session.
    private func keepUnreadableParts() async throws -> Bool {
        let aside = unreadableFolder
        // A previous delivery may have moved parts aside before its destination failed.
        var kept = FileManager.default.fileExists(atPath: aside.path)
        for part in parts where Self.size(part.url) > 0 {
            guard (try? await verifyRecording(part.url)) == nil else { continue }
            // If preservation fails, retain the entire session for a retry.
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: part.url, to: aside.appendingPathComponent(part.url.lastPathComponent))
            kept = true
        }
        return kept
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
