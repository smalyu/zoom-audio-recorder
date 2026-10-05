import Foundation
import AVFoundation
import CoreMedia

enum TestError: Error { case failed(String) }
func check(_ value: Bool, _ message: String) throws {
    if !value { throw TestError.failed(message) }
}
func bytes(_ sample: CMSampleBuffer) -> [UInt8] {
    let block = CMSampleBufferGetDataBuffer(sample)!
    var result = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    result.withUnsafeMutableBytes { buffer in
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count, destination: buffer.baseAddress!)
    }
    return result
}
func sample(frequency: Double, index: Int, unsigned8: Bool = false) throws -> CMSampleBuffer {
    let frames = 4800
    let width = unsigned8 ? 1 : 2
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: unsigned8 ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(width), mFramesPerPacket: 1, mBytesPerFrame: UInt32(width),
        mChannelsPerFrame: 1, mBitsPerChannel: UInt32(width * 8), mReserved: 0)
    var format: CMAudioFormatDescription?
    try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format) == noErr, "format")
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: nil, blockLength: frames * width, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: frames * width,
        flags: 0, blockBufferOut: &block) == noErr, "block")
    if unsigned8 {
        _ = CMBlockBufferFillDataBytes(with: 100, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames)
    } else {
        let values = (0..<frames).map { offset in
            Int16(sin(2 * .pi * frequency * Double(index * frames + offset) / 48000) * 6500)
        }
        values.withUnsafeBytes { buffer in
            _ = CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: buffer.count)
        }
    }
    var result: CMSampleBuffer?
    try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
        dataBuffer: block!, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: CMTime(value: Int64(4800000 + index * frames), timescale: 48000),
        packetDescriptions: nil, sampleBufferOut: &result) == noErr, "sample")
    return result!
}
func tone(_ buffer: AVAudioPCMBuffer, at seconds: Double, frequency: Double) -> Double {
    let rate = buffer.format.sampleRate
    let start = Int(seconds * rate)
    let count = min(Int(rate * 0.2), Int(buffer.frameLength) - start)
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
@main struct AudioTests {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try sample(frequency: 880, index: 0)
        let before = bytes(original)
        let quiet = try silence(original)
        try check(bytes(quiet).allSatisfy { $0 == 0 }, "muted PCM contains sound")
        try check(bytes(original) == before, "source was modified")
        try check(CMSampleBufferGetPresentationTimeStamp(quiet) == CMSampleBufferGetPresentationTimeStamp(original), "timing changed")
        try check(CMSampleBufferGetNumSamples(quiet) == 4800, "sample count changed")
        try check(bytes(try silence(sample(frequency: 0, index: 0, unsigned8: true))).allSatisfy { $0 == 128 }, "8-bit silence wrong")

        let zoom = AudioFile(url: folder.appendingPathComponent("zoom.m4a"), realtime: false)
        let mic = AudioFile(url: folder.appendingPathComponent("mic.m4a"), realtime: false)
        for index in 0..<40 {
            while !zoom.canAcceptSample || !mic.canAcceptSample {
                try await Task.sleep(for: .milliseconds(5))
            }
            zoom.append(try sample(frequency: 440, index: index))
            let input = try sample(frequency: 880, index: index)
            mic.append((index < 5 || (10..<20).contains(index) || index >= 30) ? try silence(input) : input)
        }
        let hasZoom = try await zoom.finish()
        let hasMic = try await mic.finish()
        try check(hasZoom && hasMic, "writers empty")
        let output = folder.appendingPathComponent("mixed.m4a")
        try await saveAudio(zoom: zoom.url, mic: mic.url, output: output, delayMilliseconds: 250)
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        try check(audio.count == 1 && video.isEmpty, "expected one audio track and no video")
        try check(abs(duration - 4.25) < 0.1, "incorrect mixed duration: \(duration)")
        let file = try AVAudioFile(forReading: output)
        let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: decoded)
        for time in [0.05, 0.35, 1.5, 3.5] {
            try check(tone(decoded, at: time, frequency: 880) < 0.003, "microphone audible during mute at \(time)")
        }
        for time in [0.85, 2.5] {
            try check(tone(decoded, at: time, frequency: 880) > 0.09, "microphone missing or shifted at \(time)")
        }
        try check(tone(decoded, at: 1.5, frequency: 440) > 0.09, "Zoom lost while mic muted")
        let remoteOnly = folder.appendingPathComponent("remote-only.m4a")
        try await saveAudio(zoom: zoom.url, mic: nil, output: remoteOnly, delayMilliseconds: 0)
        try check(Data(contentsOf: remoteOnly) == Data(contentsOf: zoom.url), "remote-only data changed")
        print("PASS: PCM silence, source preservation, timestamps, mute gaps, delayed mix, one audio track, zero video, remote-only export")
    }
}
