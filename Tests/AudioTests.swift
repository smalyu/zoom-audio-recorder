import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum TestError: Error { case failed(String) }
func check(_ value: Bool, _ message: String) throws {
    if !value { throw TestError.failed(message) }
}

/// A PCM sample buffer with a sine tone (frequency 0 gives silence).
func sample(frequency: Double, start: Int64, frames: Int = 4800, rate: Double = 48_000,
            channels: Int = 1, float: Bool = false, interleaved: Bool = true) throws -> CMSampleBuffer {
    let common: AVAudioCommonFormat = float ? .pcmFormatFloat32 : .pcmFormatInt16
    let format = channels > 2
        ? AVAudioFormat(commonFormat: common, sampleRate: rate, interleaved: interleaved,
                        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!)
        : AVAudioFormat(commonFormat: common, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
        let value = sin(2 * .pi * frequency * Double(Int(start) + frame) / rate) * 0.2
        for channel in 0..<channels {
            if float {
                if interleaved { buffer.floatChannelData![0][frame * channels + channel] = Float(value) }
                else { buffer.floatChannelData![channel][frame] = Float(value) }
            } else {
                if interleaved { buffer.int16ChannelData![0][frame * channels + channel] = Int16(value * 32767) }
                else { buffer.int16ChannelData![channel][frame] = Int16(value * 32767) }
            }
        }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                    presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(rate)),
                                    decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    try check(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                   sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr, "sample")
    try check(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                             bufferList: buffer.audioBufferList) == noErr, "sample data")
    return result!
}

func decode(_ url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: decoded)
    return decoded
}

func tone(_ buffer: AVAudioPCMBuffer, at seconds: Double, frequency: Double) -> Double {
    let rate = buffer.format.sampleRate
    let start = Int(seconds * rate)
    let count = min(Int(rate * 0.1), Int(buffer.frameLength) - start)
    guard count > 0 else { return 0 }
    let data = buffer.floatChannelData![0]
    var real = 0.0, imaginary = 0.0
    for offset in 0..<count {
        let angle = 2 * .pi * frequency * Double(start + offset) / rate
        real += Double(data[start + offset]) * cos(angle)
        imaginary += Double(data[start + offset]) * sin(angle)
    }
    return 2 * sqrt(real * real + imaginary * imaginary) / Double(count)
}

func duration(_ url: URL) async throws -> Double {
    try await AVURLAsset(url: url).load(.duration).seconds
}

func checkNormalizer() throws {
    let normalizer = PCMNormalizer(channels: 1)
    let low = try normalizer.convert(try sample(frequency: 440, start: 0, frames: 1600, rate: 16_000))
    try check(abs(Int(low.frameLength) - 4800) < 100, "16 kHz input not resampled: \(low.frameLength)")
    // The first call holds back the resampler's filter latency; later calls are exact.
    for index in 0..<2 {
        let high = try normalizer.convert(try sample(frequency: 440, start: Int64(index * 9600), frames: 9600, rate: 96_000,
                                                     channels: 2, float: true, interleaved: false))
        try check(abs(Int(high.frameLength) - 4800) < (index == 0 ? 1000 : 100), "96 kHz stereo input not resampled: \(high.frameLength)")
    }
    let stereo = PCMNormalizer(channels: 2)
    let wide = try stereo.convert(try sample(frequency: 440, start: 0, channels: 6, float: true, interleaved: false))
    try check(wide.format.channelCount == 2 && wide.frameLength >= 4000, "6-channel input not mixed down")
    let quiet = normalizer.silence(like: try sample(frequency: 880, start: 0, frames: 1600, rate: 16_000))!
    try check(quiet.frameLength == 4800, "silence length wrong")
    try check((0..<Int(quiet.frameLength)).allSatisfy { quiet.floatChannelData![0][$0] == 0 }, "silence not silent")
    let source = try normalizer.convert(try sample(frequency: 440, start: 0))
    let rest = source.dropping(frames: 1000)!
    try check(rest.frameLength == source.frameLength - 1000 && rest.floatChannelData![0][0] == source.floatChannelData![0][1000],
              "dropping wrong")
    try check(source.dropping(frames: Int64(source.frameLength)) == nil, "dropping everything should give nil")
    print("PASS: resampling 16/96 kHz, downmix, silence without reading audio, trimming")
}

/// A buffer straight from a device: interleaved Float32, tone in channel 0, optionally
/// with a channel layout that carries no speaker positions.
func deviceSample(channels: Int, frames: Int = 4800, layoutTag: AudioChannelLayoutTag? = nil) throws -> CMSampleBuffer {
    var stream = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
        mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    var layout = AudioChannelLayout(mChannelLayoutTag: layoutTag ?? 0, mChannelBitmap: [],
                                    mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
    let status = withUnsafePointer(to: &layout) { pointer in
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream,
                                       layoutSize: layoutTag == nil ? 0 : MemoryLayout<AudioChannelLayout>.size,
                                       layout: layoutTag == nil ? nil : pointer,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }
    try check(status == noErr, "device format")
    var values = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames { values[frame * channels] = Float(sin(2 * .pi * 440 * Double(frame) / 48_000) * 0.2) }
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: values.count * 4,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr, "device block")
    values.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
    var result: CMSampleBuffer?
    try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!,
        formatDescription: format!, sampleCount: frames, presentationTimeStamp: .zero,
        packetDescriptions: nil, sampleBufferOut: &result) == noErr, "device sample")
    return result!
}

func checkDevices() throws {
    let devices: [(Int, AudioChannelLayoutTag?)] = [(3, nil), (4, nil), (16, nil), (2, kAudioChannelLayoutTag_DiscreteInOrder | 2),
                                                     (4, kAudioChannelLayoutTag_Unknown | 4), (8, kAudioChannelLayoutTag_DiscreteInOrder | 8)]
    for (channels, layout) in devices {
        for target in [1, 2] {
            let normalizer = PCMNormalizer(channels: AVAudioChannelCount(target))
            var peak: Float = 0
            for _ in 0..<3 {
                let output = try normalizer.convert(try deviceSample(channels: channels, layoutTag: layout))
                for index in 0..<Int(output.frameLength) * target { peak = max(peak, abs(output.floatChannelData![0][index])) }
            }
            // Mono averages the first two channels; stereo keeps channel 0 on the left.
            try check(peak > (target == 1 ? 0.08 : 0.15), "\(channels)-channel device lost its first channel (peak \(peak))")
        }
    }
    print("PASS: multichannel devices without speaker positions")
}

/// Polls of Zoom's mute control start every 0.2 s and finish 10 ms later, like the watcher's.
struct MutePolls {
    var unmuted: (Double) -> Bool
    var readings = MuteReadings()
    private var next = 0
    init(unmuted: @escaping (Double) -> Bool) { self.unmuted = unmuted }
    mutating func advance(to clock: Double) {
        while Double(next) * 0.2 + 0.01 <= clock + 1e-9 {
            let poll = Double(next) * 0.2
            if unmuted(poll) {
                readings.unmuted = 1000 + poll
                readings.since = min(readings.since, 1000 + poll)
                readings.open = true
            } else {
                readings.other = 1000 + poll
                readings.since = .infinity
                readings.open = false
            }
            next += 1
        }
    }
}

/// Zoom gaps, a long gap that opens a new part, a format change, mute windows where
/// speech is written only after a mute reading confirms it, then a mixed export.
func checkCapture(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    var polls = MutePolls { (0.8..<1.8).contains($0) || $0 >= 3.0 }
    capture.muteReadings = { polls.readings }
    var voice = 0
    capture.onVoice = { voice += 1 }
    for index in 0..<45 {
        let start = Int64(48_000_000 + index * 4800)
        clock = Double(index + 1) * 0.1
        polls.advance(to: clock)
        // Zoom delivers nothing for 0.5 s (a gap), and switches format at 3 s.
        if !(20..<25).contains(index) {
            let zoom = index < 30 ? try sample(frequency: 440, start: start, channels: 2, float: true, interleaved: false)
                : try sample(frequency: 440, start: start / 2, frames: 2400, rate: 24_000)
            capture.receive(zoom, of: .audio)
        }
        capture.receive(try sample(frequency: 880, start: start), of: .microphone)
    }
    // Stop: one final reading, then the held audio is written.
    clock = 4.6
    polls.advance(to: clock + 0.2)
    capture.releaseVoice(flushing: true)
    // Twelve seconds later Zoom audio resumes: a long gap starts a second part.
    clock = 16.6
    capture.receive(try sample(frequency: 440, start: 48_000_000 + 160 * 4800, channels: 2, float: true, interleaved: false),
                    of: .audio)
    await capture.zoom.finish()
    await capture.mic.finish()
    try check(capture.zoom.failures == 0 && capture.mic.failures == 0, "writer failed: \(String(describing: capture.zoom.failure ?? capture.mic.failure))")
    try check(capture.hadVoice && voice == 1, "voice not reported once")
    let zoomParts = AudioTrack.parts(named: "zoom", in: folder)
    let micParts = AudioTrack.parts(named: "mic", in: folder)
    try check(zoomParts.map(\.start) == [0, 768_000], "unexpected Zoom parts: \(zoomParts.map(\.start))")
    try check(micParts.count == 1 && micParts[0].start == 0, "unexpected mic parts")
    try check(abs(try await duration(zoomParts[0].url) - 4.5) < 0.05, "queued Zoom audio lost before the long gap")
    let output = folder.appendingPathComponent("mixed.m4a")
    let length = try await exportRecording(zoom: zoomParts, mic: micParts, to: output).duration
    try check(abs(length - 16.1) < 0.15, "mixed duration \(length)")
    let decoded = try decode(output)
    for time in [0.35, 1.55, 2.5, 2.8] {
        try check(tone(decoded, at: time, frequency: 880) < 0.003, "microphone audible while muted at \(time)")
    }
    for time in [0.95, 1.15, 3.2, 4.2] {
        try check(tone(decoded, at: time, frequency: 880) > 0.05, "microphone missing or shifted at \(time)")
    }
    try check(tone(decoded, at: 2.15, frequency: 440) < 0.003, "Zoom gap collapsed or not silent")
    for time in [1.5, 2.65, 3.6, 16.02] {
        try check(tone(decoded, at: time, frequency: 440) > 0.05, "Zoom missing or shifted at \(time)")
    }
    let asset = AVURLAsset(url: output)
    try check(try await asset.loadTracks(withMediaType: .audio).count == 1, "expected one audio track")
    try check(try await asset.loadTracks(withMediaType: .video).isEmpty, "unexpected video")
    let remote = folder.appendingPathComponent("remote.m4a")
    try await exportRecording(zoom: [zoomParts[0]], mic: [], to: remote)
    try check(tone(try decode(remote), at: 1.5, frequency: 440) > 0.09, "single-track export lost volume")
    print("PASS: gap filling, new part after a long gap, format change, voice only after a confirming mute reading, aligned mix")
}

/// The gate was open, but no mute reading ever confirmed it: nothing of the voice is kept.
func checkUnconfirmedVoice(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    capture.muteReadings = { MuteReadings(since: 0, open: true) }
    for index in 0..<30 {
        clock = Double(index + 1) * 0.1
        capture.receive(try sample(frequency: 880, start: Int64(48_000_000 + index * 4800)), of: .microphone)
    }
    capture.releaseVoice(flushing: true)
    await capture.mic.finish()
    try check(!capture.hadVoice, "unconfirmed audio counted as voice")
    let decoded = try decode(AudioTrack.parts(named: "mic", in: folder)[0].url)
    for time in [0.2, 1.0, 2.5] {
        try check(tone(decoded, at: time, frequency: 880) < 0.003, "unconfirmed microphone audio written at \(time)")
    }
    print("PASS: microphone audio without a confirming reading becomes silence")
}

/// Delivery stalls for 2.5 s and the backlog arrives at once: nothing is lost or moved.
func checkLateDelivery(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    for index in 0..<100 {
        clock = (30..<55).contains(index) ? 5.5 : Double(index + 1) * 0.1
        capture.receive(try sample(frequency: 440, start: Int64(48_000_000 + index * 4800), channels: 2, float: true),
                        of: .audio)
    }
    await capture.zoom.finish()
    let parts = AudioTrack.parts(named: "zoom", in: folder)
    try check(parts.count == 1, "a stall split the track")
    let decoded = try decode(parts[0].url)
    try check(abs(Double(decoded.frameLength) / 48_000 - 10) < 0.05, "a stall changed the length")
    for time in [3.2, 4.0, 5.0, 8.0] {
        try check(tone(decoded, at: time, frequency: 440) > 0.05, "audio lost after a delivery stall at \(time)")
    }
    print("PASS: a 2.5 s delivery stall keeps every sample in place")
}

/// Writes 20 ms microphone buffers delivered as `arrival` says, with Zoom's label following `unmuted`.
func voiceTrack(_ folder: URL, seconds: Double, unmuted: @escaping (Double) -> Bool,
                arrival: (Int) -> Double) async throws -> AVAudioPCMBuffer {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    var polls = MutePolls(unmuted: unmuted)
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    capture.muteReadings = { polls.readings }
    for index in 0..<Int(seconds / 0.02) {
        clock = arrival(index)
        polls.advance(to: clock)
        capture.receive(try sample(frequency: 880, start: Int64(48_000_000 + index * 960), frames: 960), of: .microphone)
    }
    polls.advance(to: clock + 0.2)
    capture.releaseVoice(flushing: true)
    await capture.mic.finish()
    return try decode(AudioTrack.parts(named: "mic", in: folder)[0].url)
}

func checkMuteEdges(_ folder: URL) async throws {
    // Delivery stalls from 1.0 s; Zoom is unmuted at 1.99 s; the backlog arrives at 2.6 s.
    let stalled = try await voiceTrack(folder.appendingPathComponent("stall"), seconds: 4, unmuted: { $0 >= 1.99 }) {
        let captured = Double($0) * 0.02
        return (1.0..<2.5).contains(captured) ? 2.6 : captured + 0.025
    }
    for time in [1.2, 1.6, 1.9] {
        try check(tone(stalled, at: time, frequency: 880) < 0.003, "backlog spoken while muted was kept at \(time)")
    }
    try check(tone(stalled, at: 3.0, frequency: 880) > 0.05, "voice after unmute lost")
    // A short mute from 2.03 to 2.39 s with exactly one poll inside it.
    let brief = try await voiceTrack(folder.appendingPathComponent("brief"), seconds: 4, unmuted: { !(2.03..<2.39).contains($0) }) {
        Double($0) * 0.02 + 0.025
    }
    for time in [2.05, 2.15, 2.25] {
        try check(tone(brief, at: time, frequency: 880) < 0.003, "speech during a short mute was kept at \(time)")
    }
    for time in [1.5, 3.0] {
        try check(tone(brief, at: time, frequency: 880) > 0.05, "voice around a short mute lost at \(time)")
    }
    print("PASS: a stalled backlog and a short mute never let muted speech through")
}

/// The first buffers arrive 3 s late, then delivery catches up: nothing is lost.
func checkLateStart(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    for index in 0..<100 {
        clock = index < 30 ? 3.1 : Double(index + 1) * 0.1
        capture.receive(try sample(frequency: 440, start: Int64(48_000_000 + index * 4800), channels: 2, float: true), of: .audio)
    }
    await capture.zoom.finish()
    let parts = AudioTrack.parts(named: "zoom", in: folder)
    try check(parts.count == 1, "a late start split the track")
    let decoded = try decode(parts[0].url)
    try check(abs(Double(decoded.frameLength) / 48_000 - 10) < 0.05, "a late start lost audio: \(Double(decoded.frameLength) / 48_000) s")
    print("PASS: a stream whose first buffers arrive late keeps every sample")
}

/// A track whose first part starts after zero keeps its offset in the mix.
func checkOffsets(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let zoom = AudioTrack(name: "zoom", directory: folder, channels: 2, realtime: false)
    let mic = AudioTrack(name: "mic", directory: folder, channels: 1, realtime: false)
    let zoomPCM = PCMNormalizer(channels: 2), micPCM = PCMNormalizer(channels: 1)
    for index in 0..<60 {
        let start = Int64(index * 4800)
        mic.append(try micPCM.convert(try sample(frequency: 880, start: start)), at: start)
        if index >= 30 { zoom.append(try zoomPCM.convert(try sample(frequency: 440, start: start, channels: 2, float: true)), at: start) }
    }
    await zoom.finish()
    await mic.finish()
    let output = folder.appendingPathComponent("mixed.m4a")
    try await exportRecording(zoom: AudioTrack.parts(named: "zoom", in: folder), mic: AudioTrack.parts(named: "mic", in: folder), to: output)
    let decoded = try decode(output)
    try check(tone(decoded, at: 1.0, frequency: 440) < 0.003, "Zoom part placed before its offset")
    try check(tone(decoded, at: 4.0, frequency: 440) > 0.05, "Zoom part missing at its offset")
    print("PASS: a part that starts after zero keeps its offset")
}

/// Child process: records ~3 s in real time, then kills itself with SIGKILL.
func crashChild(root: URL, destination: URL) async throws -> Never {
    let session = try RecordingSession.create(destination: destination, name: "Crash test.m4a", root: root)
    let zoom = AudioTrack(name: "zoom", directory: session.folder, channels: 2)
    let mic = AudioTrack(name: "mic", directory: session.folder, channels: 1)
    let zoomPCM = PCMNormalizer(channels: 2), micPCM = PCMNormalizer(channels: 1)
    session.markVoice()
    for index in 0..<30 {
        let start = Int64(index * 4800)
        zoom.append(try zoomPCM.convert(try sample(frequency: 440, start: start, channels: 2, float: true)), at: start)
        mic.append(try micPCM.convert(try sample(frequency: 880, start: start)), at: start)
        try await Task.sleep(for: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(500))
    kill(getpid(), SIGKILL)
    fatalError("unreachable")
}

func checkCrashRecovery(_ folder: URL) async throws {
    let root = folder.appendingPathComponent("sessions")
    let destination = folder.appendingPathComponent("out")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--crash-child", root.path, destination.path]
    try child.run()
    child.waitUntilExit()
    try check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "child was not killed")
    let found = RecordingSession.interrupted(root: root, fallback: folder.appendingPathComponent("fallback"))
    try check(found.count == 1, "interrupted session not found")
    let session = found[0]
    try check(session.hasAudio && session.hasVoice, "crashed session lost its tracks")
    let delivery = try await session.deliver(fallback: folder.appendingPathComponent("fallback"))
    try check(delivery.url == destination.appendingPathComponent("Crash test.m4a") && !delivery.usedFallback, "wrong destination")
    let length = try await duration(delivery.url)
    try check(length >= 1.9, "too little recovered after SIGKILL: \(length) s")
    let decoded = try decode(delivery.url)
    try check(tone(decoded, at: 1.0, frequency: 440) > 0.05 && tone(decoded, at: 1.0, frequency: 880) > 0.05,
              "recovered mix lost a track")
    try check(!FileManager.default.fileExists(atPath: session.folder.path), "session not removed after delivery")
    try check(RecordingSession.interrupted(root: root, fallback: folder).isEmpty, "recovered session found again")
    print("PASS: SIGKILL mid-recording → \(String(format: "%.1f", length)) s recovered and delivered, session cleaned up")
}

func makeSession(root: URL, destination: URL, name: String) async throws -> RecordingSession {
    let session = try RecordingSession.create(destination: destination, name: name, root: root)
    let track = AudioTrack(name: "zoom", directory: session.folder, channels: 2, realtime: false)
    let pcm = PCMNormalizer(channels: 2)
    for index in 0..<20 {
        track.append(try pcm.convert(try sample(frequency: 440, start: Int64(index * 4800), channels: 2, float: true)),
                     at: Int64(index * 4800))
    }
    await track.finish()
    return session
}

func checkSessions(_ folder: URL) async throws {
    let root = folder.appendingPathComponent("sessions")
    let destination = folder.appendingPathComponent("meetings")
    let fallback = folder.appendingPathComponent("fallback")
    var held: RecordingSession? = try await makeSession(root: root, destination: destination, name: "Meeting.m4a")
    try check(RecordingSession.interrupted(root: root, fallback: fallback).isEmpty, "a session in use was offered for recovery")
    let heldFolder = held!.folder
    held = nil
    let released = RecordingSession.interrupted(root: root, fallback: fallback)
    try check(released.map(\.folder.lastPathComponent) == [heldFolder.lastPathComponent],
              "released session not offered for recovery: \(released.map(\.folder))")
    try check(!released[0].hasVoice, "voice marker appeared")
    // An existing file is never overwritten.
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: destination.appendingPathComponent("Meeting.m4a"))
    let first = try await released[0].deliver(fallback: fallback)
    try check(first.url.lastPathComponent == "Meeting 2.m4a", "name collision not resolved: \(first.url.lastPathComponent)")
    try check(try String(contentsOf: destination.appendingPathComponent("Meeting.m4a"), encoding: .utf8) == "keep", "existing file overwritten")
    try check(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".") },
              "temporary file left in the destination")
    // A disconnected drive falls back to the default folder.
    let offline = URL(fileURLWithPath: "/Volumes/Zoom Recorder Test Missing Drive/Meetings")
    let second = try await makeSession(root: root, destination: offline, name: "Offline.m4a")
    let moved = try await second.deliver(fallback: fallback)
    try check(moved.usedFallback && moved.url == fallback.appendingPathComponent("Offline.m4a"), "fallback not used")
    try check(!FileManager.default.fileExists(atPath: "/Volumes/Zoom Recorder Test Missing Drive"), "missing drive path recreated")
    // When nothing is writable, the recording stays in the session for the next launch.
    var third: RecordingSession? = try await makeSession(root: root, destination: offline, name: "Kept.m4a")
    let keptFolder = third!.folder
    do {
        _ = try await third!.deliver(fallback: URL(fileURLWithPath: "/Volumes/Zoom Recorder Test Missing Drive 2"))
        try check(false, "delivery to unavailable folders succeeded")
    } catch is TestError {
        throw TestError.failed("delivery to unavailable folders succeeded")
    } catch {}
    third = nil
    try check(try await verifyRecording(keptFolder.appendingPathComponent("final.m4a")) > 1.9, "final file not kept")
    try check(AudioTrack.parts(named: "zoom", in: keptFolder).count == 1, "tracks deleted after a failed delivery")
    let retry = RecordingSession.interrupted(root: root, fallback: fallback)
    try check(retry.count == 1, "kept session not offered again")
    let delivered = try await retry[0].deliver(fallback: fallback)
    try check(delivered.url.lastPathComponent == "Kept.m4a", "retry did not deliver")
    // A session abandoned before it was renamed is cleaned up.
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".abandoned"), withIntermediateDirectories: true)
    try check(RecordingSession.interrupted(root: root, fallback: fallback).isEmpty, "abandoned folder offered for recovery")
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".abandoned").path), "abandoned folder kept")
    // A session without audio is recognised as empty.
    let empty = try RecordingSession.create(destination: destination, name: "Empty.m4a", root: root)
    try check(!empty.hasAudio && empty.recordedBytes == 0, "empty session reports audio")
    empty.remove()
    try check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "sessions left behind")
    print("PASS: session locks, unique names, no overwrite, offline drive fallback, kept on failure and retried")
}

func checkStopRequest() async throws {
    let request = StopRequest()
    request.signal()
    await request.wait()
    let start = Date()
    await request.wait(timeout: 0.2)
    try check(Date().timeIntervalSince(start) >= 0.15, "timeout returned early")
    try check(!request.isRequested, "stop requested by itself")
    request.stop()
    await request.wait()
    try check(request.isRequested, "stop not recorded")
    print("PASS: stop request, signal, timeout")
}

@main struct AudioTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--crash-child" {
            try await crashChild(root: URL(fileURLWithPath: arguments[2]), destination: URL(fileURLWithPath: arguments[3]))
        }
        try checkMuteDetection()
        let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try checkNormalizer()
        try checkDevices()
        try await checkStopRequest()
        try await checkCapture(folder.appendingPathComponent("capture"))
        try await checkUnconfirmedVoice(folder.appendingPathComponent("unconfirmed"))
        try await checkLateDelivery(folder.appendingPathComponent("late"))
        try await checkMuteEdges(folder.appendingPathComponent("edges"))
        try await checkLateStart(folder.appendingPathComponent("late-start"))
        try await checkOffsets(folder.appendingPathComponent("offsets"))
        try await checkSessions(folder.appendingPathComponent("sessions"))
        try await checkCrashRecovery(folder.appendingPathComponent("crash"))
    }
}
