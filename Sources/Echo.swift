import Accelerate
import AVFoundation

/// Complex values in split form, for vDSP.
private final class Spectrum {
    let real: UnsafeMutablePointer<Float>
    let imag: UnsafeMutablePointer<Float>
    let count: Int

    init(_ count: Int) {
        self.count = count
        real = .allocate(capacity: count)
        imag = .allocate(capacity: count)
        clear()
    }

    deinit {
        real.deallocate()
        imag.deallocate()
    }

    var split: DSPSplitComplex { DSPSplitComplex(realp: real, imagp: imag) }

    func clear() {
        real.update(repeating: 0, count: count)
        imag.update(repeating: 0, count: count)
    }

    func copy(_ other: Spectrum) {
        real.update(from: other.real, count: count)
        imag.update(from: other.imag, count: count)
    }
}

/// What the canceller did over a stretch of audio. It is logged: whether echo was removed in
/// a real call can only be told from that call.
struct EchoReport {
    var blocks = 0
    /// Blocks while Zoom played something, and the energy of the microphone, of what went
    /// out and of Zoom's audio over them.
    var playing = 0
    var microphone: Float = 0
    var output: Float = 0
    var reference: Float = 0
    /// Of those, blocks with the echo at least 10 dB down: low while the user talks over a
    /// participant, while a working filter keeps it high whenever they are quiet.
    var cleared = 0
    /// The foreground filter taken over, forgotten as worse than none, and the background
    /// filter started again from it.
    var adopted = 0
    var resets = 0
    var restarts = 0
    /// Broken samples, after which both filters start over.
    var broken = 0
    /// Blocks let out before Zoom's audio of the same moment came in.
    var unreferenced = 0
    /// Blocks that went out as the microphone itself, the filter's output being louder.
    var bypassed = 0
    /// Audio that did not continue the previous run, of the microphone and of Zoom.
    var microphoneRuns = 0
    var referenceRuns = 0
    /// Where the subtracted and the learning filter are strongest, in ms; nil while empty.
    var delay: Double?
    var learning: Double?

    /// How much quieter the output was than the microphone while Zoom played.
    var removed: Double { 10 * log10(Double(max(microphone, 1e-20)) / Double(max(output, 1e-20))) }

    var description: String {
        let level = { (energy: Float) in 10 * log10(Double(max(energy, 1e-20)) / Double(max(self.playing, 1) * EchoCanceller.block)) }
        let path = { (delay: Double?) in delay.map { String(format: "%.0f ms", $0) } ?? "none" }
        return String(format: "Echo: %.0f s, Zoom playing %ld%%, removed %.1f dB, 10 dB down in %ld%% (microphone %.0f dB, Zoom %.0f dB), "
                      + "path %@, learning %@, taken %ld, reset %ld, restarted %ld, broken %ld, unreferenced %ld, bypassed %ld, "
                      + "new runs microphone %ld Zoom %ld",
                      Double(blocks * EchoCanceller.block) / AudioTrack.rate, 100 * playing / max(blocks, 1),
                      playing > 0 ? removed : 0, 100 * cleared / max(playing, 1), level(microphone), level(reference),
                      path(delay), path(learning), adopted, resets, restarts, broken, unreferenced, bypassed,
                      microphoneRuns, referenceRuns)
    }
}

/// Takes the participants the microphone hears from the speakers out of it. Zoom removes
/// them from what it sends, but the recording mixes the raw microphone with Zoom's clean
/// audio, so without this everyone would sound twice, the second time some 50 ms later.
/// An adaptive filter learns the path from Zoom's audio to the microphone and subtracts its
/// estimate (partitioned-block frequency-domain NLMS). A background filter adapts on every
/// block; the foreground filter, the one subtracted, takes its coefficients only while they
/// remove more, so the user speaking over a participant cannot spoil it.
final class EchoCanceller {
    static let block = 512
    /// 32 partitions of `block` samples cover 341 ms of echo path, room for Bluetooth speakers.
    static let partitions = 32
    static let step: Float = 0.5
    /// Microphone audio waits up to 0.5 s for Zoom's audio of the same moment, within the
    /// time it is held for Zoom's mute state anyway.
    static let patience: Int64 = 24_000
    /// Microphone audio within 5 ms of continuing the previous audio does: timestamps jitter,
    /// and a 44.1 kHz microphone converted to 48 kHz slips by a frame now and then. The
    /// smoothed shift follows any real drift.
    static let slip: Int64 = 240
    /// Blocks this close to following on keep the reference history built for them.
    static let jitter: Int64 = 16
    /// How fast a smoothed shift follows timestamps, per buffer: a device clock's drift of
    /// tens of ppm is followed, jitter of a few milliseconds is averaged out.
    static let follow = 0.002
    /// A report is logged every 10 s of microphone audio.
    static let reportFrames = 480_000
    private static let size = 2 * block
    private static let history = 1 << 18
    private let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    private let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
    /// Zoom's audio in mono, at timeline position modulo the ring's length.
    private var reference = [Float](repeating: 0, count: history)
    private var referenceEnd: Int64?
    /// Zoom's audio as one continuous run: where it began, how much of it is written, and how
    /// far its timestamps have drifted from that, smoothed.
    private var referenceRun: (start: Int64, written: Int64, shift: Double)?
    /// Spectra of the reference windows behind the latest block, the newest at `head`.
    private let windows = (0..<partitions).map { _ in Spectrum(size) }
    private var head = 0
    private var lastBlock: Int64?
    private let foreground = (0..<partitions).map { _ in Spectrum(size) }
    private let background = (0..<partitions).map { _ in Spectrum(size) }
    private var errors: (foreground: Float, background: Float, microphone: Float) = (0, 0, 0)
    private var better = 0
    private var worse = 0
    /// Zoom's recent loudness, per block: thresholds follow it, so a quiet Zoom is handled too.
    private var referenceLevel: Float = 0
    private var constrained = 0
    /// Microphone audio waiting for its Zoom audio, as one continuous run: `pendingStart` is
    /// its first sample's place in the run, which `shift` turns into a timeline position.
    private var pending: [Float] = []
    private var pendingStart: Int64 = 0
    /// Frames the microphone's positions slipped by since the run began, and their smoothed
    /// value: jitter of a frame is ignored, the drift of a device's clock is followed.
    private var slips: Int64 = 0
    private var shift: Double = 0
    private var format: AVAudioFormat?
    private var report = EchoReport()
    private(set) var lastReport: EchoReport?
    // Scratch space.
    private let time = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let zeros = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let estimate = Spectrum(size)
    private let gradient = Spectrum(size)
    private let power = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let echoForeground = UnsafeMutablePointer<Float>.allocate(capacity: block)
    private let echoBackground = UnsafeMutablePointer<Float>.allocate(capacity: block)

    init() {
        zeros.update(repeating: 0, count: Self.size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for pointer in [time, imaginary, zeros, power, magnitudes, echoForeground, echoBackground] { pointer.deallocate() }
    }

    /// Zoom's audio at its timeline position.
    func addReference(_ buffer: AVAudioPCMBuffer, at position: Int64) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        // Timestamps jitter by a frame or so while a device clock drifts slowly: each buffer
        // follows on from the previous, moved only by the smoothed drift, as the microphone's do.
        var position = position
        // A whole buffer missing is a real gap, not jitter: tolerance stays below half a buffer.
        if var run = referenceRun, abs(position - (run.start + run.written + Int64(run.shift.rounded()))) <= min(480, Int64(frames) / 2) {
            run.shift += Self.follow * (Double(position - (run.start + run.written)) - run.shift)
            position = run.start + run.written + Int64(run.shift.rounded())
            run.written += Int64(frames)
            referenceRun = run
        } else {
            if referenceRun != nil { report.referenceRuns += 1 }
            referenceRun = (position, Int64(frames), 0)
        }
        // A gap since the last audio is silence, not whatever the ring held before.
        if let end = referenceEnd, position > end {
            for gap in end..<min(position, end + Int64(Self.history)) { reference[Self.index(gap)] = 0 }
        }
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            reference[Self.index(position + Int64(frame))] = sum.isFinite ? sum / Float(channels) : 0
        }
        referenceEnd = max(referenceEnd ?? .min, position + Int64(frames))
    }

    /// Microphone audio in; echo-free blocks out with their timeline positions, each once
    /// Zoom's audio of the same moment is in.
    func process(_ buffer: AVAudioPCMBuffer, at position: Int64) -> [(buffer: AVAudioPCMBuffer, position: Int64)] {
        let first = format == nil
        format = format ?? buffer.format
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        // Audio that does not continue the run, give or take a slipped frame, starts a new one.
        let slip = position - (pendingStart + Int64(pending.count) + slips)
        var done: [(buffer: AVAudioPCMBuffer, position: Int64)] = []
        if abs(slip) <= min(Self.slip, Int64(buffer.frameLength) / 2) {
            slips += slip
            shift += Self.follow * (Double(slips) - shift)
        } else {
            if !first { report.microphoneRuns += 1 }
            done = drain()
            pendingStart = position
            slips = 0
            shift = 0
        }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        done += ready()
        return done
    }

    /// Blocks whose Zoom audio has come in since; with `flushing`, everything left.
    func ready(flushing: Bool = false) -> [(buffer: AVAudioPCMBuffer, position: Int64)] {
        guard let format, !pending.isEmpty else { return [] }
        var done: [(buffer: AVAudioPCMBuffer, position: Int64)] = []
        let offset = Int64(shift.rounded())
        let end = pendingStart + offset + Int64(pending.count)
        var used = 0
        while used < pending.count {
            let start = pendingStart + offset + Int64(used)
            let count = min(Self.block, pending.count - used)
            guard count == Self.block || flushing else { break }
            guard flushing || (referenceEnd ?? .min) >= start + Int64(count) || end - start - Int64(count) >= Self.patience else { break }
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.block)) else { break }
            if (referenceEnd ?? .min) < start + Int64(count) { report.unreferenced += 1 }
            output.frameLength = AVAudioFrameCount(count)
            pending.withUnsafeBufferPointer { input in
                if count == Self.block {
                    cancel(input.baseAddress! + used, at: start, into: output.floatChannelData![0], count: count, adapt: true)
                } else {
                    // The last partial block is padded with silence, which must not train the filter.
                    var padded = [Float](repeating: 0, count: Self.block)
                    padded.replaceSubrange(0..<count, with: input[used..<used + count])
                    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.block)
                    defer { scratch.deallocate() }
                    cancel(padded, at: start, into: scratch, count: count, adapt: false)
                    output.floatChannelData![0].update(from: scratch, count: count)
                    lastBlock = nil
                }
            }
            done.append((output, start))
            used += count
        }
        pending.removeFirst(used)
        pendingStart += Int64(used)
        return done
    }

    func drain() -> [(buffer: AVAudioPCMBuffer, position: Int64)] { ready(flushing: true) }

    private static func index(_ position: Int64) -> Int {
        let length = Int64(history)
        return Int((position % length + length) % length)
    }

    /// Writes into `time` Zoom's audio for the `size` samples that end at `end`.
    private func window(endingAt end: Int64) {
        for offset in 0..<Self.size {
            let position = end - Int64(Self.size) + Int64(offset)
            let known = referenceEnd.map { position < $0 && position >= $0 - Int64(Self.history) } ?? false
            time[offset] = known ? reference[Self.index(position)] : 0
        }
    }

    private func transform(_ input: UnsafePointer<Float>, into output: Spectrum) {
        vDSP_DFT_Execute(forward, input, zeros, output.real, output.imag)
    }

    /// The real part of the inverse transform, scaled, into `time`.
    private func restore(_ input: Spectrum) {
        vDSP_DFT_Execute(inverse, input.real, input.imag, time, imaginary)
        var scale = 1 / Float(Self.size)
        vDSP_vsmul(time, 1, &scale, time, 1, vDSP_Length(Self.size))
    }

    /// Adds the newest reference window ending at `end`, dropping the oldest.
    private func push(endingAt end: Int64) {
        head = (head + Self.partitions - 1) % Self.partitions
        window(endingAt: end)
        transform(time, into: windows[head])
    }

    /// The echo `filter` predicts for the latest block, into `output`.
    private func predict(_ filter: [Spectrum], into output: UnsafeMutablePointer<Float>) {
        estimate.clear()
        var sum = estimate.split
        var total = estimate.split
        for partition in 0..<Self.partitions {
            var coefficients = filter[partition].split
            var spectrum = windows[(head + partition) % Self.partitions].split
            vDSP_zvma(&coefficients, 1, &spectrum, 1, &sum, 1, &total, 1, vDSP_Length(Self.size))
        }
        restore(estimate)
        output.update(from: time + Self.block, count: Self.block)
    }

    /// Cancels one block, of which the first `count` samples are real audio.
    private func cancel(_ microphone: UnsafePointer<Float>, at start: Int64, into output: UnsafeMutablePointer<Float>,
                        count: Int, adapt: Bool) {
        let block = Int64(Self.block)
        let blockLength = vDSP_Length(Self.block)
        defer { if report.blocks * Self.block >= Self.reportFrames { finishReport() } }
        if lastBlock.map({ abs(start - block - $0) > Self.jitter }) ?? true {
            // Not right after the previous block: rebuild the history at these positions.
            for partition in stride(from: Self.partitions - 1, through: 1, by: -1) { push(endingAt: start + block - Int64(partition) * block) }
        }
        push(endingAt: start + block)
        lastBlock = start
        predict(foreground, into: echoForeground)
        predict(background, into: echoBackground)
        // The errors: the microphone less each filter's estimate.
        vDSP_vsub(echoForeground, 1, microphone, 1, echoForeground, 1, blockLength)
        vDSP_vsub(echoBackground, 1, microphone, 1, echoBackground, 1, blockLength)
        var foregroundEnergy: Float = 0, backgroundEnergy: Float = 0, microphoneEnergy: Float = 0, referenceEnergy: Float = 0
        vDSP_svesq(echoForeground, 1, &foregroundEnergy, blockLength)
        vDSP_svesq(echoBackground, 1, &backgroundEnergy, blockLength)
        vDSP_svesq(microphone, 1, &microphoneEnergy, blockLength)
        window(endingAt: start + block)
        vDSP_svesq(time + Self.block, 1, &referenceEnergy, blockLength)
        report.blocks += 1
        guard microphoneEnergy.isFinite, foregroundEnergy.isFinite, backgroundEnergy.isFinite else {
            // Broken samples teach nothing, and the filters must not keep them.
            output.update(from: microphone, count: Self.block)
            report.broken += 1
            if !foregroundEnergy.isFinite || !backgroundEnergy.isFinite { reset() }
            return
        }
        referenceLevel = 0.99 * referenceLevel + 0.01 * referenceEnergy
        // Learn only while Zoom plays something: silence teaches nothing.
        let playing = referenceEnergy > max(1e-10 * Float(Self.block), 0.01 * referenceLevel)
        if adapt, playing {
            time.update(repeating: 0, count: Self.block)
            (time + Self.block).update(from: echoBackground, count: Self.block)
            transform(time, into: gradient)
            // Normalized by the reference power over all partitions, with a floor for near silence.
            power.update(repeating: max(1e-9, 2e-3 * Float(Self.partitions) * referenceLevel), count: Self.size)
            for partition in 0..<Self.partitions {
                var spectrum = windows[partition].split
                vDSP_zvmags(&spectrum, 1, magnitudes, 1, vDSP_Length(Self.size))
                vDSP_vadd(magnitudes, 1, power, 1, power, 1, vDSP_Length(Self.size))
            }
            vDSP_vdiv(power, 1, gradient.real, 1, gradient.real, 1, vDSP_Length(Self.size))
            vDSP_vdiv(power, 1, gradient.imag, 1, gradient.imag, 1, vDSP_Length(Self.size))
            var step = Self.step
            vDSP_vsmul(gradient.real, 1, &step, gradient.real, 1, vDSP_Length(Self.size))
            vDSP_vsmul(gradient.imag, 1, &step, gradient.imag, 1, vDSP_Length(Self.size))
            var update = gradient.split
            for partition in 0..<Self.partitions {
                var spectrum = windows[(head + partition) % Self.partitions].split
                var coefficients = background[partition].split
                var result = background[partition].split
                vDSP_zvcma(&spectrum, 1, &update, 1, &coefficients, 1, &result, 1, vDSP_Length(Self.size))
            }
            // Keep a few partitions a linear, not circular, convolution on every block.
            for _ in 0..<4 {
                let partition = constrained % Self.partitions
                constrained += 1
                restore(background[partition])
                (time + Self.block).update(repeating: 0, count: Self.block)
                transform(time, into: background[partition])
            }
        }
        errors.foreground = 0.7 * errors.foreground + 0.3 * foregroundEnergy
        errors.background = 0.7 * errors.background + 0.3 * backgroundEnergy
        errors.microphone = 0.7 * errors.microphone + 0.3 * microphoneEnergy
        // Only a background filter that clearly removes echo is taken over: while the user talks,
        // what is left is mostly their voice, and a filter that lowered it would eat into it.
        better = errors.background < 0.8 * errors.foreground && errors.background < 0.5 * errors.microphone ? better + 1 : 0
        // A foreground worse than none at all, as after putting on headphones or turning the
        // volume down, is forgotten: otherwise it would add the participant to the user's voice.
        // Pauses in Zoom's audio do not count either way.
        if adapt, playing { worse = errors.foreground > errors.microphone ? worse + 1 : 0 }
        if worse >= 40 {
            report.resets += 1
            reset()
        } else if better >= 3 {
            report.adopted += 1
            for partition in 0..<Self.partitions { foreground[partition].copy(background[partition]) }
            errors.foreground = errors.background
            better = 0
        } else if errors.background > 2 * errors.foreground {
            // The background filter learned the user's voice as echo: start it again from the foreground.
            report.restarts += 1
            for partition in 0..<Self.partitions { background[partition].copy(foreground[partition]) }
            errors.background = errors.foreground
        }
        // Never louder than the microphone itself, judged on the real samples of a padded block.
        var foregroundReal: Float = 0, microphoneReal: Float = 0
        vDSP_svesq(echoForeground, 1, &foregroundReal, vDSP_Length(count))
        vDSP_svesq(microphone, 1, &microphoneReal, vDSP_Length(count))
        let filtered = foregroundReal <= microphoneReal
        output.update(from: filtered ? UnsafePointer(echoForeground) : microphone, count: Self.block)
        if !filtered { report.bypassed += 1 }
        if playing {
            report.playing += 1
            report.microphone += microphoneEnergy
            report.output += filtered ? foregroundEnergy : microphoneEnergy
            report.reference += referenceEnergy
            if filtered, foregroundEnergy * 10 <= microphoneEnergy { report.cleared += 1 }
        }
    }

    /// Logs what is left of the current report, as when a stream ends.
    func flushReport() {
        if report.blocks > 0 { finishReport() }
    }

    /// Logs what the canceller did since the last report and starts a new one.
    private func finishReport() {
        report.delay = strongest(foreground)
        report.learning = strongest(background)
        recorderLog.notice(report.description)
        lastReport = report
        report = EchoReport()
    }

    /// Where `filter` is strongest, in ms: the delay of the path it learned. Taps beyond the first
    /// half of a partition are wrap-around the constraint has not cleared yet, not delay.
    private func strongest(_ filter: [Spectrum]) -> Double? {
        var strongest: (tap: Int, value: Float) = (0, 0)
        for partition in 0..<Self.partitions {
            restore(filter[partition])
            for tap in 0..<Self.block where abs(time[tap]) > strongest.value {
                strongest = (partition * Self.block + tap, abs(time[tap]))
            }
        }
        return strongest.value > 0 ? Double(strongest.tap) / AudioTrack.rate * 1000 : nil
    }

    private func reset() {
        for partition in 0..<Self.partitions {
            foreground[partition].clear()
            background[partition].clear()
        }
        let level = errors.microphone.isFinite ? errors.microphone : 0
        errors = (level, level, level)
        better = 0
        worse = 0
    }
}
