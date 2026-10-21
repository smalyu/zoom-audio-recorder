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
    /// Energy into and out of the suppressor while Zoom played.
    var suppressedFrom: Float = 0
    var suppressedTo: Float = 0
    /// Where the subtracted and the learning filter are strongest, in ms; nil while empty.
    var delay: Double?
    var learning: Double?

    /// How much quieter the filter's output was than the microphone while Zoom played.
    var removed: Double { 10 * log10(Double(max(microphone, 1e-20)) / Double(max(output, 1e-20))) }
    /// How much quieter the suppressor made that.
    var suppressed: Double { suppressedFrom > 0 ? 10 * log10(Double(suppressedFrom) / Double(max(suppressedTo, 1e-20))) : 0 }

    var description: String {
        let level = { (energy: Float) in 10 * log10(Double(max(energy, 1e-20)) / Double(max(self.playing, 1) * EchoCanceller.block)) }
        let path = { (delay: Double?) in delay.map { String(format: "%.0f ms", $0) } ?? "none" }
        return String(format: "Echo: %.0f s, Zoom playing %ld%%, removed %.1f dB, then suppressed %.1f dB, 10 dB down in %ld%% (microphone %.0f dB, Zoom %.0f dB), "
                      + "path %@, learning %@, taken %ld, reset %ld, restarted %ld, broken %ld, unreferenced %ld, bypassed %ld, "
                      + "new runs microphone %ld Zoom %ld",
                      Double(blocks * EchoCanceller.block) / AudioTrack.rate, 100 * playing / max(blocks, 1),
                      playing > 0 ? removed : 0, suppressed, 100 * cleared / max(playing, 1), level(microphone), level(reference),
                      path(delay), path(learning), adopted, resets, restarts, broken, unreferenced, bypassed,
                      microphoneRuns, referenceRuns)
    }
}

/// Turns down what the adaptive filter leaves of the echo. Loud laptop speakers distort, and a
/// path changes before the filter follows it; in a real call that left a copy of everyone some
/// 20 dB down, still audible. Each frequency is turned down by the share of it that is echo,
/// estimated as a fraction of the filter's own echo estimate. The fraction is learned per band
/// two ways, and the larger is taken: as how much the leftover rises and falls with that
/// estimate, which the user's voice, unrelated to Zoom's audio, does not bias, and which tells
/// a leftover that follows the estimate's every moment; and as the leftover's lowest share of
/// the estimate in the last seconds, between the user's words, which tells distortion that only
/// follows its loudness. Moments that are almost all echo are turned down harder than ones with
/// the user's voice in them. Works on half-overlapping windows, so each block comes out one
/// block later.
private final class EchoSuppressor {
    private static let block = EchoCanceller.block
    private static let size = 2 * block
    private static let bins = block + 1
    /// Bands the echo's fraction is learned over, about a third of an octave wide above 500 Hz.
    private static let edges = [0, 2, 4, 6, 8, 11, 14, 18, 23, 29, 36, 45, 56, 70, 87, 108, 134, 166, 206, 256, 318, 395, bins]
    private static let bandOf: [Int] = (0..<bins).map { bin in edges.lastIndex { $0 <= bin }! }
    /// The leftover is overstated: its fraction is an average, and each moment varies. While
    /// the filter's output is within `echoing` times the leftover, it is all echo and overstated
    /// by `harder`; from `talking` times on, the user is talking, and it is overstated by `gently`.
    private static let gently: Float = 2
    private static let harder: Float = 16
    private static let echoing: Float = 1
    private static let talking: Float = 4
    /// No frequency is turned down by more than 30 dB.
    private static let floor: Float = 0.03
    /// How much a frequency's gain leans on what it let out before, against music-like flutter.
    private static let memory: Float = 0.7
    /// How much the powers a gain is judged on lean on the previous window.
    private static let smoothing: Float = 0.5
    /// The fraction stays between 26 dB down and the whole estimate.
    private static let least: Float = 0.0025
    /// How fast the fraction is learned per block: fast while the estimate dominates what is
    /// left, slow while the user talks over a participant (as Speex's echo canceller does).
    private static let learning: Float = 2 * Float(block) / 48_000
    private static let fastest: Float = 0.5 * Float(block) / 48_000
    /// How fast the averages the rises and falls are measured from follow the audio.
    private static let averaging: Float = Float(block) / 48_000
    /// The lowest share is taken over 8 stretches of 28 blocks, 2.4 s, from band powers smoothed
    /// over a few blocks, in blocks where the estimate is not far below its usual level, and
    /// doubled: the lowest of varying values lies below their usual one.
    private static let stretch = 28
    private static let stretches = 8
    private static let shareSmoothing: Float = 0.7
    private static let present: Float = 1e-3
    private static let lowestBias: Float = 2
    private let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    private let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
    /// Square root of a periodic Hann window: windowing on the way in and out adds up to one.
    private let window = (0..<size).map { Float(sin(Double.pi * Double($0) / Double(size))) }
    private var previous = [Float](repeating: 0, count: block)
    private var previousEcho = [Float](repeating: 0, count: block)
    /// The second half of the last window, waiting for the next one to complete its block.
    private var tail = [Float](repeating: 0, count: block)
    /// Whether a block waits for the next one.
    private(set) var holding = false
    private var meanSignal = [Float](repeating: 0, count: bins)
    private var meanEcho = [Float](repeating: 0, count: bins)
    private var covariance = [Float](repeating: 0, count: edges.count - 1)
    private var variance = [Float](repeating: 0, count: edges.count - 1)
    private var fraction = [Float](repeating: EchoSuppressor.least, count: edges.count - 1)
    /// Band powers of the leftover and the estimate, smoothed; the estimate's usual level.
    private var bandSignal = [Float](repeating: 0, count: edges.count - 1)
    private var bandEcho = [Float](repeating: 0, count: edges.count - 1)
    private var usualEcho = [Float](repeating: 0, count: edges.count - 1)
    /// The lowest share in each of the last stretches, the newest first, and in the current one.
    private var lowest = [[Float]](repeating: [Float](repeating: .infinity, count: edges.count - 1), count: stretches)
    private var lowestNow = [Float](repeating: .infinity, count: edges.count - 1)
    private var stretchBlocks = 0
    /// What each frequency let out last time, for the next gain.
    private var kept = [Float](repeating: 0, count: bins)
    /// Energy of the last window before and after.
    private(set) var energy: (input: Float, output: Float) = (0, 0)
    private let signal = Spectrum(size)
    private let echo = Spectrum(size)
    private let time = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let zeros = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private var gains = [Float](repeating: 1, count: bins)
    private var signalPower = [Float](repeating: 0, count: bins)
    private var echoPower = [Float](repeating: 0, count: bins)
    private var smoothSignal = [Float](repeating: 0, count: bins)
    private var smoothEcho = [Float](repeating: 0, count: bins)
    private var leftover = [Float](repeating: 0, count: bins)

    init() {
        zeros.update(repeating: 0, count: Self.size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for pointer in [time, zeros, imaginary] { pointer.deallocate() }
    }

    /// Takes the filter's next block and its echo estimate; writes the block before it, finished,
    /// into `finished` and says whether there was one. `learn` while the filter is trustworthy.
    func process(_ input: UnsafePointer<Float>, echo estimate: UnsafePointer<Float>, learn: Bool,
                 into finished: UnsafeMutablePointer<Float>) -> Bool {
        let block = Self.block
        // Broken samples are silence here: a transform would spread them over two blocks.
        let clean = { (value: Float) in value.isFinite ? value : 0 }
        for index in 0..<block {
            time[index] = previous[index] * window[index]
            time[block + index] = clean(input[index]) * window[block + index]
        }
        vDSP_DFT_Execute(forward, time, zeros, signal.real, signal.imag)
        for index in 0..<block {
            time[index] = previousEcho[index] * window[index]
            time[block + index] = clean(estimate[index]) * window[block + index]
        }
        vDSP_DFT_Execute(forward, time, zeros, echo.real, echo.imag)
        for index in 0..<block {
            previous[index] = clean(input[index])
            previousEcho[index] = clean(estimate[index])
        }
        var inputEnergy: Float = 0, outputEnergy: Float = 0, echoEnergy: Float = 0
        for bin in 0..<Self.bins {
            signalPower[bin] = signal.real[bin] * signal.real[bin] + signal.imag[bin] * signal.imag[bin]
            echoPower[bin] = echo.real[bin] * echo.real[bin] + echo.imag[bin] * echo.imag[bin]
            inputEnergy += signalPower[bin]
            echoEnergy += echoPower[bin]
        }
        if learn {
            let rate = min(Self.learning * echoEnergy / max(inputEnergy, 1e-20), Self.fastest)
            for band in 0..<fraction.count {
                var cross: Float = 0, square: Float = 0, bandSignalNow: Float = 0, bandEchoNow: Float = 0
                for bin in Self.edges[band]..<Self.edges[band + 1] {
                    let rise = echoPower[bin] - meanEcho[bin]
                    cross += (signalPower[bin] - meanSignal[bin]) * rise
                    square += rise * rise
                    bandSignalNow += signalPower[bin]
                    bandEchoNow += echoPower[bin]
                }
                covariance[band] += rate * (cross - covariance[band])
                variance[band] += rate * (square - variance[band])
                bandSignal[band] = Self.shareSmoothing * bandSignal[band] + (1 - Self.shareSmoothing) * bandSignalNow
                bandEcho[band] = Self.shareSmoothing * bandEcho[band] + (1 - Self.shareSmoothing) * bandEchoNow
                usualEcho[band] = 0.99 * usualEcho[band] + 0.01 * bandEchoNow
                if bandEcho[band] > Self.present * usualEcho[band], bandEcho[band] > 0 {
                    lowestNow[band] = min(lowestNow[band], bandSignal[band] / bandEcho[band])
                }
                let following = variance[band] > 0 ? covariance[band] / variance[band] : 0
                let lowestShare = lowest.reduce(lowestNow[band]) { min($0, $1[band]) }
                let share = max(following, lowestShare.isFinite ? Self.lowestBias * lowestShare : 0)
                fraction[band] = min(max(share, Self.least), 1)
            }
            for bin in 0..<Self.bins {
                meanSignal[bin] += Self.averaging * (signalPower[bin] - meanSignal[bin])
                meanEcho[bin] += Self.averaging * (echoPower[bin] - meanEcho[bin])
            }
            stretchBlocks += 1
            if stretchBlocks == Self.stretch {
                lowest.removeLast()
                lowest.insert(lowestNow, at: 0)
                lowestNow = [Float](repeating: .infinity, count: fraction.count)
                stretchBlocks = 0
            }
        }
        var signalTotal: Float = 0, leftoverTotal: Float = 0
        for bin in 0..<Self.bins {
            smoothSignal[bin] = Self.smoothing * smoothSignal[bin] + (1 - Self.smoothing) * signalPower[bin]
            smoothEcho[bin] = Self.smoothing * smoothEcho[bin] + (1 - Self.smoothing) * echoPower[bin]
            leftover[bin] = fraction[Self.bandOf[bin]] * smoothEcho[bin]
            signalTotal += smoothSignal[bin]
            leftoverTotal += leftover[bin]
        }
        let echoing = min(max((Self.talking - signalTotal / max(leftoverTotal, 1e-20)) / (Self.talking - Self.echoing), 0), 1)
        let overstate = Self.gently + (Self.harder - Self.gently) * echoing
        // A Wiener gain from the share of each frequency that is not echo, leaning on what it
        // let out last time (decision-directed), never below the floor.
        for bin in 0..<Self.bins {
            let echoPart = overstate * leftover[bin] + 1e-20
            let now = max(smoothSignal[bin] / echoPart - 1, 0)
            let ratio = Self.memory * kept[bin] / echoPart + (1 - Self.memory) * now
            let gain = max(ratio / (1 + ratio), Self.floor)
            gains[bin] = gain
            kept[bin] = gain * gain * smoothSignal[bin]
            outputEnergy += gain * gain * signalPower[bin]
        }
        energy = (inputEnergy, outputEnergy)
        for bin in 0..<Self.bins {
            signal.real[bin] *= gains[bin]
            signal.imag[bin] *= gains[bin]
            if bin > 0, bin < Self.block {
                signal.real[Self.size - bin] *= gains[bin]
                signal.imag[Self.size - bin] *= gains[bin]
            }
        }
        vDSP_DFT_Execute(inverse, signal.real, signal.imag, time, imaginary)
        let wasHolding = holding
        for index in 0..<Self.size { time[index] *= window[index] / Float(Self.size) }
        if wasHolding {
            for index in 0..<block { finished[index] = tail[index] + time[index] }
        }
        for index in 0..<block { tail[index] = time[block + index] }
        holding = true
        return wasHolding
    }

    /// Finishes the block that waits, as the last one of a run, and starts over.
    func flush(into finished: UnsafeMutablePointer<Float>) -> Bool {
        guard holding else { return false }
        _ = process(zeros, echo: zeros, learn: false, into: finished)
        holding = false
        previous = [Float](repeating: 0, count: Self.block)
        previousEcho = previous
        tail = previous
        kept = [Float](repeating: 0, count: Self.bins)
        smoothSignal = kept
        smoothEcho = kept
        return true
    }
}

/// Takes the participants the microphone hears from the speakers out of it. Zoom removes
/// them from what it sends, but the recording mixes the raw microphone with Zoom's clean
/// audio, so without this everyone would sound twice, the second time some 50 ms later.
/// An adaptive filter learns the path from Zoom's audio to the microphone and subtracts its
/// estimate (partitioned-block frequency-domain NLMS). A background filter adapts on every
/// block; the foreground filter, the one subtracted, takes its coefficients only while they
/// remove more, so the user speaking over a participant cannot spoil it. What the filter
/// leaves of the echo is then turned down per frequency (`EchoSuppressor`).
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
    /// The foreground filter's echo estimate for the latest block, and what it left.
    private let echoEstimate = UnsafeMutablePointer<Float>.allocate(capacity: block)
    private let linear = UnsafeMutablePointer<Float>.allocate(capacity: block)
    private let finished = UnsafeMutablePointer<Float>.allocate(capacity: block)
    private let suppressor: EchoSuppressor?
    /// The block the suppressor holds until the next one: its position and real samples.
    private var held: (start: Int64, count: Int)?

    /// `suppressing`: whether what the filter leaves of the echo is turned down too.
    init(suppressing: Bool = true) {
        suppressor = suppressing ? EchoSuppressor() : nil
        zeros.update(repeating: 0, count: Self.size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for pointer in [time, imaginary, zeros, power, magnitudes, echoForeground, echoBackground, echoEstimate, linear, finished] {
            pointer.deallocate()
        }
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
        guard let format else { return [] }
        var done: [(buffer: AVAudioPCMBuffer, position: Int64)] = []
        let offset = Int64(shift.rounded())
        let end = pendingStart + offset + Int64(pending.count)
        var used = 0
        while used < pending.count {
            let start = pendingStart + offset + Int64(used)
            let count = min(Self.block, pending.count - used)
            guard count == Self.block || flushing else { break }
            guard flushing || (referenceEnd ?? .min) >= start + Int64(count) || end - start - Int64(count) >= Self.patience else { break }
            if (referenceEnd ?? .min) < start + Int64(count) { report.unreferenced += 1 }
            let state = pending.withUnsafeBufferPointer { input in
                if count == Self.block {
                    return cancel(input.baseAddress! + used, at: start, count: count, adapt: true)
                }
                // The last partial block is padded with silence, which must not train the filter.
                var padded = [Float](repeating: 0, count: Self.block)
                padded.replaceSubrange(0..<count, with: input[used..<used + count])
                lastBlock = nil
                return cancel(padded, at: start, count: count, adapt: false)
            }
            if let block = suppress(start: start, count: count, state: state, format: format) { done.append(block) }
            used += count
        }
        pending.removeFirst(used)
        pendingStart += Int64(used)
        if flushing, let suppressor, let last = held, suppressor.flush(into: finished) {
            held = nil
            if let buffer = block(of: finished, count: last.count, format: format) { done.append((buffer, last.start)) }
        }
        return done
    }

    /// Passes the latest block through the suppressor; returns the block before it, finished,
    /// at its own position (or the latest itself when not suppressing).
    private func suppress(start: Int64, count: Int, state: (playing: Bool, trusted: Bool),
                          format: AVAudioFormat) -> (buffer: AVAudioPCMBuffer, position: Int64)? {
        guard let suppressor else { return block(of: linear, count: count, format: format).map { ($0, start) } }
        // Past the real samples of a padded block is no audio.
        (linear + count).update(repeating: 0, count: Self.block - count)
        (echoEstimate + count).update(repeating: 0, count: Self.block - count)
        let previous = held
        held = (start, count)
        let done = suppressor.process(linear, echo: echoEstimate, learn: state.trusted, into: finished)
        if state.playing {
            report.suppressedFrom += suppressor.energy.input
            report.suppressedTo += suppressor.energy.output
        }
        guard done, let previous else { return nil }
        return block(of: finished, count: previous.count, format: format).map { ($0, previous.start) }
    }

    private func block(of samples: UnsafePointer<Float>, count: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.block)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].update(from: samples, count: count)
        return buffer
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

    /// Cancels one block, of which the first `count` samples are real audio, into `linear`, and
    /// says whether Zoom played and whether the result can teach the suppressor.
    @discardableResult
    private func cancel(_ microphone: UnsafePointer<Float>, at start: Int64, count: Int, adapt: Bool) -> (playing: Bool, trusted: Bool) {
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
        echoEstimate.update(from: echoForeground, count: Self.block)
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
            linear.update(from: microphone, count: Self.block)
            echoEstimate.update(repeating: 0, count: Self.block)
            report.broken += 1
            if !foregroundEnergy.isFinite || !backgroundEnergy.isFinite { reset() }
            return (false, false)
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
        linear.update(from: filtered ? UnsafePointer(echoForeground) : microphone, count: Self.block)
        if !filtered { report.bypassed += 1 }
        if playing {
            report.playing += 1
            report.microphone += microphoneEnergy
            report.output += filtered ? foregroundEnergy : microphoneEnergy
            report.reference += referenceEnergy
            if filtered, foregroundEnergy * 10 <= microphoneEnergy { report.cleared += 1 }
        }
        return (playing, adapt && playing && filtered)
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
