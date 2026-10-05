import Foundation

func checkMuteDetection() throws {
    var matcher = ZoomMuteLabels()
    matcher.mute.append("выключить мой звук")
    matcher.unmute.append("включить мой звук")
    try check(matcher.state(labels: ["Mute my audio (⇧⌘A)"], role: "AXMenuItem", enabled: true) == .unmuted, "own menu action not recognized")
    try check(matcher.state(labels: ["Unmute my audio"], role: "AXMenuItem", enabled: true) == .muted, "unmute confused with mute")
    try check(matcher.state(labels: ["Mute my audio"], role: "AXMenuItem", enabled: false) == nil, "disabled menu implies a meeting")
    try check(matcher.state(labels: ["Включить мой звук"], role: "AXCheckBox", enabled: true) == .muted, "localized checkbox not recognized")
    try check(matcher.state(labels: ["Mute (⇧⌘A)"], role: "AXButton", enabled: true, inToolbar: true) == .unmuted, "toolbar mute not recognized")
    try check(matcher.state(labels: ["Unmute"], role: "AXButton", enabled: true, inToolbar: true) == .muted, "toolbar unmute not recognized")
    try check(matcher.state(labels: ["Mute"], role: "AXButton", enabled: true) == nil, "participant mute enabled own microphone")
    try check(matcher.state(labels: ["Mute all"], role: "AXButton", enabled: true, inToolbar: true) == nil, "mute all enabled own microphone")
    try check(matcher.state(labels: ["Audio"], role: "AXButton", enabled: true, inToolbar: true) == nil, "unknown audio state guessed")
    try check(matcher.state(labels: ["Mute my audio", "Mute/unmute my audio"], role: "AXMenuItem", enabled: true) == .unmuted, "generic help overrode current menu action")
    try check(matcher.state(labels: ["Mute/unmute my audio"], role: "AXMenuItem", enabled: true) == nil, "toggle description guessed a state")
    try check(matcher.state(labels: ["Unmute audio"], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .muted, "actual Zoom 7 command not recognized")
    try check(matcher.state(labels: ["Mute audio"], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .unmuted, "actual Zoom 7 unmuted command not recognized")
    try check(matcher.state(labels: ["Mute audio"], role: "AXMenuItem", enabled: true, identifier: "onMuteAll:") == nil, "another command enabled own audio")
    try check(matcher.state(labels: ["Mute my audio.txt"], role: "AXMenuItem", enabled: true, identifier: "_recentItemRequested:") == nil, "recent file interpreted as a microphone command")
    matcher.ownActionUnmute.append("включить звук")
    try check(matcher.state(labels: ["Включить звук"], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .muted, "localized own audio action not recognized")
    // In Italian, Portuguese and Swedish the Mute title contains the Unmute title.
    for (mute, unmute) in [("Disattiva audio", "Attiva audio"), ("Desativar áudio", "Ativar áudio"), ("Inaktivera ljud", "Aktivera ljud")] {
        var labels = ZoomMuteLabels()
        labels.add(localization: ["Mute Audio": mute, "Unmute Audio": unmute])
        try check(labels.state(labels: [mute], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .unmuted, "\(mute) read as muted")
        try check(labels.state(labels: [unmute], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .muted, "\(unmute) read as unmuted")
    }
    // In Chinese the long label equals the short word, so participant and settings controls must not match.
    var chinese = ZoomMuteLabels()
    chinese.add(localization: ["Mute": "静音", "Unmute": "解除静音", "Mute My Audio": "静音", "Unmute My Audio": "解除静音",
                               "Mute Audio": "静音", "Unmute Audio": "解除静音"])
    for label in ["静音", "全体静音", "解除全体静音", "加入会议时将麦克风静音", "保持静音"] {
        try check(chinese.state(labels: [label], role: "AXButton", enabled: true) == nil, "\(label) outside the toolbar enabled the microphone")
        try check(chinese.state(labels: [label], role: "AXCheckBox", enabled: true) == nil, "\(label) checkbox enabled the microphone")
    }
    try check(chinese.state(labels: ["静音"], role: "AXButton", enabled: true, inToolbar: true) == .unmuted, "Chinese toolbar mute not recognized")
    try check(chinese.state(labels: ["解除静音"], role: "AXMenuItem", enabled: true, identifier: "onMuteAudio:") == .muted, "Chinese menu unmute not recognized")
    print("PASS: own menu, disabled menu, localized checkbox, toolbar, participant isolation, unknown state, whole-label matching (it, pt, sv, zh)")
}

func checkMuteTips() throws {
    var labels = ZoomMuteLabels()
    try check(labels.tipState("Noise removal is on. Mute my audio (⇧⌘A)") == .unmuted, "unmuted tooltip not recognized")
    try check(labels.tipState("Mute my audio") == .unmuted, "bare tooltip not recognized")
    try check(labels.tipState("Press (⇧⌘A) to unmute or hold (Space) to temporarily unmute.") == .muted, "muted tooltip not recognized")
    try check(labels.tipState("Noise removal is on. Unmute my audio (⇧⌘A)") == .muted, "unmute action read as mute")
    try check(labels.tipState("Mute/unmute my audio (⇧⌘A)") == nil, "toggle description guessed a state")
    try check(labels.tipState("Audio options") == nil, "unrelated tooltip guessed a state")
    labels.add(localization: ["Mute My Audio": "Выключить мой звук", "Unmute My Audio": "Включить мой звук",
        "LN_Unmute_Audio_Tip_803981": "Нажмите (%1$@), чтобы включить звук, или нажмите и удерживайте (%2$@), чтобы временно включить звук."])
    try check(labels.tipState("Нажмите (⇧⌘A), чтобы включить звук, или нажмите и удерживайте (Пробел), чтобы временно включить звук.") == .muted,
              "localized muted tooltip not recognized")
    try check(labels.tipState("Удаление шума: включено. Выключить мой звук (⇧⌘A)") == .unmuted, "localized unmuted tooltip not recognized")
    // In Italian the Mute title ends with the Unmute title.
    var italian = ZoomMuteLabels()
    italian.add(localization: ["Mute My Audio": "Disattiva il mio audio", "Unmute My Audio": "Attiva il mio audio"])
    try check(italian.tipState("Rimozione del rumore: attiva. Disattiva il mio audio (⇧⌘A)") == .unmuted, "Italian mute read as unmute")
    try check(italian.tipState("Attiva il mio audio (⇧⌘A)") == .muted, "Italian unmute not recognized")
    print("PASS: mute button tooltips (en, ru, it), toggle descriptions ignored")
}

/// The readings Zoom gave in a real meeting: the tooltip changes 0.1 s after a click, the
/// menu command up to a second later, the label about a second later.
func checkMuteIndicators() throws {
    var indicators = MuteIndicators()
    var time = 0.0
    func read(_ tip: ZoomMuteState?, _ menu: ZoomMuteState?, _ label: ZoomMuteState?) -> ZoomMuteState {
        time += 0.02
        let shown: [MuteIndicators.Kind: ZoomMuteState?] = [.tip: tip, .menu: menu, .label: label]
        return indicators.update(shown.compactMapValues { $0 }, at: time)
    }
    // A stale tooltip at the start is outvoted.
    try check(read(.unmuted, .muted, .muted) == .muted, "a stale tooltip decided the first reading")
    try check(read(.unmuted, .muted, .muted) == .muted, "a stale tooltip took over")
    // A click: the tooltip changes first.
    try check(read(.muted, .muted, .muted) == .muted, "unchanged state")
    try check(read(.unmuted, .muted, .muted) == .unmuted, "the tooltip's change was ignored")
    try check(read(.unmuted, .unmuted, .muted) == .unmuted, "the menu catching up changed the state")
    try check(read(.unmuted, .unmuted, .unmuted) == .unmuted, "the label catching up changed the state")
    // The hotkey: the menu changes at once, the tooltip stays stale.
    try check(read(.unmuted, .muted, .unmuted) == .muted, "the menu's change was ignored")
    try check(read(.unmuted, .muted, .muted) == .muted, "the stale tooltip came back")
    // The button disappears right after a click, before the menu caught up.
    try check(read(.unmuted, .muted, .muted) == .muted, "unchanged state")
    try check(read(.muted, .muted, .muted) == .muted, "unchanged state")
    _ = read(.unmuted, .muted, .muted)
    try check(read(nil, .muted, nil) == .unmuted, "a stale menu undid a click")
    try check(read(nil, .unmuted, nil) == .unmuted, "the menu catching up changed the state")
    // The button comes back showing a change made while it was hidden.
    try check(read(nil, nil, nil) == .unavailable, "no indicator must mean unavailable")
    try check(read(.unmuted, nil, .unmuted) == .unmuted, "controls that came back were ignored")
    try check(read(.unmuted, .muted, .unmuted) == .unmuted, "a menu that appeared overrode the button")
    // Every indicator disagreeing for longer than any of them stays stale wins.
    var since = time
    while time - since < MuteIndicators.staleness - 0.1 {
        try check(read(nil, .muted, nil) == .unmuted, "a lagging menu took over too early")
    }
    since = time
    while time - since < 0.2 { _ = read(nil, .muted, nil) }
    try check(read(nil, .muted, nil) == .muted, "a lasting disagreement was never resolved")
    print("PASS: the newest indicator change wins; stale indicators are outvoted")
}
