import Foundation

enum SetupStep: Int, CaseIterable { case choose, volume, attention, complete }
enum StartupState: Equatable { case off, on, needsApproval, unavailable }
enum SetupAction {
    case choose(String, Bool), useAnotherApp, tryAgain, addApp, cancelAnotherApp
    case soundSettings, login(Bool), openLoginItems
}

struct DictationApp: Equatable {
    let id: String, name: String
    var note: String?       // what to switch off in that app, in its own words
    var tile = false        // offered on the choose screen when installed; needs a complete real-app record
    var path: String?
    var chosen = false
}
// Any app can be added with Use another app…; a row here only adds a tile or the exact setting names.
let knownApps = [
    DictationApp(id: "com.seewillow.WillowMac", name: "Willow",
                 note: "In Willow, turn off Mute Audio While Dictating. Sigá also lowers the volume during Willow Scribe.", tile: true),
    DictationApp(id: "com.superduper.superwhisper", name: "superwhisper",
                 note: "In superwhisper, set Playback when recording to Keep Playing. Sigá also lowers the volume during superwhisper meetings.", tile: true),
    DictationApp(id: "com.electron.wispr-flow", name: "Wispr Flow",
                 note: "In Wispr Flow, keep Mute music while dictating turned off. Sigá also lowers the volume during Flow Notetaker."),
    DictationApp(id: "com.prakashjoshipax.VoiceInk", name: "VoiceInk",
                 note: "In VoiceInk, turn off Mute Audio While Recording and Pause Media While Recording."),
    DictationApp(id: "now.typeless.desktop", name: "Typeless", note: "In Typeless, turn off Mute when dictating."),
]
let anyAppNote = "Turn off your dictation app’s automatic muting, pausing, and volume lowering."
let sigaHandlesIt = " Sigá handles the volume."

func dictationApp(id: String, path: String) -> DictationApp {
    var app = knownApps.first { $0.id == id }
        ?? DictationApp(id: id, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    app.path = path
    return app
}
// The one source of rows for the choose screen and the Dictation apps menu: installed tiles, then
// whatever else the person has added.
func dictationRows(chosen: [String], installedAt: (String) -> URL?) -> [DictationApp] {
    let tiles = knownApps.filter(\.tile).map(\.id)
    return (tiles + chosen.filter { !tiles.contains($0) }).compactMap { id in
        guard let url = installedAt(id) else { return nil }
        var app = dictationApp(id: id, path: url.path)
        app.chosen = chosen.contains(id)
        return app
    }
}
func chosenNotes(_ apps: [DictationApp]) -> String {
    let notes = apps.filter(\.chosen).compactMap(\.note)
    return notes.isEmpty ? "" : notes.joined(separator: " ") + sigaHandlesIt
}

// What the done page has seen since setup finished. A real lowering is never replaced.
enum Session: Equatable {
    case none, lowered, skipped
    mutating func observe(lowered: Bool, skipped: Bool) {
        if lowered { self = .lowered } else if skipped && self == .none { self = .skipped }
    }
    func line(_ apps: [DictationApp]) -> String {
        switch self {
        case .none: return "Try it now. Play something, then dictate."
        case .lowered: return "That’s it. Sigá lowered the volume."
        case .skipped:
            let notes = chosenNotes(apps)
            return "Your volume was already off, so Sigá left it alone. " + (notes.isEmpty ? anyAppNote + sigaHandlesIt : notes)
        }
    }
}

// The outermost .app folder that holds an executable, with a trailing slash; nil for a bare tool.
func owningApp(ofExecutable path: String) -> String? {
    path.range(of: ".app/").map { String(path[..<$0.upperBound]) }
}
// Use another app…: the person dictates once and Sigá offers the app whose microphone went on, then off.
struct Discovery {
    enum Phase: Equatable { case waiting, hearing(String), heard(String) }
    var phase = Phase.waiting
    var wasActive: [String]?           // nil until the first tick

    // `active` holds the owning apps with a client on the microphone this tick, so one helper
    // stopping while another continues is not a stop.
    mutating func tick(active: [String]) {
        defer { wasActive = active }
        guard let wasActive else { return }             // the first tick only records who is already on
        switch phase {
        case .waiting:
            // Off to on. An app already on when watching began never makes this transition until
            // it has stopped and started again, so a call in progress is never offered.
            if let started = active.first(where: { !wasActive.contains($0) }) { phase = .hearing(started) }
        case .hearing(let root):
            if !active.contains(root) { phase = .heard(root) }
        case .heard: break
        }
    }
    // Forgets who was on the microphone too, so activity already running does not count.
    mutating func tryAgain() { self = Discovery() }
}
struct AnotherAppSheet: Equatable {
    let headline: String, note: String, warning: String?, canAdd: Bool
    static let footnote = "Nothing showing up? Some apps keep the microphone on all the time. Sigá can’t follow those."
    // `app` is the candidate once there is one. The note is on screen before Add can be pressed.
    init(_ phase: Discovery.Phase, app: DictationApp?) {
        switch phase {
        case .waiting: headline = "Start dictating in your app."
        case .hearing: headline = "Hearing \(app?.name ?? "your app"). Stop dictating to finish."
        case .heard: headline = "Found \(app?.name ?? "your app")."
        }
        note = (app?.note ?? anyAppNote) + sigaHandlesIt
        warning = app.map { "Sigá lowers everything your Mac plays whenever \($0.name) uses the microphone, including calls." }
        if case .heard = phase, app != nil { canAdd = true } else { canAdd = false }
    }
}

// Values describe observed state. They never stand in for a permission grant.
struct SetupSnapshot {
    var apps: [DictationApp] = []
    var startup: StartupState = .off
    var startupError: String?
    var session = Session.none
    var anotherApp: AnotherAppSheet?
    var canContinue: Bool { apps.contains(where: \.chosen) }    // nothing is ever chosen for the person
}
