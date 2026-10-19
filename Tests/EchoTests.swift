import AVFoundation
import Foundation

/// Speech-like noise: bursts of a few hundred milliseconds, low-passed to below 4 kHz.
func babble(seconds: Int, seed: UInt64) -> [Float] {
    var state = seed
    var smooth: Float = 0
    return (0..<seconds * 48_000).map { index in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
        smooth += 0.45 * (noise - smooth)
        let syllable = sin(Double(index) / 48_000 * .pi * 3.1 + Double(seed)) > -0.2
        return syllable ? smooth * 0.3 : 0
    }
}

/// Echo removed from a participant heard through the speakers, the user's voice untouched,
/// every sample out once at its own position.
func checkEchoCanceller() throws {
    let rate = 48_000
    let far = babble(seconds: 16, seed: 1)
    var near = [Float](repeating: 0, count: far.count)
    near.replaceSubrange(12 * rate..<16 * rate, with: babble(seconds: 4, seed: 2))
    // 51 ms from the speakers to the microphone, a reflection and a short tail.
    var echo = [Float](repeating: 0, count: far.count)
    for (lag, gain) in [(2448, Float(0.4)), (2600, 0.15), (3100, -0.08), (4000, 0.04)] {
        for index in lag..<far.count { echo[index] += gain * far[index - lag] }
    }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
    func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        result.frameLength = AVAudioFrameCount(samples.count)
        for (offset, sample) in samples.enumerated() { result.floatChannelData![0][offset] = sample }
        return result
    }
    var report: EchoReport?
    /// `slipping`: timestamps jitter, the microphone's by up to 20 frames and Zoom's by a few.
    func run(_ microphone: [Float], slipping: Bool = false) throws -> [Float] {
        let canceller = EchoCanceller()
        var output = [Float](repeating: 0, count: microphone.count)
        var filled = [Bool](repeating: false, count: microphone.count)
        var written = 0
        func take(_ blocks: [(buffer: AVAudioPCMBuffer, position: Int64)]) throws {
            for block in blocks {
                written += Int(block.buffer.frameLength)
                for offset in 0..<Int(block.buffer.frameLength) {
                    let index = Int(block.position) + offset
                    guard output.indices.contains(index) else { continue }
                    try check(slipping || !filled[index], "sample \(index) written twice")
                    filled[index] = true
                    output[index] = block.buffer.floatChannelData![0][offset]
                }
            }
        }
        // The microphone in 960-frame buffers; Zoom's audio in 1024-frame ones, a little behind.
        var zoomAt = 0
        for (number, start) in stride(from: 0, to: microphone.count, by: 960).enumerated() {
            let slip = slipping ? [0, 20, 0, -20, 0, 1, -1][number % 7] : 0
            try take(canceller.process(buffer(microphone[start..<min(start + 960, microphone.count)]), at: Int64(start + slip)))
            while zoomAt + 1024 <= start {
                let jitter = slipping ? [0, 3, -3, 1, 0, -2, 2][(zoomAt / 1024) % 7] : 0
                canceller.addReference(buffer(far[zoomAt..<zoomAt + 1024]), at: Int64(zoomAt + jitter))
                zoomAt += 1024
                try take(canceller.ready())
            }
        }
        canceller.addReference(buffer(far[zoomAt...]), at: Int64(zoomAt))
        try take(canceller.drain())
        try check(written == microphone.count, "\(written) samples out of \(microphone.count)")
        try check(slipping || !filled.contains(false), "samples missing from the output")
        report = canceller.lastReport
        return output.map { $0.isFinite ? $0 : 0 }
    }
    func db(_ signal: [Float], _ noise: [Float], _ seconds: Range<Int>) -> Double {
        let range = seconds.lowerBound * rate..<seconds.upperBound * rate
        let power = { (x: [Float]) in range.reduce(0.0) { $0 + Double(x[$1] * x[$1]) } }
        return 10 * log10(power(signal) / max(power(noise), 1e-20))
    }
    let output = try run(zip(echo, near).map(+))
    let left = zip(output, near).map(-)
    // The 16 s are reported every 10 s: the participant playing, the echo removed, the speakers' path found.
    try check(report.map { $0.playing > 0 && $0.removed > 6 && $0.cleared > 0 && abs(($0.delay ?? 0) - 51) < 1 } == true,
              "report: \(report?.description ?? "none")")
    try check(db(echo, left, 6..<12) > 15, "echo removed by only \(db(echo, left, 6..<12)) dB")
    try check(db(near, left, 12..<16) > 6, "the user's voice over a participant lost: \(db(near, left, 12..<16)) dB")
    // With headphones the microphone hears no one: what it records stays as it was.
    let quiet = try run(near)
    try check(db(near, zip(quiet, near).map(-), 12..<16) > 40, "the voice changed without any echo")
    // Headphones put on mid-call: the filter forgets the speakers instead of adding them to the voice.
    let unplugged = try run((0..<far.count).map { $0 < 8 * rate ? echo[$0] : near[$0] })
    try check(db(near, zip(unplugged, near).map(-), 12..<16) > 40, "the voice changed after the echo stopped")
    // Jittering timestamps of the microphone and of Zoom keep it cancelling.
    let slipped = try run(echo, slipping: true)
    try check(report.map { $0.microphoneRuns == 0 && $0.referenceRuns == 0 } == true, "jitter started new runs: \(report?.description ?? "none")")
    try check(db(echo, slipped, 6..<12) > 15, "with slipping positions echo removed by only \(db(echo, slipped, 6..<12)) dB")
    // A broken sample neither stops the filter nor spreads.
    var broken = echo
    broken[rate / 2] = .nan
    let recovered = try run(broken)
    try check(db(echo, recovered, 6..<12) > 15, "after a broken sample echo removed by only \(db(echo, recovered, 6..<12)) dB")
    print("PASS: echo cancellation removes the speakers, keeps the user's voice and every sample, recovers from headphones, slips and broken samples")
}

/// The recording's microphone track is echo-free; the safety copy keeps the raw microphone.
func checkCaptureEcho(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    var polls = MutePolls { _ in true }
    capture.muteTimeline = { _ in polls.timeline }
    let far = babble(seconds: 10, seed: 3)
    var heard = [Float](repeating: 0, count: far.count)
    for index in 2448..<far.count { heard[index] = 0.4 * far[index - 2448] }
    let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    func sample(_ values: ArraySlice<Float>, format: AVAudioFormat, at start: Int) throws -> CMSampleBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        for channel in 0..<Int(format.channelCount) {
            for (offset, value) in values.enumerated() { buffer.floatChannelData![channel][offset] = value }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTime(value: Int64(48_000_000 + start), timescale: 48_000),
                                        decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        try check(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                       refcon: nil, formatDescription: format.formatDescription, sampleCount: values.count,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                       sampleSizeArray: nil, sampleBufferOut: &result) == noErr, "sample")
        try check(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: kCFAllocatorDefault,
                                                                 blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                 bufferList: buffer.audioBufferList) == noErr, "sample data")
        return result!
    }
    for start in stride(from: 0, to: far.count, by: 4800) {
        clock = Double(start + 4800) / 48_000
        polls.advance(to: clock)
        capture.receive(try sample(far[start..<start + 4800], format: stereo, at: start), of: .audio)
        capture.receive(try sample(heard[start..<start + 4800], format: mono, at: start), of: .microphone)
    }
    polls.advance(to: clock + 0.6)
    capture.releaseVoice(flushing: true)
    await capture.zoom.finish()
    await capture.mic.finish()
    await capture.raw.finish()
    let level = { (name: String) throws -> Double in
        let decoded = try decode(AudioTrack.parts(named: name, in: folder)[0].url)
        let range = 5 * 48_000..<9 * 48_000
        return range.reduce(0.0) { $0 + Double(decoded.floatChannelData![0][$1] * decoded.floatChannelData![0][$1]) }
    }
    let removed = 10 * log10(try level("raw") / max(try level("mic"), 1e-20))
    try check(removed > 15, "the microphone track kept the speakers: \(removed) dB removed")
    print("PASS: the recording's microphone is echo-free and its safety copy is not")
}
