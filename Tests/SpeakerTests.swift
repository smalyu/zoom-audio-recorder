import AVFoundation
import Foundation

func checkSpeakerTiles() throws {
    let gallery = { (names: [String]) in names.map { ZoomTile(name: $0, area: 368 * 207) } }
    let reading = { (now: [String], before: [String]?) in ZoomTiles.reading(of: gallery(now), after: before.map(gallery)) }
    try check(reading(["Анна", "Борис"], nil) == .speaker("Борис"), "first look: the video drawn last is the speaker")
    try check(reading(["Анна", "Вера", "Борис"], ["Анна", "Борис", "Вера"]) == .speaker("Борис"), "a video moved to the end is the speaker")
    try check(reading(["Анна", "Борис", "Вера"], ["Анна", "Борис", "Вера"]) == .unchanged, "the same order changed the speaker")
    try check(reading(["Анна", "Борис", "Вера"], ["Анна", "Борис"]) == .unchanged, "someone joining became the speaker")
    try check(reading(["Вера", "Анна", "Борис"], ["Анна", "Борис", "Вера"]) == .unchanged, "a rearranged gallery named a speaker")
    try check(ZoomTiles.reading(of: [ZoomTile(name: "Анна", area: 668 * 376), ZoomTile(name: "Я", area: 160 * 90)],
                                after: gallery(["Я", "Анна"])) == .speaker("Анна"), "speaker view: the large video is the speaker")
    try check(reading([], ["Анна"]) == .noOne, "no videos, no speaker")
    try check(ZoomTiles.name(in: "Анна Петрова, Computer audio muted, Video off", labels: ["Анна Петрова"]) == "Анна Петрова",
              "name before the audio state not found")
    try check(ZoomTiles.name(in: "Smith, John, Computer audio unmuted, Video on", labels: ["More", "Smith, John", "Smith"]) == "Smith, John",
              "a name with a comma was cut")
    try check(ZoomTiles.name(in: "iPhone (Анна), Computer audio muted", labels: ["Ask to unmute"]) == nil, "an unrelated label taken as the name")
    print("PASS: speaker from a video moved to the end or the large one, not from rearrangements; names from video labels")
}

/// The speaker Zoom showed before the first audio lands at the start; the user's voice
/// counts only while Zoom is quiet, never when the speakers reach the microphone.
func checkSpeakerTimeline(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let capture = Capture(directory: folder, realtime: false)
    var clock = 0.0
    capture.now = { CMTime(seconds: 1000 + clock, preferredTimescale: 48_000) }
    var polls = MutePolls { _ in true }
    capture.muteTimeline = { _ in polls.timeline }
    capture.noteSpeaker("Анна", at: 999)
    for index in 0..<60 {
        let start = Int64(48_000_000 + index * 4800)
        clock = Double(index + 1) * 0.1
        polls.advance(to: clock)
        if index == 25 { capture.noteSpeaker("Борис Петров", at: 1002.5) }
        // The user speaks at 1-2 s; Zoom plays a participant at 3-4 s, which the microphone also hears.
        let remote = (30..<40).contains(index)
        capture.receive(try sample(frequency: remote ? 440 : 0, start: start, channels: 2, float: true, interleaved: false), of: .audio)
        capture.receive(try sample(frequency: (10..<20).contains(index) || remote ? 880 : 0, start: start), of: .microphone)
    }
    polls.advance(to: clock + 0.6)
    capture.releaseVoice(flushing: true)
    capture.finishVoiceSpans()
    await capture.zoom.finish()
    await capture.mic.finish()
    await capture.raw.finish()
    let text = try SpeakerLog.timeline(in: folder) ?? { throw TestError.failed("no timeline") }()
    let timeline = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: [[Any]]]
    let speakers = timeline["speakers"]!.map { "\($0[0]) \($0[1])" }
    try check(speakers == ["0 Анна", "2.5 Борис Петров"], "speakers: \(speakers)")
    let me = timeline["me"]! as! [[Double]]
    try check(me.count == 1 && abs(me[0][0] - 1.0) <= 0.15 && abs(me[0][1] - 2.0) <= 0.15, "own voice: \(me)")
    // A line cut short by a crash is skipped.
    let handle = try FileHandle(forWritingTo: capture.speakers.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("[\"zoom\", 5.1, \"Ве".utf8))
    try handle.close()
    try check(SpeakerLog.timeline(in: folder) == text, "a cut line changed the timeline")
    try check(SpeakerLog.timeline(in: folder.appendingPathComponent("missing")) == nil, "a timeline without a log")
    // The timeline travels inside the saved file; a recording without one has no description.
    let description = { (url: URL) async throws -> String? in
        let items = try await AVURLAsset(url: url).load(.metadata)
        return try await AVMetadataItem.metadataItems(from: items, withKey: "desc", keySpace: .iTunes).first?.load(.stringValue)
    }
    let root = folder.appendingPathComponent("sessions")
    let destination = folder.appendingPathComponent("meetings")
    // Zoom alone is copied by the export preset; Zoom with the user's voice goes through the mix encoder.
    for withVoice in [false, true] {
        let described = try await makeSession(root: root, destination: destination, name: "Described.m4a")
        try FileManager.default.copyItem(at: capture.speakers.url, to: SpeakerLog(directory: described.folder).url)
        if withVoice {
            for part in AudioTrack.parts(named: "mic", in: folder) {
                try FileManager.default.copyItem(at: part.url, to: described.folder.appendingPathComponent(part.url.lastPathComponent))
            }
            described.markVoice()
        }
        let saved = try await described.deliver(fallback: destination).url
        try check(try await description(saved) == text, "saved file lost the timeline (voice: \(withVoice))")
    }
    let plain = try await makeSession(root: root, destination: destination, name: "Plain.m4a")
    try check(try await description(try await plain.deliver(fallback: destination).url) == nil, "a description without a timeline")
    print("PASS: speaker timeline on the recording's clock, own voice only while Zoom is quiet, saved in the file")
}

/// A tone of `amplitude` in the recorder's mono format, for `VoiceSpans`.
func level(_ amplitude: Float, frames: Int = 4800) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                                           interleaved: true)!, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames { buffer.floatChannelData![0][frame] = amplitude * Float(sin(Double(frame) * 0.3)) }
    return buffer
}

/// A participant heard by the microphone a little later, or delivered late by Zoom, is not the user.
func checkVoiceSpans() throws {
    let slot = Int(VoiceSpans.slot)
    // A participant at 1-2 s reaches the microphone 0.3 s later; the user speaks at 3-4 s.
    var echo = VoiceSpans()
    var spans: [Range<Double>] = []
    for index in 0..<60 {
        echo.addZoom(level((10..<20).contains(index) ? 0.2 : 0), at: Int64(index * slot))
        let mic: Float = (13..<23).contains(index) ? 0.1 : (30..<40).contains(index) ? 0.2 : 0
        spans += echo.addMicrophone(level(mic), at: Int64(index * slot))
    }
    spans += echo.finish()
    try check(spans.count == 1 && abs(spans[0].lowerBound - 3) < 0.05 && abs(spans[0].upperBound - 4) < 0.05,
              "an echo of a participant counted as the user: \(spans)")
    // Zoom's audio for 1-2 s arrives two seconds late: the microphone waits for it.
    var late = VoiceSpans()
    spans = []
    for index in 0..<60 {
        if !(10..<40).contains(index) { late.addZoom(level(0), at: Int64(index * slot)) }
        if index == 40 {
            for back in 10..<40 { late.addZoom(level((10..<20).contains(back) ? 0.2 : 0), at: Int64(back * slot)) }
        }
        spans += late.addMicrophone(level((10..<20).contains(index) ? 0.05 : 0), at: Int64(index * slot))
    }
    spans += late.finish()
    try check(spans.isEmpty, "a participant delivered late counted as the user: \(spans)")
    print("PASS: own voice ignores echoes and waits for late Zoom audio")
}

/// Lines appended out of order are sorted; a speaker gone at the end stays gone.
func checkSpeakerLog(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = SpeakerLog(directory: folder)
    log.speaker("Анна", at: 1)
    log.speaker(nil, at: 100)
    log.speaker("Анна", at: 99.9)
    log.speaker(nil, at: 120)
    let text = SpeakerLog.timeline(in: folder) ?? ""
    try check(text == #"{"me":[],"speakers":[[1,"Анна"],[100,null]]}"#, "timeline: \(text)")
    print("PASS: speaker log sorted by time, keeps the window gone until the end")
}
