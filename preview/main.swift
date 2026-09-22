import AppKit

// Deliberately imports neither CoreAudio nor ServiceManagement.
// No production App/Ducking source or UserDefaults are linked into this target.
final class Preview: NSObject, NSApplicationDelegate {
    var window: Welcome?
    var value = SetupSnapshot(apps: Preview.records(2))
    var volumeAvailable = true
    var discovery: Discovery?, search = 0
    // Supplied records. Nothing here looks at the apps on this Mac; system apps lend their icons.
    static let found = DictationApp(id: "com.electron.wispr-flow", name: "Wispr Flow",
        note: knownApps.first { $0.id == "com.electron.wispr-flow" }?.note, path: "/System/Applications/Podcasts.app")
    static func records(_ count: Int, longName: Bool = false) -> [DictationApp] {
        let icons = ["Music", "Podcasts", "Notes", "Mail", "Maps", "Books", "Weather", "Clock", "Stocks", "Freeform", "Home", "News"]
        var apps = knownApps.filter(\.tile)
        apps += (apps.count..<max(apps.count, count)).map { DictationApp(id: "preview.app\($0)", name: "Dictation app \($0 + 1)") }
        if longName { apps[1] = DictationApp(id: "preview.long", name: "An Unusually Long Dictation App Name Pro", note: "In An Unusually Long Dictation App Name Pro, turn off Lower system audio during recording and Pause playback.") }
        return apps.prefix(count).enumerated().map { index, app in
            var app = app; app.path = "/System/Applications/\(icons[index % icons.count]).app"; return app
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let root = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let actions = NSMenu(); root.submenu = actions; menu.addItem(root)
        for (index, title) in ["Two apps", "No apps", "Volume unavailable", "Login approval needed", "Login request failed", "Login unavailable", "Settings", "One app", "Twelve apps", "Long name", "Dictation lowered the volume", "Volume was already off"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(scenario(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; actions.addItem(item)
        }
        actions.addItem(.separator())
        let restart = NSMenuItem(title: "Restart onboarding", action: #selector(restart), keyEquivalent: "r"); restart.target = self; actions.addItem(restart)
        let quit = NSMenuItem(title: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); actions.addItem(quit)
        let file = NSMenu(title: "File"); let fileItem = NSMenuItem(); fileItem.submenu = file; menu.addItem(fileItem)
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        show()
    }
    func make(step: SetupStep? = nil, firstRun: Bool = true) -> Welcome {
        weak var made: Welcome?
        let result = Welcome(percent: 30, firstRun: firstRun, initialStep: step,
            onRefresh: { [weak self] in guard let self else { return }; self.window?.update(self.value) },
            onAction: { [weak self] action in self?.perform(action) }, onVolume: { _ in },
            onFinish: { [weak self] _ in self?.finish() }, onClose: { [weak self] in
                // Closing cancels the simulated check, like the app: the controller is released.
                DispatchQueue.main.async { if let self, self.window === made { self.window = nil } }
            })
        made = result
        // The window looks exactly like the app's; the application menu says Sigá Preview.
        result.window?.title = "Sigá Preview — Simulated"
        result.update(value)
        return result
    }
    func show(firstRun: Bool = true) { window = make(firstRun: firstRun); window?.present() }
    func finish() {
        guard let window else { return }
        // Simulate the brief readiness check that Start performs. Closing cancels it, like the app.
        window.setFinishing(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak window] in
            guard let self, let window, self.window === window, window.window?.isVisible == true else { return }
            window.setFinishing(false)
            guard self.volumeAvailable else { window.showAttention(); return }
            window.showComplete()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show() }
        return true
    }
    func perform(_ action: SetupAction) {
        switch action {
        case .choose(let id, let on):
            if let index = value.apps.firstIndex(where: { $0.id == id }) { value.apps[index].chosen = on }
        case .useAnotherApp, .tryAgain:
            // The real Discovery, fed a scripted start and stop one second apart.
            discovery = Discovery(); hear([]); search += 1
            for (delay, active) in [(1.0, [Preview.found.path!]), (2.0, [])] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, search] in
                    if self?.search == search { self?.hear(active) }
                }
            }
        case .addApp:
            if !value.apps.contains(where: { $0.id == Preview.found.id }) { var app = Preview.found; app.chosen = true; value.apps.append(app) }
            discovery = nil; value.anotherApp = nil
        case .cancelAnotherApp: discovery = nil; value.anotherApp = nil
        case .soundSettings: volumeAvailable = true
        case .openLoginItems: value.startup = .on
        case .login(let enabled):
            value.startupError = nil
            // With Login Items unavailable the real request fails, so the simulation reports that.
            if value.startup == .unavailable {
                if enabled { value.startupError = "Couldn’t update Login Items. Try again." }
            } else {
                value.startup = enabled ? (value.startup == .needsApproval ? .needsApproval : .on) : .off
            }
        }
        window?.update(value)
    }
    func hear(_ active: [String]) {
        discovery?.tick(active: active)
        guard let discovery else { return }
        if case .waiting = discovery.phase { value.anotherApp = AnotherAppSheet(discovery.phase, app: nil) }
        else { value.anotherApp = AnotherAppSheet(discovery.phase, app: Preview.found) }
        window?.update(value)
    }
    @objc func restart() { window?.close(); show() }
    @objc func scenario(_ sender: NSMenuItem) {
        value = SetupSnapshot(apps: Preview.records(2)); volumeAvailable = true; discovery = nil
        switch sender.tag {
        case 1: value.apps = []
        case 7: value.apps = Preview.records(1)
        case 8: value.apps = Preview.records(12)
        case 9: value.apps = Preview.records(3, longName: true)
        case 10: value.session = .lowered
        case 11: value.session = .skipped
        case 2: volumeAvailable = false
        case 3: value.startup = .needsApproval
        case 4: value.startupError = "Couldn’t update Login Items. Try again."
        case 5: value.startup = .unavailable
        case 6: window?.close(); show(firstRun: false); return
        default: break
        }
        window?.update(value)
    }
}

let application = NSApplication.shared
let preview = Preview()
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render" {
    application.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func render(_ name: String, step: SetupStep, firstRun: Bool = true) throws {
        let controller = preview.make(step: step, firstRun: firstRun)
        let view = controller.window!.contentView!; view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
    }
    func chosen(_ apps: [DictationApp], _ ids: [Int]) -> [DictationApp] {
        apps.enumerated().map { index, app in var app = app; app.chosen = ids.contains(index); return app }
    }
    func renderSheet(_ name: String, _ sheet: AnotherAppSheet) throws {
        preview.value = SetupSnapshot(apps: Preview.records(2), anotherApp: sheet)
        let controller = preview.make(step: .choose)
        let view = controller.sheet!.contentView!; view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
    }
    try render("choose-two-apps", step: .choose)
    preview.value.apps = []; try render("choose-no-apps", step: .choose)
    preview.value.apps = chosen(Preview.records(1), [0]); try render("choose-one-app-chosen", step: .choose)
    preview.value.apps = chosen(Preview.records(2), [1]); try render("choose-note", step: .choose)
    preview.value.apps = chosen(Preview.records(12), [1]); try render("choose-twelve-apps", step: .choose)
    preview.value.apps = chosen(Preview.records(3, longName: true), [1]); try render("choose-long-name", step: .choose)
    try renderSheet("another-app-waiting", AnotherAppSheet(.waiting, app: nil))
    try renderSheet("another-app-hearing", AnotherAppSheet(.hearing(""), app: Preview.found))
    try renderSheet("another-app-found", AnotherAppSheet(.heard(""), app: Preview.found))
    try renderSheet("another-app-found-unknown", AnotherAppSheet(.heard(""), app: DictationApp(id: "preview.unknown", name: "Some Dictation App")))
    preview.value = SetupSnapshot(apps: chosen(Preview.records(2), [1])); try render("complete", step: .complete)
    preview.value.session = .lowered; try render("complete-lowered", step: .complete)
    preview.value.session = .skipped; try render("complete-volume-off", step: .complete)
    preview.value = SetupSnapshot(apps: Preview.records(2)); try render("find-your-quiet", step: .volume)
    preview.value.startup = .needsApproval; try render("login-approval", step: .volume)
    preview.value = SetupSnapshot(apps: Preview.records(2), startupError: "Couldn’t update Login Items. Try again."); try render("login-error", step: .volume)
    preview.value = SetupSnapshot(apps: Preview.records(2)); try render("one-thing-first", step: .attention)
    try render("settings", step: .volume, firstRun: false)
} else {
    application.setActivationPolicy(.regular); application.delegate = preview; application.run()
}
