import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()
    static let defaultFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Записи Zoom", isDirectory: true)
    enum Phase { case idle, preparing, recording, saving }
    enum Access: CaseIterable { case screen, microphone, zoom }

    /// The result of the last recording; stays visible until the next one starts.
    struct Outcome: Equatable {
        enum Kind { case saved, attention, failed }
        var kind: Kind
        var title: String
        var detail: String?
        var file: URL?
        var microphone: URL? = nil
        var unreadableFolder: URL? = nil
    }

    @Published var phase: Phase = .idle
    @Published var screenAllowed = false
    @Published var microphoneAllowed = false
    @Published var zoomAllowed = false
    @Published var zoomRunning = false
    @Published var microphone: ZoomMuteState = .unavailable
    @Published var connected = true
    @Published var problem: String?
    @Published var lowDiskSpace = false
    @Published var zoomAudio = true
    @Published var elapsed = 0
    @Published var progress: Double?
    @Published var outcome: Outcome?
    @Published var recovered: [URL] = []
    @Published var unrecovered: URL?
    @Published var recovering = false
    @Published var folder: URL
    @Published var folderAvailable = true
    @Published var attention = false
    @Published var quitting = false
    /// Logout, restart or shutdown: close the tracks and leave saving to the next launch.
    private var systemQuit = false
    /// Cancel pressed while connecting: nothing is saved.
    private var cancelled = false
    private var tracksClosed = false
    private var stop: StopRequest?
    private var started: TimeInterval?
    private var timer: Timer?
    var quitConfirmed = false

    var ready: Bool { screenAllowed && microphoneAllowed && zoomAllowed }
    var busy: Bool { phase != .idle }
    var time: String { Self.clock(elapsed) }
    var micText: String {
        guard connected else { return "Переподключаюсь к Zoom…" }
        switch microphone {
        case .unmuted: return "Ваш голос записывается"
        case .muted: return "Микрофон выключен в Zoom"
        case .unavailable: return "Не вижу микрофон Zoom"
        }
    }
    var micIcon: String {
        guard connected else { return "arrow.triangle.2.circlepath" }
        switch microphone {
        case .unmuted: return "mic.fill"
        case .muted: return "mic.slash"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
    var micColor: Color {
        guard connected else { return .orange }
        switch microphone {
        case .unmuted: return .green
        case .muted: return .secondary
        case .unavailable: return .orange
        }
    }
    var lastFile: URL? { outcome?.file ?? recovered.last }
    /// A recording is kept in its working folder because it could not be saved yet.
    var unsaved: Bool {
        unrecovered != nil || (outcome?.kind == .attention && outcome?.file.map { $0.pathExtension != "m4a" } == true)
    }

    nonisolated static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "folder")
        folder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
        refresh()
        checkFolder()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes keep the clock running during alerts and a pending quit.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if let started, phase == .recording {
            elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
        }
        if !busy { refresh() }
    }

    /// Permissions and Zoom: cheap, so checked every second while idle.
    func refresh() {
        #if !PREVIEW
        screenAllowed = CGPreflightScreenCaptureAccess()
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        zoomAllowed = AXIsProcessTrusted()
        zoomRunning = ZoomAudio.runningZoom() != nil
        #endif
    }

    /// The folder and free space. These calls can block on a network share, so they
    /// run off the main thread: at launch, on activation and when the folder changes.
    func checkFolder() {
        #if !PREVIEW
        let folder = folder
        Task {
            let (available, free) = await Task.detached(priority: .utility) {
                (Self.reachable(folder), Self.freeSpace())
            }.value
            guard folder == self.folder else { return }
            folderAvailable = available
            if !busy { lowDiskSpace = free < 1_000_000_000 }
        }
        #endif
    }

    nonisolated static func freeSpace() -> Int64 {
        (try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Creates the folder and writes a test file, so a privacy prompt for a protected
    /// folder appears now, while the user is here, rather than at save time.
    nonisolated static func probe(_ folder: URL) -> Bool {
        RecordingStorage.probe(folder)
    }

    /// False for a folder on a drive that is not connected.
    nonisolated static func reachable(_ folder: URL) -> Bool {
        RecordingStorage.reachable(folder)
    }

    func allowed(_ access: Access) -> Bool {
        switch access {
        case .screen: return screenAllowed
        case .microphone: return microphoneAllowed
        case .zoom: return zoomAllowed
        }
    }

    func request(_ access: Access) {
        switch access {
        case .screen:
            if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    refresh()
                }
            } else { openSettings("Privacy_Microphone") }
        case .zoom:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openSettings("Privacy_Accessibility")
        }
        refresh()
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        refresh()
        guard ready, !busy, !recovering, zoomRunning, !quitting else { return }
        // A recording still waiting to be saved stays visible as a banner.
        if unsaved, unrecovered == nil { unrecovered = outcome?.file }
        outcome = nil
        problem = nil
        zoomAudio = true
        microphone = .unavailable
        connected = true
        progress = nil
        elapsed = 0
        attention = false
        cancelled = false
        tracksClosed = false
        systemQuit = false
        phase = .preparing
        let request = StopRequest()
        stop = request
        let destination = folder
        // The probe can hang on a dead network share; recording never waits for it.
        Task {
            let available = await Task.detached(priority: .utility) { Self.probe(destination) }.value
            if destination == folder { folderAvailable = available }
        }
        Task {
            // Keeps the Mac awake and App Nap away until the file is saved.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Запись созвона Zoom")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var session: RecordingSession?
            do {
                try await ZoomAudio.prepare()
                guard !request.isRequested else { throw CancellationError() }
                let created = try RecordingSession.create(destination: destination,
                                                          name: RecordingSession.fileName(for: Date()))
                session = created
                let summary = try await ZoomAudio.record(into: created.folder, stop: request, events: { event in
                    Task { @MainActor in
                        guard self.stop === request else { return }
                        self.handle(event)
                    }
                }, onVoice: { created.markVoice() }, onUncertainVoice: { created.markSafetyCopy() },
                   onControlSeen: { created.markControlSeen() })
                if summary.needsSafetyCopy { created.markSafetyCopy() }
                tracksClosed = true
                if cancelled { throw CancellationError() }
                guard summary.hasAudio else { throw RecorderError.noAudio }
                if systemQuit {
                    recorderLog.notice("System quit: tracks closed, saving on next launch")
                } else {
                    phase = .saving
                    let delivery = try await created.deliver(fallback: Self.defaultFolder) { value in
                        Task { @MainActor in
                            guard self.stop === request, self.phase == .saving else { return }
                            self.progress = min(1, max(self.progress ?? 0, value))
                        }
                    }
                    outcome = Self.outcome(for: delivery, summary: summary, preferred: destination)
                }
            } catch is CancellationError where cancelled || !(session?.hasAudio ?? false) {
                session?.remove()
            } catch {
                tracksClosed = true
                if let session, session.hasAudio {
                    // Captured audio stays on disk; the next launch saves it again.
                    outcome = Outcome(kind: .attention, title: "Запись не потеряна",
                                      detail: "Файл не сохранён: \(Self.sentence(error)) Можно повторить сохранение.",
                                      file: session.folder)
                } else {
                    session?.remove()
                    outcome = Outcome(kind: .failed, title: "Не удалось записать", detail: error.localizedDescription)
                }
            }
            if let outcome, outcome.kind != .saved {
                attention = true
                NSApplication.shared.requestUserAttention(.criticalRequest)
            }
            phase = .idle
            started = nil
            stop = nil
            progress = nil
            refresh()
            checkFolder()
            if quitting && (!recovering || systemQuit) { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
    }

    private static func sentence(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    private static func outcome(for delivery: RecordingSession.Delivery, summary: RecordingSummary? = nil,
                                preferred: URL) -> Outcome {
        let size = (try? FileManager.default.attributesOfItem(atPath: delivery.url.path)[.size] as? Int) ?? 0
        var details = [clock(Int(delivery.duration.rounded())) + " · "
                       + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)]
        if let summary {
            if !summary.hasZoom { details.append("Звук собеседников не получен") }
            if summary.zoomQuit { details.append("Zoom закрылся — запись остановлена") }
            if summary.interruptions > 0 { details.append("Связь с Zoom прерывалась: \(summary.interruptions)") }
            if !summary.hasVoice && delivery.microphone == nil && summary.hasZoom { details.append("Микрофон оставался выключен или не определялся") }
        }
        if delivery.microphone != nil { details.append("Кнопка mute не определялась — микрофон сохранён отдельно") }
        if delivery.incomplete { details.append("Часть записи повреждена — исходные файлы сохранены") }
        if delivery.usedFallback {
            details.insert("Папка «\(preferred.lastPathComponent)» недоступна", at: 0)
            return Outcome(kind: .attention, title: "Сохранено в «\(delivery.url.deletingLastPathComponent().lastPathComponent)»",
                           detail: details.joined(separator: "\n"), file: delivery.url,
                           microphone: delivery.microphone, unreadableFolder: delivery.unreadableFolder)
        }
        return Outcome(kind: delivery.incomplete || delivery.microphone != nil || summary?.hasZoom == false
                       || (summary?.interruptions ?? 0) > 0 ? .attention : .saved, title: "Сохранено",
                       detail: details.joined(separator: "\n"), file: delivery.url,
                       microphone: delivery.microphone, unreadableFolder: delivery.unreadableFolder)
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case .started:
            guard !cancelled else { return }
            started = ProcessInfo.processInfo.systemUptime
            if phase == .preparing { phase = .recording }
        case .connected:
            connected = true
            problem = nil
        case .reconnecting:
            if connected { NSApplication.shared.requestUserAttention(.informationalRequest) }
            connected = false
        case let .microphone(state):
            microphone = state
        case let .problem(message):
            problem = message
        case let .lowDiskSpace(low):
            lowDiskSpace = low
        case let .zoomAudio(receiving):
            zoomAudio = receiving
        }
    }

    func finish() {
        guard phase == .recording || phase == .preparing else { return }
        if let started { elapsed = Int(ProcessInfo.processInfo.systemUptime - started) }
        if phase == .preparing { cancelled = true }
        if phase == .recording { phase = .saving }
        stop?.stop()
    }

    /// Saves recordings left by a crash, a forced quit or a failed save.
    func recover() {
        guard !recovering, !busy, !quitting else { return }
        recovering = true
        Task {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Восстановление записи")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for session in RecordingSession.interrupted(fallback: Self.defaultFolder) {
                // A crash in the first second leaves nothing playable to save.
                guard session.hasAudio else {
                    session.remove()
                    continue
                }
                do {
                    let delivery = try await session.deliver(fallback: Self.defaultFolder, recovering: true)
                    recovered.append(delivery.url)
                    if outcome?.file == session.folder { outcome = nil }
                    if unrecovered == session.folder { unrecovered = nil }
                    if delivery.incomplete || delivery.microphone != nil || delivery.usedFallback {
                        if outcome == nil {
                            outcome = Self.outcome(for: delivery,
                                preferred: URL(fileURLWithPath: session.manifest.destination, isDirectory: true))
                        }
                        attention = true
                    }
                } catch RecorderError.noAudio where session.recordedBytes == 0 {
                    session.remove()
                } catch {
                    recorderLog.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
                    unrecovered = session.folder
                    attention = true
                    NSApplication.shared.requestUserAttention(.criticalRequest)
                }
            }
            recovering = false
            if quitting && !busy { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
    }

    /// The recovered files were shown; a recording still waiting to be saved stays visible.
    func dismissRecovered() {
        recovered = []
        if !unsaved { attention = false }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openFolder() {
        let folder = folder
        Task {
            let ready = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard Self.reachable(folder) else { return false }
                return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            }.value
            if ready { NSWorkspace.shared.open(folder) }
            else {
                folderAvailable = false
                let alert = NSAlert()
                alert.messageText = "Не удалось открыть папку записей"
                alert.informativeText = "\(folder.path)\n\nПодключите диск или выберите другую папку в приложении."
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Папка для записей"
        panel.prompt = "Выбрать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        folder = url
        if url == Self.defaultFolder {
            UserDefaults.standard.removeObject(forKey: "folder")
        } else {
            UserDefaults.standard.set(url.path, forKey: "folder")
        }
        checkFolder()
    }

    func quit() -> NSApplication.TerminateReply {
        // Logout, restart and shutdown never ask and never wait for an export.
        let system = Self.isSystemQuit
        switch phase {
        case .idle:
            // A recovery in progress finishes first; its folder survives a forced exit anyway.
            guard recovering, !system else { return .terminateNow }
        case .recording:
            if system {
                systemQuit = true
            } else if !quitConfirmed {
                let alert = NSAlert()
                alert.messageText = "Остановить запись и выйти?"
                alert.informativeText = "Запись будет сохранена."
                alert.addButton(withTitle: "Сохранить и выйти")
                alert.addButton(withTitle: "Продолжить запись")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
                // The recording may have ended on its own while the alert was open.
                if phase == .idle {
                    guard recovering else { return .terminateNow }
                    quitting = true
                    return .terminateLater
                }
            }
            finish()
        case .preparing:
            if system { systemQuit = true }
            finish()
        case .saving:
            if system {
                // Closed tracks are safe: an interrupted export is redone at next launch.
                if tracksClosed { return .terminateNow }
                systemQuit = true
            }
        }
        quitting = true
        return .terminateLater
    }

    private static var isSystemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}

final class RecorderDelegate: NSObject, NSApplicationDelegate {
    #if !PREVIEW
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Read-only developer diagnostics run under this app's own authorization.
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--diagnose-zoom"), arguments.count > flag + 1 else {
            RecorderModel.shared.recover()
            return
        }
        let path = arguments[flag + 1]
        let observations = arguments.contains("--observe") ? 150 : 1
        Task.detached {
            let result = await zoomMicrophoneDiagnostics(observations: observations)
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }
    #endif
    #if PREVIEW
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Renders one state to a PNG: zoom-audio <output.png> <state>.
        NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        let model = RecorderModel.shared
        let state = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "idle"
        model.screenAllowed = true
        model.microphoneAllowed = state != "permissions"
        model.zoomAllowed = state != "permissions"
        model.zoomRunning = state != "nozoom"
        let file = RecorderModel.defaultFolder.appendingPathComponent("Zoom 2026-10-05 14-30.m4a")
        switch state {
        case "recording": model.phase = .recording; model.microphone = .unmuted; model.elapsed = 754
        case "muted": model.phase = .recording; model.microphone = .muted; model.elapsed = 754
        case "unknown": model.phase = .recording; model.microphone = .unavailable; model.elapsed = 754
        case "reconnecting": model.phase = .recording; model.connected = false; model.elapsed = 754
        case "saving": model.phase = .saving; model.elapsed = 2832; model.progress = 0.62
        case "preparing": model.phase = .preparing
        case "saved":
            model.outcome = .init(kind: .saved, title: "Сохранено", detail: "47:12 · 38,2 МБ", file: file)
        case "fallback":
            model.outcome = .init(kind: .attention, title: "Сохранено в «Записи Zoom»",
                                  detail: "Папка «Meetings» недоступна\n47:12 · 38,2 МБ", file: file)
        case "kept":
            model.outcome = .init(kind: .attention, title: "Запись не потеряна",
                                  detail: "Файл не сохранён: на диске нет места. Можно повторить сохранение.",
                                  file: RecordingSession.root.appendingPathComponent("2026-10-05 14-30-00 1A2B3C4D"))
        case "failed":
            model.outcome = .init(kind: .failed, title: "Не удалось записать", detail: "Откройте Zoom и войдите в созвон")
        case "recovered": model.recovered = [file]
        case "recovering": model.recovering = true
        case "longfolder":
            model.folder = URL(fileURLWithPath: "/tmp/Очень длинное название папки с записями созвонов команды")
        case "safety":
            model.outcome = .init(kind: .attention, title: "Сохранено",
                detail: "47:12 · 38,2 МБ\nКнопка mute не определялась — микрофон сохранён отдельно",
                file: file, microphone: file.deletingLastPathComponent().appendingPathComponent("Zoom 2026-10-05 14-30 (микрофон).m4a"))
        case "unrecovered":
            model.unrecovered = RecordingSession.root.appendingPathComponent("2026-10-05 14-30-00 1A2B3C4D")
        case "damaged":
            model.outcome = .init(kind: .attention, title: "Сохранено",
                detail: "47:12 · 38,2 МБ\nЧасть записи повреждена — исходные файлы сохранены",
                file: file, unreadableFolder: RecordingSession.root.deletingLastPathComponent().appendingPathComponent("Unreadable"))
        default: break
        }
        let host = NSHostingView(rootView: RecorderView(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[1]))
            }
            // Preview simulations never enter the recording shutdown path.
            model.phase = .idle
            model.recovering = false
            NSApplication.shared.terminate(nil)
        }
    }
    #endif
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RecorderModel.shared.quit()
    }
}

@main
struct RecorderApplication: App {
    @NSApplicationDelegateAdaptor(RecorderDelegate.self) private var delegate
    @StateObject private var model = RecorderModel.shared
    var body: some Scene {
        Window("Zoom Audio Recorder", id: "recorder") {
            RecorderView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .commands { RecorderCommands(model: model) }
        Window("Справка", id: "help") {
            HelpView().padding(24).frame(width: 340)
        }
        .windowResizability(.contentSize)
        MenuBarExtra {
            RecorderMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

struct RecorderCommands: Commands {
    @ObservedObject var model: RecorderModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Запись") {
            Button("Начать запись") { model.start() }
                .keyboardShortcut("r")
                .disabled(model.busy || model.recovering || !model.ready || !model.zoomRunning || model.quitting)
            Button("Остановить запись") { model.finish() }
                .keyboardShortcut(".")
                .disabled(model.phase != .recording && model.phase != .preparing)
            Divider()
            Button("Открыть папку записей") { model.openFolder() }
            Button("Повторить сохранение") { model.recover() }
                .disabled(model.busy || model.recovering || !model.unsaved || model.quitting)
            Button("Изменить папку…") { model.chooseFolder() }
                .disabled(model.busy)
        }
        CommandGroup(replacing: .help) {
            Button("Справка Zoom Audio Recorder") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        switch model.phase {
        case .recording:
            Text("\(Image(systemName: model.micIcon)) \(model.time)").monospacedDigit()
        case .preparing:
            Image(systemName: "record.circle")
        case .saving:
            Image(systemName: "arrow.down.circle")
        case .idle:
            Image(systemName: model.attention ? "exclamationmark.triangle" : "waveform")
        }
    }
}

struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if !model.recovered.isEmpty {
            Button(model.recovered.count == 1 ? "Восстановлена запись — показать"
                   : "Восстановлено записей: \(model.recovered.count) — показать") {
                model.reveal(model.recovered)
                model.dismissRecovered()
            }
            Divider()
        }
        switch model.phase {
        case .recording:
            Text(model.connected ? "Запись · \(model.time)" : "Запись · \(model.time) · нет связи с Zoom")
            Text(model.micText)
        case .preparing: Text("Подключаюсь к Zoom…")
        case .saving: Text("Сохраняю…")
        case .idle: if let outcome = model.outcome { Text(outcome.title) }
        }
        Divider()
        if model.phase == .recording || model.phase == .preparing {
            Button("Остановить запись") { model.finish() }
        } else {
            Button("Начать запись") { model.start() }
                .disabled(model.busy || model.recovering || !model.ready || !model.zoomRunning || model.quitting)
        }
        if let file = model.lastFile, !model.busy {
            Button("Показать последнюю запись") { model.reveal([file]) }
        }
        if model.unsaved {
            Button(model.recovering ? "Сохраняю…" : "Повторить сохранение") { model.recover() }
                .disabled(model.busy || model.recovering || model.quitting)
        }
        if let microphone = model.outcome?.microphone {
            Button("Показать запись микрофона") { model.reveal([microphone]) }
        }
        Button("Открыть папку записей") { model.openFolder() }
        Divider()
        Button("Показать окно") {
            openWindow(id: "recorder")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Справка") {
            openWindow(id: "help")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        // A second terminate while one is pending would skip saving.
        Button(model.phase == .recording ? "Остановить и выйти" : "Выйти") {
            guard !model.quitting else { return }
            model.quitConfirmed = true
            NSApplication.shared.terminate(nil)
        }
        .disabled(model.quitting)
    }
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(spacing: 16) {
            if !model.recovered.isEmpty || model.unrecovered != nil {
                RecoveryBanner(model: model)
            }
            if !model.ready && !model.busy {
                if let outcome = model.outcome { OutcomeView(model: model, outcome: outcome) }
                PermissionsView(model: model)
            } else {
                switch model.phase {
                case .idle: IdleView(model: model)
                case .preparing: PreparingView(model: model)
                case .recording: RecordingView(model: model)
                case .saving: SavingView(model: model)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy, value: model.phase)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.busy {
                model.refresh()
                model.checkFolder()
            }
            // Seen now; only a recording still waiting to be saved keeps the warning.
            if !model.unsaved { model.attention = false }
        }
    }
}

private let wideButton: CGFloat = 200

struct IdleView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(spacing: 14) {
            if let outcome = model.outcome {
                OutcomeView(model: model, outcome: outcome)
            } else {
                Text(model.zoomRunning ? "Готов к записи" : "Откройте Zoom и войдите в созвон")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(model.zoomRunning ? .primary : .secondary)
                    .multilineTextAlignment(.center)
            }
            Button { model.start() } label: {
                Label("Начать запись", systemImage: "record.circle").frame(width: wideButton)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.zoomRunning || model.recovering || model.quitting)
            VStack(spacing: 4) {
                FolderMenu(model: model)
                if !model.folderAvailable {
                    Caption("Папка недоступна — сохраню в «\(RecorderModel.defaultFolder.lastPathComponent)»", color: .orange)
                }
                if model.lowDiskSpace { Caption("Мало места на диске", color: .orange) }
                if model.recovering { Caption("Восстанавливаю прерванную запись…") }
            }
        }
    }
}

struct OutcomeView: View {
    @ObservedObject var model: RecorderModel
    let outcome: RecorderModel.Outcome
    var body: some View {
        VStack(spacing: 8) {
            Label {
                Text(outcome.title)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .font(.title3.weight(.medium))
            .multilineTextAlignment(.center)
            if let file = outcome.file {
                Button { model.reveal([file]) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: file.pathExtension == "m4a" ? "waveform" : "folder")
                        Text(file.pathExtension == "m4a" ? file.lastPathComponent : "Показать исходную запись")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Показать в Finder")
                .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
            }
            if let detail = outcome.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let microphone = outcome.microphone {
                Button("Показать запись микрофона") { model.reveal([microphone]) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if let folder = outcome.unreadableFolder {
                Button("Показать исходные файлы") { model.reveal([folder]) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if outcome.file?.pathExtension != "m4a", outcome.kind == .attention {
                Button(model.recovering ? "Сохраняю…" : "Повторить сохранение") { model.recover() }
                    .disabled(model.busy || model.recovering || model.quitting)
            }
        }
    }
    private var color: Color {
        switch outcome.kind {
        case .saved: return .green
        case .attention: return .orange
        case .failed: return .red
        }
    }
    private var icon: String {
        switch outcome.kind {
        case .saved: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

struct PreparingView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Подключаюсь к Zoom…").font(.title3.weight(.medium))
            }
            Button("Отменить") { model.finish() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }
}

struct RecordingView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.time)
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Идёт запись, \(model.time)")
            Label(model.micText, systemImage: model.micIcon)
                .font(.callout)
                .foregroundStyle(model.micColor)
            if model.connected && model.microphone == .unavailable {
                Caption("Покажите панель управления встречей в Zoom")
            }
            if model.connected && !model.zoomAudio { Caption("Звук Zoom не поступает", color: .orange) }
            if let problem = model.problem { Caption(problem, color: .orange) }
            if model.lowDiskSpace { Caption("Мало места на диске", color: .orange) }
            Button { model.finish() } label: {
                Label("Остановить", systemImage: "stop.fill").frame(width: wideButton)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.top, 6)
        }
    }
}

struct SavingView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(spacing: 12) {
            Text(model.time)
                .font(.system(size: 40, weight: .light))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(model.quitting ? "Сохраняю перед выходом…" : "Сохраняю…").font(.callout)
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: wideButton)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Нужен доступ").font(.title3.weight(.medium))
            row(.screen, "Звук Zoom", "speaker.wave.2", "«Запись экрана и системного звука»")
            row(.microphone, "Микрофон", "mic", "«Микрофон»")
            row(.zoom, "Кнопка mute в Zoom", "hand.tap",
                "«Универсальный доступ» (в macOS 27 — «Управление устройством и доступ к данным»)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Нет в списке? Нажмите «+» и выберите приложение.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Показать приложение в Finder") { model.revealApplication() }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ access: RecorderModel.Access, _ title: String, _ icon: String, _ pane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            if model.allowed(access) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Разрешить") { model.request(access) }.controlSize(.small)
            }
        }
        .help("Конфиденциальность и безопасность → \(pane)")
    }
}

struct RecoveryBanner: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.unrecovered == nil ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.unrecovered == nil ? Color.accentColor : .orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                if model.unrecovered != nil {
                    Button(model.recovering ? "Сохраняю…" : "Повторить") { model.recover() }
                        .disabled(model.busy || model.recovering || model.quitting)
                }
                Button("Показать") {
                    model.reveal(model.unrecovered.map { [$0] } ?? model.recovered)
                }
            }
            .controlSize(.small)
            if model.unrecovered == nil {
                Button { model.dismissRecovered() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Скрыть")
                    .accessibilityLabel("Скрыть сообщение о восстановлении")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private var text: String {
        if model.unrecovered != nil { return "Запись ещё не сохранена. Можно повторить." }
        return model.recovered.count == 1 ? "Восстановлена прерванная запись"
            : "Восстановлено записей: \(model.recovered.count)"
    }
}

struct FolderMenu: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        Menu {
            Button("Открыть в Finder") { model.openFolder() }
            Button("Изменить папку…") { model.chooseFolder() }
            if model.folder != RecorderModel.defaultFolder {
                Button("По умолчанию: «\(RecorderModel.defaultFolder.lastPathComponent)»") {
                    model.setFolder(RecorderModel.defaultFolder)
                }
            }
        } label: {
            Label {
                Text(folderName)
            } icon: { Image(systemName: "folder") }
        } primaryAction: {
            model.openFolder()
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: wideButton)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(model.folder.path)
        .accessibilityLabel("Папка записей: \(model.folder.lastPathComponent)")
    }

    /// Native macOS menus ignore Text's lineLimit, so fit the title before handing it over.
    private var folderName: String {
        let name = model.folder.lastPathComponent
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let available = wideButton - 48
        guard (name as NSString).size(withAttributes: attributes).width > available else { return name }
        var kept = name.count - 1
        while kept > 0 {
            let text = String(name.prefix((kept + 1) / 2)) + "…" + String(name.suffix(kept / 2))
            if (text as NSString).size(withAttributes: attributes).width <= available { return text }
            kept -= 1
        }
        return "…"
    }
}

struct Caption: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Войдите в созвон Zoom → «Начать запись» → «Остановить». Файл появится в папке записей.")
            Text("Ваш голос записывается, только когда микрофон включён в Zoom. В Zoom и macOS должен быть выбран один микрофон.")
            Text("Прерванная запись восстанавливается при следующем запуске.")
            Text("Если сохранение не удалось, нажмите «Повторить сохранение». Если кнопка mute не определялась, проверьте отдельную запись микрофона рядом с основным файлом.")
            Text("Предупредите участников о записи.").foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
