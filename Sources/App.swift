import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()
    enum Phase { case idle, preparing, recording, saving, finished }
    enum Access: String, CaseIterable { case screen, microphone, zoom }

    @Published var phase: Phase = .idle
    @Published var screenAllowed = false
    @Published var microphoneAllowed = false
    @Published var zoomAllowed = false
    @Published var microphone: ZoomMuteState = .unavailable
    @Published var elapsed = 0
    @Published var error: String?
    @Published var output: URL?
    @Published var result = ""
    private var stop: StopRequest?
    private var started: Date?
    private var timer: Timer?
    private var quitAfterSave = false

    var ready: Bool { screenAllowed && microphoneAllowed && zoomAllowed }
    var busy: Bool { phase == .preparing || phase == .recording || phase == .saving }
    var time: String {
        elapsed >= 3600
            ? String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
            : String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
    var title: String {
        switch phase {
        case .idle: return ready ? "Готов к записи" : "Настроим доступ"
        case .preparing: return "Подключаюсь к Zoom…"
        case .recording: return "Запись идёт"
        case .saving: return "Сохраняю запись…"
        case .finished: return result
        }
    }
    var micText: String {
        switch microphone {
        case .unmuted: return "Ваш микрофон записывается"
        case .muted: return "Ваш микрофон выключен в Zoom"
        case .unavailable: return "Ваш голос не записывается — проверьте окно созвона Zoom"
        }
    }
    var micColor: Color {
        switch microphone {
        case .unmuted: return .green
        case .muted: return .secondary
        case .unavailable: return .orange
        }
    }

    init() {
        refreshAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let started = self.started, self.phase == .recording { self.elapsed = Int(Date().timeIntervalSince(started)) }
                if !self.busy { self.refreshAccess() }
            }
        }
    }

    func refreshAccess() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        zoomAllowed = AXIsProcessTrusted()
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
                    refreshAccess()
                }
            } else { openSettings("Privacy_Microphone") }
        case .zoom:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            openSettings("Privacy_Accessibility")
        }
        refreshAccess()
    }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        refreshAccess()
        guard ready, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Куда сохранить созвон?"
        panel.prompt = "Начать запись"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = "Zoom \(formatter.string(from: Date())).m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        output = url
        elapsed = 0
        microphone = .unavailable
        phase = .preparing
        let request = StopRequest()
        stop = request
        Task {
            do {
                let recording = try await ZoomAudio.record(stop: request, output: url,
                    onStarted: { Task { @MainActor in
                        self.started = Date()
                        if self.phase != .saving { self.phase = .recording }
                    }},
                    onMicrophone: { value in Task { @MainActor in self.microphone = value } })
                result = recording.hasMicrophone ? "Запись сохранена" : "Сохранён звук собеседников"
                self.error = recording.warning
                phase = .finished
            } catch {
                self.error = error.localizedDescription
                phase = .idle
            }
            started = nil
            stop = nil
            if quitAfterSave { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        }
    }
    func finish() {
        guard phase == .recording || phase == .preparing else { return }
        phase = .saving
        stop?.stop()
    }
    func reveal() {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
    }
    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func quit() -> NSApplication.TerminateReply {
        guard busy else { return .terminateNow }
        quitAfterSave = true
        finish()
        return .terminateLater
    }
}

final class RecorderDelegate: NSObject, NSApplicationDelegate {
    #if !PREVIEW
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Read-only developer diagnostics run under this app's own authorization.
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--diagnose-zoom"), arguments.count > flag + 1 else { return }
        let path = arguments[flag + 1]
        Task.detached {
            let result = zoomMicrophoneDiagnostics()
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }
    #endif
    #if PREVIEW
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let model = RecorderModel.shared
            if CommandLine.arguments.contains("--recording") {
                model.screenAllowed = true; model.microphoneAllowed = true; model.zoomAllowed = true
                model.phase = .recording; model.microphone = .muted; model.elapsed = 143
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Zoom Audio Recorder" }),
                   let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: CommandLine.arguments[1]))
                }
                // Preview simulations never enter the recording shutdown path.
                model.phase = .idle
                NSApplication.shared.terminate(nil)
            }
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
                .frame(width: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            RecorderMenu(model: model)
        } label: {
            Image(systemName: model.busy ? "record.circle.fill" : "waveform")
        }
    }
}

struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.title)
        Button("Открыть рекордер") {
            openWindow(id: "recorder")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if model.busy {
            Button("Остановить и сохранить") { model.finish() }
                .disabled(model.phase == .saving)
        }
        Divider()
        Button("Выйти") { NSApplication.shared.terminate(nil) }
    }
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    @State private var showHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Zoom Audio Recorder").font(.system(size: 24, weight: .semibold))
                    Text("Созвоны команды — в одном аудиофайле")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 19))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showHelp) { HelpView().padding(22).frame(width: 360) }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(model.phase == .recording ? Color.red : Color.accentColor.opacity(0.6))
                        .frame(width: 9, height: 9)
                    Text(model.title).font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text(model.time).font(.system(size: 28, weight: .medium, design: .monospaced))
                        .monospacedDigit().foregroundStyle(model.busy ? .primary : .secondary)
                }
                if model.phase == .recording {
                    Label(model.micText, systemImage: model.microphone == .unmuted ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 12)).foregroundStyle(model.micColor)
                    if model.microphone == .unavailable {
                        Text("Войдите в созвон и покажите панель с кнопкой микрофона. Звук собеседников продолжает записываться.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.phase == .finished ? "Файл M4A готов. Его можно отправить коллегам." :
                        "Запишет звук Zoom и ваш голос, когда микрофон включён в Zoom.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if model.busy {
                        Button { model.finish() } label: {
                            Label(model.phase == .saving ? "Сохраняю…" : "Остановить и сохранить",
                                  systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }.disabled(model.phase == .saving)
                    } else {
                        Button { model.start() } label: {
                            Label("Начать запись", systemImage: "record.circle")
                                .frame(maxWidth: .infinity)
                        }.disabled(!model.ready)
                    }
                    if model.phase == .finished {
                        Button { model.reveal() } label: { Image(systemName: "folder") }
                            .help("Показать сохранённый файл")
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.ready {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Первый запуск").font(.system(size: 14, weight: .semibold))
                    Text("Разрешите доступ для Zoom Audio Recorder. В следующий раз этот шаг не понадобится.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    accessRow(.screen, "Звук Zoom", "Запись экрана и системного аудио", "speaker.wave.2")
                    accessRow(.microphone, "Ваш голос", "Доступ к микрофону", "mic")
                    accessRow(.zoom, "Состояние микрофона в Zoom", "Управление приложениями", "switch.2")
                    Text("Нет приложения в списке настроек? Нажмите «+» под списком и выберите Zoom Audio Recorder.app в папке «Программы».")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Показать приложение в Finder") { model.revealApplication() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            HStack {
                Label("Только на вашем Mac", systemImage: "lock")
                Spacer()
                Text("M4A · macOS 15+")
            }.font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }
    private func accessRow(_ access: RecorderModel.Access, _ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.allowed(access) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Разрешить") { model.request(access) }.controlSize(.small)
            }
        }
    }
}

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Как записать созвон").font(.headline)
            Text("Откройте Zoom, войдите в созвон и нажмите «Начать запись». Выберите файл. После встречи нажмите «Остановить и сохранить».")
            Text("Микрофон").font(.subheadline.bold())
            Text("Используется системный микрофон Mac. Выберите тот же микрофон в Zoom. Приложение читает кнопку mute Zoom; если кнопка недоступна, ваш микрофон заглушается. Индикатор показывает это во время записи.")
            Text("Разрешения").font(.subheadline.bold())
            Text("В настройках macOS включайте Zoom Audio Recorder. Если его нет в списке, нажмите «+» и выберите приложение в папке «Программы». Терминалу доступ не нужен. macOS 27 называет доступ к кнопке Zoom «Device Control and Data Access», ранние версии — «Accessibility».")
            Text("Все записи остаются в выбранном вами месте. Приложение ничего не отправляет в интернет.")
            Text("Перед записью предупредите участников.").foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}
