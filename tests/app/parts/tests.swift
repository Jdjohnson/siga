// Tests for the verbatim `App` class. Each scenario starts from a fresh world.
var retained: [App] = []   // NotificationCenter observers must outlive the run
let launchNote = Notification(name: Notification.Name("NSApplicationDidFinishLaunchingNotification"))
let willow = "com.seewillow.WillowMac", superwhisper = "com.superduper.superwhisper", flow = "com.electron.wispr-flow"
let willowRoot = "/Applications/com.seewillow.WillowMac.app/"
let loginFailure = "Couldn’t update Login Items. Try again."
let terminateTimeoutText = "Sigá couldn’t confirm the restore in time. Check your Mac’s volume controls."
let terminateAlertTitle = "Sigá couldn’t restore your volume."

func resetWorld() {
    UserDefaults.standard = UserDefaults()
    SMAppService.mainApp = SMAppService(); SMAppService.settingsOpened = 0
    NSAlert.shown = []
    NSWorkspace.shared = NSWorkspace()
    NSRunningApplication.running = []
    SavedVolume.supported = true; SavedVolume.captures = 0
    Logger.messages = []
    NSApp.reset()
    DispatchQueue.main.pending = []; DispatchQueue.worker.pending = []
    FakeQueue.background.removeAll { $0 !== DispatchQueue.worker }
    DispatchSemaphore.waits = []; DispatchSemaphore.created = 0
    Ducking.created = 0
    bundleIDs = [:]
}
@discardableResult
func launch(setupComplete: Bool, volume: Int? = nil, apps: [String] = [willow], configure: () -> Void = {}) -> App {
    resetWorld()
    if setupComplete { UserDefaults.standard.set(true, forKey: "hasFinishedSetup"); UserDefaults.standard.set(apps, forKey: "dictationApps") }
    if let volume { UserDefaults.standard.set(volume, forKey: "volumePercent") }
    configure()
    let app = App(); retained.append(app)
    app.applicationDidFinishLaunching(launchNote)
    return app
}
func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil) {
    NSWorkspace.shared.notificationCenter.post(name: name, object: nil, userInfo: userInfo)
}
func menuTitles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }
func item(_ app: App, _ title: String) -> NSMenuItem? { app.status.menu?.items.first { $0.title == title } }
func savedApps() -> [String]? { UserDefaults.standard.values["dictationApps"] as? [String] }
func appsMenu(_ app: App) -> [NSMenuItem] { app.menuWillOpen(app.status.menu!); return item(app, "Dictation apps")?.submenu?.items ?? [] }
func hasFinished() -> Bool { UserDefaults.standard.values["hasFinishedSetup"] as? Bool == true }
func requestedAboutThreeSeconds(_ wait: DispatchSemaphore.Wait) -> Bool { wait.requestedSeconds > 2.9 && wait.requestedSeconds <= 3.0 }

// ───────────────────────────── (18) launch and the "Finish setting up Sigá" line ─────────────────────────────
do {
    let app = launch(setupComplete: false)
    check(app.info.title == "Finish setting up Sigá", "18a incomplete launch: info title is 'Finish setting up Sigá'")
    check(app.info.target === app, "18b incomplete launch: info target is the delegate")
    check(app.info.action == #selector(App.showSettings), "18c incomplete launch: info action is showSettings")
    check(app.enableItem.state == .off, "18d incomplete launch: Enabled item is off")
    check(app.welcome != nil && app.welcome?.presented == 1 && app.welcome?.firstRun == true && app.welcome?.percent == 30,
          "18e incomplete launch presents a first-run Welcome at the default 30%")
    check(!app.audioStarted && Ducking.created == 0, "18f incomplete launch starts no audio and builds no Ducking")
    app.startAudioIfNeeded()
    check(!app.audioStarted && Ducking.created == 0, "18g startAudioIfNeeded is a no-op while setup is incomplete")
    check(app.validateMenuItem(app.info), "16a the setup line validates enabled (actionable) during setup")
    check(menuTitles(app.status.menu) == ["Finish setting up Sigá", "Enabled", "Restore volume", "-", "Dictation apps", "Settings…", "Launch at login", "Quit Sigá"],
          "18h status menu order and titles (Quit renamed 'Quit Sigá')")
    check(app.status.menu?.delegate === app, "18i status menu delegate is the App (menuWillOpen refreshes login state)")
    let main = NSApp.mainMenu
    let quit = main?.items.first?.submenu?.items.first, close = main?.items.last?.submenu?.items.first
    check(main?.items.count == 2 && quit?.title == "Quit Sigá" && quit?.keyEquivalent == "q"
          && quit?.action == #selector(NSApplication.terminate(_:)) && quit?.target == nil,
          "18j hidden main menu carries ⌘Q → NSApplication.terminate(_:) through the responder chain")
    check(close?.title == "Close" && close?.keyEquivalent == "w" && close?.action == #selector(NSWindow.performClose(_:)) && close?.target == nil,
          "18k hidden main menu carries ⌘W → NSWindow.performClose(_:)")
    // Completing setup clears the target/action so the line becomes informational.
    UserDefaults.standard.set(true, forKey: "hasFinishedSetup"); UserDefaults.standard.set([willow], forKey: "dictationApps")
    app.startAudioIfNeeded()
    check(app.audioStarted && app.info.target == nil && app.info.action == nil, "18l after startAudioIfNeeded the info target/action are cleared")
    check(!app.validateMenuItem(item(app, "Restore volume")!), "16b Restore volume stays disabled right after start (nothing saved yet)")
}
do {
    NSRunningApplication.running = []
    let app = launch(setupComplete: true, volume: 22) { NSRunningApplication.running = [NSRunningApplication(bundleIdentifier: willow, pid: 4242)] }
    check(app.audioStarted && Ducking.created == 1 && app.audio.initialPercent == 22, "18m complete launch starts audio once with the stored percent")
    check(app.info.title == "Waiting for your dictation app" && app.info.target == nil && app.info.action == nil && app.enableItem.state == .on,
          "18n complete launch keeps the plain waiting line and Enabled on")
    check(app.welcome == nil, "18o complete launch shows no window")
    app.audio.queue.drain()
    check(app.audio.events == ["percent:22", "start", "show"] && app.audio.roots == [willowRoot], "18p audio queue receives percent, the running chosen app, start, show in order")
    post(NSWorkspace.willSleepNotification); app.audio.queue.drain()
    check(app.audio.events.last == "awake:false", "misc-a willSleepNotification reaches sleep() and pauses audio")
    NSRunningApplication.running = []
    post(NSWorkspace.didWakeNotification); app.audio.queue.drain()
    check(app.audio.events.last == "awake:true" && app.audio.roots.isEmpty, "misc-b didWakeNotification re-reads the running chosen apps then wakes audio")
}

// ───────────────────────────── (1)–(4) finishSetup ─────────────────────────────
do { // (1) capture probe fails
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    SavedVolume.supported = false
    welcome.pressStart(47)
    check(welcome.finishingLog == [true] && SavedVolume.captures == 0, "1a Start disables the window before the probe runs off-main")
    DispatchQueue.worker.drain()
    check(SavedVolume.captures == 1 && !hasFinished(), "1b probe runs once off-main and writes nothing by itself")
    DispatchQueue.main.drain()
    check(welcome.attentionShown == 1, "1c failed probe → controller.showAttention() once")
    check(welcome.finishingLog == [true, false], "1d failed probe → setFinishing(false)")
    check(!hasFinished() && UserDefaults.standard.values["volumePercent"] == nil, "1e failed probe writes neither hasFinishedSetup nor volume")
    check(!app.audioStarted && Ducking.created == 0, "1f failed probe starts no audio")
    check(app.welcome === welcome && welcome.closed == 0 && welcome.window?.isVisible == true, "1g failed probe leaves the window open")
}
do { // (2) capture probe succeeds
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    welcome.pressStart(47)
    DispatchQueue.worker.drain(); DispatchQueue.main.drain()
    check(welcome.finishingLog == [true, false], "2a successful probe re-enables the window before finishing")
    check(app.volumePercent == 47 && UserDefaults.standard.values["volumePercent"] as? Int == 47, "2b successful probe saves the chosen volume")
    check(hasFinished(), "2c successful probe writes hasFinishedSetup = true")
    check(app.audioStarted && Ducking.created == 1 && app.audio.initialPercent == 47, "2d startAudioIfNeeded builds Ducking with the saved volume")
    app.audio.queue.drain()
    check(app.audio.events == ["percent:47", "start", "show"], "2e audio starts once with the saved percent")
    check(welcome.completeShown == 1 && welcome.closed == 0 && welcome.window?.isVisible == true, "2f successful probe shows the complete page and leaves the window open")
    welcome.close(); DispatchQueue.main.drain()
    check(app.welcome == nil, "2g closing the complete page releases the controller on the main queue")
    check(app.info.target == nil && app.info.action == nil, "2h setup line target/action cleared once audio starts")
    check(welcome.attentionShown == 0, "2i successful probe never shows the attention page")
}
do { // (3) window closed while the probe is pending (close lands before the probe result)
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    welcome.pressStart(63)
    welcome.close()                       // user ⌘W during "Checking…"
    DispatchQueue.worker.drain(); DispatchQueue.main.drain()
    check(!hasFinished() && UserDefaults.standard.values["volumePercent"] == nil, "3a close-then-probe: nothing written")
    check(!app.audioStarted && Ducking.created == 0 && welcome.attentionShown == 0, "3b close-then-probe: no audio, no attention page")
    check(app.welcome == nil && SavedVolume.captures == 1, "3c close-then-probe: controller released, probe result discarded")
    observe("3: setFinishing(false) is never delivered to a closed controller (finishingLog=\(welcome.finishingLog)); harmless because the controller is discarded")
}
do { // (3') probe result lands first, but the window is already hidden (welcome still set)
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    welcome.pressStart(63)
    DispatchQueue.worker.drain()          // probe finished; result queued on main
    welcome.close()                       // close queued after it
    DispatchQueue.main.drain()
    check(!hasFinished() && UserDefaults.standard.values["volumePercent"] == nil && !app.audioStarted, "3d probe-then-close: isVisible guard blocks completion")
    check(app.welcome == nil, "3e probe-then-close: controller released afterwards")
}
do { // duplicate Start requests while one probe is pending
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    welcome.pressStart(40); welcome.pressStart(41)
    DispatchQueue.worker.drain(); DispatchQueue.main.drain()
    check(hasFinished() && app.volumePercent == 40 && welcome.completeShown == 1 && Ducking.created == 1 && SavedVolume.captures == 1,
          "3f a second Start while one check is pending is ignored")
}
do { // (4) setup already complete: Settings window "Done"
    let app = launch(setupComplete: true, volume: 30)
    app.audio.queue.drain()
    app.showSettings()
    let welcome = app.welcome!
    check(welcome.firstRun == false && welcome.presented == 1, "4a Settings opens a non-first-run Welcome")
    welcome.pressStart(55)
    check(app.volumePercent == 55 && SavedVolume.captures == 0 && welcome.finishingLog.isEmpty, "4b complete setup: saves without probing or disabling")
    check(welcome.closed == 1, "4c complete setup: closes the window")
    app.audio.queue.drain()
    check(app.audio.events.last == "percent:55", "4d live volume change reaches the running audio engine")
    DispatchQueue.main.drain()
    check(app.welcome == nil, "4e Done releases the controller")
    check(DispatchQueue.worker.pending.isEmpty, "4f complete setup queues no probe")
}
do { // finishSetup with no window (incomplete)
    let app = launch(setupComplete: false)
    app.welcome!.close(); DispatchQueue.main.drain()
    app.finishSetup(50)
    DispatchQueue.worker.drain(); DispatchQueue.main.drain()
    check(!hasFinished() && SavedVolume.captures == 0 && !app.audioStarted, "3g finishSetup without a controller does nothing")
}

// ───────────────────────────── (5)–(9) setLogin / reconcileStartupError ─────────────────────────────
do { // (5) notRegistered → register succeeds
    let app = launch(setupComplete: true)
    app.setLogin(true)
    let service = SMAppService.mainApp
    check(service.registered == 1 && service.unregistered == 0 && service.status == .enabled, "5a setLogin(true) from notRegistered registers once")
    check(app.startupError == nil && app.startupRequestedEnabled == nil, "5b successful register leaves no error and no pending request")
    check(app.loginItem.state == .on, "5c menu login state reflects enabled")
    check(NSAlert.shown.isEmpty && Logger.messages.isEmpty, "5d no alert, no log on success")
}
do { // (6) requiresApproval → open Login Items, no register
    let app = launch(setupComplete: true) { SMAppService.mainApp.status = .requiresApproval }
    app.setLogin(true)
    let service = SMAppService.mainApp
    check(SMAppService.settingsOpened == 1, "6a setLogin(true) from requiresApproval opens System Settings › Login Items")
    check(service.registered == 0 && service.unregistered == 0, "6b requiresApproval does not register again")
    check(app.startupError == nil && app.loginItem.state == .mixed && NSAlert.shown.isEmpty, "6c approval pending: no error, mixed menu state, no alert")
}
do { // (7a) register throws, no window, setup incomplete → alert
    let app = launch(setupComplete: false)
    app.welcome!.close(); DispatchQueue.main.drain()
    SMAppService.mainApp.registerError = HarnessError.registerFailed
    app.setLogin(true)
    check(app.startupError == loginFailure && app.startupRequestedEnabled == true, "7a failed register sets startupError and remembers the request")
    check(NSAlert.shown.count == 1 && NSAlert.shown.first?.messageText == "Couldn’t update launch at login."
          && NSAlert.shown.first?.informativeText == "Try again from the Sigá menu.", "7b with no window the error is shown once as an alert")
    check(NSAlert.shown.first?.activationsWhenShown == 1, "7c notice activates the app before the modal")
    check(app.loginItem.state == .off && SMAppService.mainApp.status == .notRegistered, "7d menu state stays truthful (off) after the failure")
    check(Logger.messages.count == 1 && Logger.messages[0].hasPrefix("Launch at login failed: state=0 domain=") && Logger.messages[0].contains(" code="),
          "7e failure is logged with previous state, domain, code")
}
do { // (7b) register throws, Settings window open (setup complete) → alert
    let app = launch(setupComplete: true)
    app.showSettings()
    SMAppService.mainApp.registerError = HarnessError.registerFailed
    app.toggleLogin()
    check(NSAlert.shown.count == 1 && app.startupError == loginFailure, "7f setup complete with Settings open: alert still shown once")
    check(app.welcome?.snapshots.last?.startupError == loginFailure, "7g Settings window also receives the snapshot with the error")
}
do { // (7c) register throws during first-run setup with the window present → no alert; note via refreshSetup/update
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    SMAppService.mainApp.registerError = HarnessError.registerFailed
    welcome.toggleLoginCheckbox(true)
    check(NSAlert.shown.isEmpty, "7h first-run window present: no alert")
    check(welcome.snapshots.last == SetupSnapshot(startup: .off, startupError: loginFailure),
          "7i first-run window receives the error in its snapshot (checkbox note) with truthful startup=off")
    check(app.startupError == loginFailure && app.loginItem.state == .off, "7j error retained; menu state truthful")
}
do { // (8) setLogin(false)
    let app = launch(setupComplete: true) { SMAppService.mainApp.status = .enabled }
    app.setLogin(false)
    check(SMAppService.mainApp.unregistered == 1 && SMAppService.mainApp.status == .notRegistered, "8a setLogin(false) from enabled unregisters")
    check(app.startupError == nil && app.startupRequestedEnabled == nil && app.loginItem.state == .off && NSAlert.shown.isEmpty, "8b successful unregister: clean state")
    let idle = launch(setupComplete: true)
    idle.setLogin(false)
    check(SMAppService.mainApp.registered == 0 && SMAppService.mainApp.unregistered == 0 && SMAppService.settingsOpened == 0 && idle.startupError == nil,
          "8c setLogin(false) from notRegistered is a no-op")
    let missing = launch(setupComplete: true) { SMAppService.mainApp.status = .notFound }
    missing.setLogin(false)
    check(SMAppService.mainApp.unregistered == 0 && missing.startupError == nil && NSAlert.shown.isEmpty, "8d setLogin(false) from notFound is a no-op")
    let already = launch(setupComplete: true) { SMAppService.mainApp.status = .enabled }
    already.setLogin(true)
    check(SMAppService.mainApp.registered == 0 && already.startupError == nil, "8e setLogin(true) from enabled is a no-op")
    let pending = launch(setupComplete: true) { SMAppService.mainApp.status = .requiresApproval }
    pending.setLogin(false)
    check(SMAppService.mainApp.unregistered == 1 && SMAppService.mainApp.status == .notRegistered, "8f setLogin(false) from requiresApproval unregisters the pending item")
    let broken = launch(setupComplete: true) { SMAppService.mainApp.status = .enabled; SMAppService.mainApp.unregisterError = HarnessError.unregisterFailed }
    broken.setLogin(false)
    check(broken.startupError == loginFailure && broken.startupRequestedEnabled == false && broken.loginItem.state == .on && NSAlert.shown.count == 1,
          "8g failed unregister: error, request=false, menu still on, one alert")
    let retry = launch(setupComplete: true) { SMAppService.mainApp.status = .notFound }
    retry.setLogin(true)
    check(SMAppService.mainApp.registered == 1 && retry.startupError == nil && retry.loginItem.state == .on, "8h setLogin(true) from notFound still attempts registration")
}
do { // (9) reconcileStartupError
    let app = launch(setupComplete: true) { SMAppService.mainApp.registerError = HarnessError.registerFailed }
    app.setLogin(true)
    check(app.startupError != nil, "9a precondition: failed enable leaves an error")
    app.reconcileStartupError()
    check(app.startupError == loginFailure && app.startupRequestedEnabled == true, "9b error persists while macOS still reports notRegistered")
    SMAppService.mainApp.status = .requiresApproval; app.reconcileStartupError()
    check(app.startupError == loginFailure, "9c requiresApproval does not satisfy a requested enable")
    SMAppService.mainApp.status = .enabled; app.reconcileStartupError()
    check(app.startupError == nil && app.startupRequestedEnabled == nil && SMAppService.mainApp.registered == 1, "9d enabled clears the error without another register")
    let off = launch(setupComplete: true) { SMAppService.mainApp.status = .enabled; SMAppService.mainApp.unregisterError = HarnessError.unregisterFailed }
    off.setLogin(false)
    SMAppService.mainApp.status = .notRegistered; off.reconcileStartupError()
    check(off.startupError == nil && off.startupRequestedEnabled == nil && SMAppService.mainApp.registered == 0, "9e notRegistered clears a failed disable without re-registering")
    let viaWindow = launch(setupComplete: false) { SMAppService.mainApp.registerError = HarnessError.registerFailed }
    viaWindow.welcome!.toggleLoginCheckbox(true)
    SMAppService.mainApp.status = .enabled
    viaWindow.welcome!.windowBecameKey()
    check(viaWindow.welcome!.snapshots.last == SetupSnapshot(startup: .on, startupError: nil), "9f refreshSetup reconciles first, so the window sees on + no error")
    let clean = launch(setupComplete: true)
    clean.startupRequestedEnabled = true; clean.reconcileStartupError()
    check(clean.startupRequestedEnabled == nil, "9g no error → stale request is dropped")
}
do { // toggleLogin and menu plumbing
    let app = launch(setupComplete: true) { SMAppService.mainApp.status = .enabled }
    app.toggleLogin()
    check(SMAppService.mainApp.unregistered == 1 && SMAppService.mainApp.status == .notRegistered, "misc-c toggleLogin from enabled → unregister")
    app.toggleLogin()
    check(SMAppService.mainApp.registered == 1 && SMAppService.mainApp.status == .enabled, "misc-d toggleLogin from notRegistered → register")
    SMAppService.mainApp.status = .requiresApproval; app.toggleLogin()
    check(SMAppService.settingsOpened == 1 && SMAppService.mainApp.registered == 1, "misc-e toggleLogin from requiresApproval → Login Items")
    app.loginItem.state = .off; SMAppService.mainApp.status = .enabled
    app.menuWillOpen(app.status.menu!)
    check(app.loginItem.state == .on, "misc-f menuWillOpen re-reads the real login state")
    app.setupAction(.openLoginItems)
    check(SMAppService.settingsOpened == 2, "misc-g setupAction(.openLoginItems) opens Login Items")
    app.setupAction(.login(false))
    check(SMAppService.mainApp.unregistered == 2, "misc-h setupAction(.login(false)) routes to setLogin")
    NSWorkspace.shared.openSucceeds = true; app.setupAction(.soundSettings)
    check(NSWorkspace.shared.opened.last?.absoluteString == "x-apple.systempreferences:com.apple.Sound-Settings.extension", "misc-j soundSettings opens the Sound pane")
    NSWorkspace.shared.openSucceeds = false; NSWorkspace.shared.installed = ["com.apple.systempreferences"]; app.setupAction(.soundSettings)
    check(NSWorkspace.shared.opened.suffix(2).map(\.absoluteString) == ["x-apple.systempreferences:com.apple.Sound-Settings.extension", "file:///Applications/com.apple.systempreferences.app"],
          "misc-k soundSettings falls back to opening System Settings itself")
}

// ───────────────────────────── (10)–(15) applicationShouldTerminate ─────────────────────────────
do { // (10) audio never started
    let app = launch(setupComplete: false)
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow, "10a incomplete setup → .terminateNow")
    check(Ducking.created == 0 && DispatchSemaphore.created == 0 && NSAlert.shown.isEmpty, "10b no Ducking, no wait, no alert")
}
do { // (11) restore succeeds (nil advice)
    let app = launch(setupComplete: true)
    app.audio.terminateBehavior = .immediate(nil)
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow && app.audio.terminateCalls == 1, "11a successful restore → .terminateNow after one terminate call")
    check(NSAlert.shown.isEmpty, "11b successful restore → no alert")
    check(DispatchSemaphore.waits.count == 1 && DispatchSemaphore.waits[0].result == .success && requestedAboutThreeSeconds(DispatchSemaphore.waits[0]),
          "11c waits once with a 3 s bound and is released by the completion")
}
do { // (12) restore fails with advice
    let advice = "Set it back to about 60% with your Mac’s volume controls."
    let app = launch(setupComplete: true)
    app.audio.terminateBehavior = .immediate(advice)
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow, "12a failed restore still → .terminateNow")
    check(NSAlert.shown.count == 1 && NSAlert.shown.first?.informativeText == advice && NSAlert.shown.first?.messageText == terminateAlertTitle,
          "12b exactly one alert carrying the advice text")
    check(NSAlert.shown.first?.activationsWhenShown == 1, "12c alert is preceded by app activation")
    let later = launch(setupComplete: true)
    later.audio.terminateBehavior = .deferred(advice)   // completion arrives asynchronously on the audio queue
    check(later.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.count == 1 && NSAlert.shown.first?.informativeText == advice,
          "12d a completion that lands later on the audio queue is still awaited")
}
do { // (13) restore never completes while a lowered volume is mirrored on the main thread
    let app = launch(setupComplete: true)
    app.audio.display(AudioStatus(title: "Volume lowered · 30%", detail: nil, lowered: true, enabled: true, restorable: true)); DispatchQueue.main.drain()
    check(app.restorable, "13-pre display() mirrored restorable = true")
    app.audio.terminateBehavior = .never
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow, "13a timeout → .terminateNow")
    check(NSAlert.shown.count == 1 && NSAlert.shown.first?.informativeText == terminateTimeoutText && NSAlert.shown.first?.messageText == terminateAlertTitle,
          "13b timeout → exactly one alert with the timeout text")
    check(DispatchSemaphore.waits.count == 1 && DispatchSemaphore.waits[0].result == .timedOut && requestedAboutThreeSeconds(DispatchSemaphore.waits[0]),
          "13c the wait is bounded at 3 s")
    // (15) late completion after the timeout, then a second termination request
    app.audio.pendingTerminations.removeFirst()(nil)
    check(NSAlert.shown.count == 1, "15a a completion arriving after the timeout adds no alert")
    let second = app.applicationShouldTerminate(NSApp)
    check(second == .terminateNow && NSAlert.shown.count == 1 && app.audio.terminateCalls == 1, "15b second request: no second attempt, no second alert, still .terminateNow")
    check(app.terminating && DispatchSemaphore.created == 1 && DispatchSemaphore.waits.count == 1, "15c the guard skips the wait entirely on a repeated request")
    let mixed = launch(setupComplete: true)
    mixed.audio.terminateBehavior = .immediate("Use your Mac’s volume controls to set it back.")
    _ = mixed.applicationShouldTerminate(NSApp)
    mixed.audio.terminateBehavior = .immediate(nil)
    check(mixed.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.count == 1 && mixed.audio.terminateCalls == 1, "15d a second request adds no alert and no attempt")
    let fresh = launch(setupComplete: true)
    check(!fresh.terminating, "15e terminating starts false")
}
do { // (14) powering off suppresses the alert
    let app = launch(setupComplete: true)
    post(NSWorkspace.willPowerOffNotification)
    check(app.poweringOff, "14a willPowerOffNotification sets poweringOff")
    app.audio.terminateBehavior = .immediate("Set it back to about 42% with your Mac’s volume controls.")
    check(app.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.isEmpty, "14b powering off + failed restore → no alert, .terminateNow")
    check(app.audio.terminateCalls == 1 && DispatchSemaphore.waits.count == 1 && requestedAboutThreeSeconds(DispatchSemaphore.waits[0]), "14c powering off still attempts the bounded restore")
    let timeout = launch(setupComplete: true)
    timeout.audio.display(AudioStatus(title: "Volume lowered · 30%", detail: nil, lowered: true, enabled: true, restorable: true)); DispatchQueue.main.drain()
    post(NSWorkspace.willPowerOffNotification)
    timeout.audio.terminateBehavior = .never
    check(timeout.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.isEmpty, "14d powering off + timeout with a lowered volume → no alert, .terminateNow")
}
do { // quit menu item
    let app = launch(setupComplete: true)
    app.quit()
    check(NSApp.terminateRequests == 1, "misc-l Quit Sigá asks NSApp to terminate (AppKit then calls applicationShouldTerminate)")
}

// ───────────────────────────── (16) validateMenuItem ─────────────────────────────
do {
    let app = launch(setupComplete: true)
    let items = app.status.menu!.items
    app.restorable = false
    check(items.allSatisfy { app.validateMenuItem($0) == ($0.title != "Restore volume") }, "16c restorable=false: only Restore volume is disabled")
    app.restorable = true
    check(items.allSatisfy { app.validateMenuItem($0) }, "16d restorable=true: every item validates")
    let restore = item(app, "Restore volume")!
    check(restore.action == #selector(App.restoreManually) && restore.target === app, "16e Restore volume targets restoreManually on the App")
}

// ───────────────────────────── (17) display closure ─────────────────────────────
do {
    let app = launch(setupComplete: true)
    app.audio.display(AudioStatus(title: "Volume lowered · 30%", detail: nil, lowered: true, enabled: true, restorable: true))
    check(app.info.title == "Volume lowered · 30%" && app.info.toolTip == nil, "17a title set, no tooltip without detail")
    check(app.enableItem.state == .on && app.restorable == true, "17b enabled → on, restorable mirrored")
    check(app.status.button?.toolTip == "Sigá · Volume lowered · 30%", "17c status tooltip 'Sigá · <title>' without detail")
    check(app.status.button?.appearsDisabled == true, "17d appearsDisabled == lowered (true)")
    check(app.validateMenuItem(item(app, "Restore volume")!), "16f Restore volume validates once restorable")
    app.audio.display(AudioStatus(title: "Couldn’t restore volume", detail: "Restore failed: Saved output is unavailable", lowered: false, enabled: false, restorable: true))
    check(app.info.title == "Couldn’t restore volume" && app.info.toolTip == "Restore failed: Saved output is unavailable", "17e short title, technical detail in the tooltip")
    check(app.enableItem.state == .off, "17f enabled=false → off")
    check(app.status.button?.toolTip == "Sigá · Couldn’t restore volume\nRestore failed: Saved output is unavailable", "17g status tooltip appends the detail on a new line")
    check(app.status.button?.appearsDisabled == false, "17h appearsDisabled == lowered (false)")
    app.audio.display(AudioStatus(title: "Ready", detail: nil, lowered: false, enabled: true, restorable: false))
    check(app.restorable == false && !app.validateMenuItem(item(app, "Restore volume")!), "17i restorable=false disables Restore volume again")
}

// ───────────────────────────── (19) refreshSetup snapshot ─────────────────────────────
do {
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    let before = welcome.snapshots.count
    for (status, expected) in [(SMAppService.Status.enabled, StartupState.on), (.requiresApproval, .needsApproval), (.notRegistered, .off), (.notFound, .unavailable)] {
        SMAppService.mainApp.status = status
        app.refreshSetup()
        check(welcome.snapshots.last?.startup == expected, "19 \(status) → \(expected)")
    }
    check(welcome.snapshots.count == before + 4, "19e each refreshSetup delivers exactly one snapshot")
    SMAppService.mainApp.status = .notRegistered
    app.refreshSetup()
    check(welcome.snapshots.last?.apps == [], "19f nothing installed → no rows")
    NSWorkspace.shared.installed = [willow, flow]; app.refreshSetup()
    check(welcome.snapshots.last?.apps.map(\.id) == [willow] && welcome.snapshots.last?.apps.first?.chosen == false,
          "19g an installed tile is offered unchosen; an installed app without a tile is not offered")
    check(welcome.snapshots.last?.apps.first?.path == "/Applications/\(willow).app", "19h the row carries where the app is installed, for its icon")
    NSWorkspace.shared.installed = []; app.refreshSetup()
    check(welcome.snapshots.last == SetupSnapshot(), "19j full snapshot with nothing installed and login off")
    welcome.close(); DispatchQueue.main.drain()
    let count = welcome.snapshots.count
    app.refreshSetup()
    check(welcome.snapshots.count == count, "19k refreshSetup without a window is a no-op")
}

// ───────────────────────────── appsChanged, toggles, sleep/wake, saveVolume ─────────────────────────────
do {
    let app = launch(setupComplete: true)
    app.showSettings()
    let welcome = app.welcome!
    let snapshots = welcome.snapshots.count
    NSRunningApplication.running = [NSRunningApplication(bundleIdentifier: "com.apple.Music", pid: 9)]
    app.audio.queue.drain()
    check(welcome.snapshots.count == snapshots && !app.audio.events.contains { $0.hasPrefix("roots") }, "misc-m apps that were not chosen launching are ignored")
    let instance = NSRunningApplication(bundleIdentifier: willow, pid: 4242)
    NSRunningApplication.running = [instance]
    post(NSWorkspace.didLaunchApplicationNotification, [NSWorkspace.applicationUserInfoKey: instance])
    app.audio.queue.drain()
    check(app.audio.events.last == "roots:\(willowRoot)", "misc-n a chosen app launching hands where it is running to audio")
    NSRunningApplication.running = []
    post(NSWorkspace.didTerminateApplicationNotification, [NSWorkspace.applicationUserInfoKey: instance])
    app.audio.queue.drain()
    check(app.audio.events.last == "roots:", "misc-o a chosen app quitting leaves nothing to watch")
    app.toggleEnabled(); app.audio.queue.drain()
    check(app.audio.events.last == "enabled:false" && app.audio.enabled == false, "misc-p Enabled toggles the engine off")
    app.toggleEnabled(); app.audio.queue.drain()
    check(app.audio.events.last == "enabled:true", "misc-q Enabled toggles the engine back on")
    app.restoreManually(); app.audio.queue.drain()
    check(app.audio.events.last == "manualRestore", "misc-r Restore volume asks the engine for a manual restore")
    app.saveVolume(120); app.audio.queue.drain()
    check(app.volumePercent == 100 && app.audio.events.last == "percent:100", "misc-s saveVolume clamps to 100 and forwards")
    let writes = UserDefaults.standard.writes.count
    app.saveVolume(100); app.audio.queue.drain()
    check(UserDefaults.standard.writes.count == writes && app.audio.events.last == "percent:100" && app.audio.queue.pending.isEmpty, "misc-t unchanged volume writes nothing and sends nothing")
    app.saveVolume(-5)
    check(app.volumePercent == 0, "misc-u saveVolume clamps to 0")
}
do {
    let app = launch(setupComplete: false)
    let welcome = app.welcome!
    app.toggleEnabled()
    check(welcome.presented == 2 && Ducking.created == 0, "misc-v Enabled during setup re-presents the setup window instead of touching audio")
    app.restoreManually(); app.sleep(); app.wake()
    check(Ducking.created == 0 && !app.audioStarted, "misc-w Restore/sleep/wake during setup never build audio")
    welcome.close(); DispatchQueue.main.drain()
    app.showSettings()
    check(app.welcome !== welcome && app.welcome?.firstRun == true && app.welcome?.presented == 1, "misc-x reopening after close builds a fresh first-run window")
    let same = app.welcome
    app.showSettings()
    check(app.welcome === same && same?.presented == 2, "misc-y showSettings re-presents an existing window")
}

// ───────────────────────────── (T) build-11 termination review ─────────────────────────────
do { // T1 a second Quit (status menu, ⌘Q, or a quit Apple event) arriving while the failure alert is modal
    let advice = "Set it back to about 60% with your Mac’s volume controls."
    let app = launch(setupComplete: true)
    app.audio.terminateBehavior = .immediate(advice)
    var inner: NSApplication.TerminateReply?
    var innerSemaphores = -1, innerAlerts = -1, innerCalls = -1
    NSAlert.whileModal = {
        // AppKit re-enters terminate: → applicationShouldTerminate while runModal is still on the stack.
        inner = app.applicationShouldTerminate(NSApp)
        innerSemaphores = DispatchSemaphore.created; innerAlerts = NSAlert.shown.count; innerCalls = app.audio.terminateCalls
    }
    let outer = app.applicationShouldTerminate(NSApp)
    check(inner == .terminateNow, "T1a re-entrant Quit during the alert → .terminateNow immediately")
    check(innerSemaphores == 1 && innerAlerts == 1 && innerCalls == 1, "T1b re-entrant Quit adds no wait, no alert, no restore attempt")
    check(outer == .terminateNow && NSAlert.shown.count == 1 && DispatchSemaphore.waits.count == 1, "T1c the outer request still ends with one alert and one wait")
}
do { // T2 logout begins while the failure alert is modal: willPowerOff lands, then the quit Apple event
    let app = launch(setupComplete: true)
    app.audio.terminateBehavior = .immediate("Use your Mac’s volume controls to set it back.")
    var inner: NSApplication.TerminateReply?
    NSAlert.whileModal = {
        post(NSWorkspace.willPowerOffNotification)
        inner = app.applicationShouldTerminate(NSApp)
    }
    _ = app.applicationShouldTerminate(NSApp)
    check(app.poweringOff && inner == .terminateNow && NSAlert.shown.count == 1 && app.audio.terminateCalls == 1,
          "T2a logout during the alert: .terminateNow, one alert, one attempt")
}
do { // T3 timeout with nothing to restore (audio queue unresponsive; nothing was ever lowered)
    let app = launch(setupComplete: true)
    check(!app.restorable, "T3a precondition: nothing restorable on the main-thread mirror")
    app.audio.terminateBehavior = .never
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow, "T3b timeout → .terminateNow")
    check(NSAlert.shown.isEmpty, "T3c timeout with nothing restorable shows no ‘couldn’t restore your volume’ alert")
    check(DispatchSemaphore.waits.count == 1 && requestedAboutThreeSeconds(DispatchSemaphore.waits[0]), "T3d the bounded wait still happens")
    observe("T3 alerts shown=\(NSAlert.shown.count) text=\(NSAlert.shown.first.map { "\($0.messageText) / \($0.informativeText)" } ?? "none")")
}
do { // T4 a logout cancelled elsewhere leaves Sigá running; a later explicit Quit whose restore fails must still say so
    let advice = "Set it back to about 42% with your Mac’s volume controls."
    let app = launch(setupComplete: true)
    post(NSWorkspace.willPowerOffNotification)      // logout began…
    // …another app cancelled it before Sigá was asked to quit. The user keeps using Sigá for hours.
    app.menuWillOpen(app.status.menu!); app.showSettings(); app.refreshSetup()
    post(NSWorkspace.willSleepNotification); post(NSWorkspace.didWakeNotification)
    app.audio.queue.drain(); DispatchQueue.main.drain()
    check(!app.poweringOff, "T4a opening the menu after a cancelled logout resets poweringOff")
    app.audio.terminateBehavior = .immediate(advice)
    app.quit()   // status-menu Quit Sigá → NSApp.terminate(nil) → applicationShouldTerminate
    let reply = app.applicationShouldTerminate(NSApp)
    check(reply == .terminateNow && app.audio.terminateCalls == 1, "T4b explicit Quit still makes one bounded attempt")
    check(NSAlert.shown.count == 1 && NSAlert.shown.first?.informativeText == advice, "T4c explicit Quit after a cancelled logout shows the failure message")
    observe("T4 alerts shown=\(NSAlert.shown.count) poweringOff=\(app.poweringOff)")
}
do { // T5 first Quit during the login-failure alert (a modal already up), then Quit again inside the termination alert
    let app = launch(setupComplete: true)
    SMAppService.mainApp.registerError = HarnessError.registerFailed
    app.audio.terminateBehavior = .immediate("Use your Mac’s volume controls to set it back.")
    var replies: [NSApplication.TerminateReply] = []
    NSAlert.whileModal = {                                   // inside the launch-at-login alert
        NSAlert.whileModal = { replies.append(app.applicationShouldTerminate(NSApp)) }   // inside the termination alert
        replies.append(app.applicationShouldTerminate(NSApp))
    }
    app.setLogin(true)
    check(replies == [.terminateNow, .terminateNow] && NSAlert.shown.count == 2 && app.audio.terminateCalls == 1 && DispatchSemaphore.created == 1,
          "T5a nested modals: one restore attempt, one termination alert, both requests .terminateNow")
}
do { // T7 poweringOff resets on activation too, and a fresh power-off notice still suppresses
    let app = launch(setupComplete: true)
    post(NSWorkspace.willPowerOffNotification)
    check(app.poweringOff, "T7a power-off notice sets the flag")
    app.applicationDidBecomeActive(Notification(name: Notification.Name("NSApplicationDidBecomeActiveNotification")))
    check(!app.poweringOff, "T7b app activation (a click on Sigá) resets it")
    post(NSWorkspace.willSleepNotification); post(NSWorkspace.didWakeNotification); app.refreshSetup(); app.audio.queue.drain(); DispatchQueue.main.drain()
    check(!app.poweringOff, "T7c sleep, wake, and setup refresh leave it false")
    post(NSWorkspace.willPowerOffNotification)
    app.audio.terminateBehavior = .immediate("Set it back to about 42% with your Mac’s volume controls.")
    check(app.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.isEmpty && app.audio.terminateCalls == 1, "T7d a new power-off notice right before the quit still suppresses the alert")
    let timeout = launch(setupComplete: true)
    timeout.audio.display(AudioStatus(title: "Volume lowered · 30%", detail: nil, lowered: true, enabled: true, restorable: true)); DispatchQueue.main.drain()
    post(NSWorkspace.willPowerOffNotification); timeout.menuWillOpen(timeout.status.menu!)
    timeout.audio.terminateBehavior = .never
    check(timeout.applicationShouldTerminate(NSApp) == .terminateNow && NSAlert.shown.count == 1 && NSAlert.shown.first?.informativeText == terminateTimeoutText, "T7e cancelled logout, then a timeout with a lowered volume: the message shows")
}
do { // T6 the fast path never marks terminating, and a completed first attempt never re-arms
    let app = launch(setupComplete: false)
    _ = app.applicationShouldTerminate(NSApp)
    check(!app.terminating, "T6a incomplete setup → .terminateNow without touching the flag")
    let done = launch(setupComplete: true)
    done.audio.terminateBehavior = .immediate(nil)
    _ = done.applicationShouldTerminate(NSApp)
    post(NSWorkspace.didWakeNotification); done.menuWillOpen(done.status.menu!); done.audio.queue.drain(); DispatchQueue.main.drain()
    check(done.terminating && done.applicationShouldTerminate(NSApp) == .terminateNow && done.audio.terminateCalls == 1,
          "T6b after a completed attempt, later requests never start a second attempt")
}

// ───────────────────────────── choosing apps, Use another app…, and the done-page line ─────────────────────────────
func relaunch() -> App { let app = App(); retained.append(app); app.applicationDidFinishLaunching(launchNote); return app }
func finish(_ app: App) { app.welcome!.pressStart(30); DispatchQueue.worker.drain(); DispatchQueue.main.drain() }
func running(_ id: String, _ pid: pid_t) -> NSRunningApplication { NSRunningApplication(bundleIdentifier: id, pid: pid) }
let flowRoot = "/Applications/Wispr Flow.app/"
let flowHelper = flowRoot + "Contents/Frameworks/Wispr Flow Helper.app/Contents/MacOS/Wispr Flow Helper"
let zoom = "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
do { // S1 choose one app, leave the other; after a restart only that one is on, in the window and the menu
    let app = launch(setupComplete: false) { NSWorkspace.shared.installed = [willow, superwhisper] }
    let welcome = app.welcome!
    welcome.windowBecameKey()
    check(welcome.snapshots.last?.apps.map(\.id) == [willow, superwhisper] && welcome.snapshots.last?.apps.allSatisfy { !$0.chosen } == true && welcome.snapshots.last?.canContinue == false,
          "S1a verified installed tiles are offered with nothing preselected")
    app.setupAction(.choose(superwhisper, true))
    check(welcome.snapshots.last?.apps.filter(\.chosen).map(\.id) == [superwhisper] && welcome.snapshots.last?.canContinue == true && savedApps() == nil,
          "S1b the choice is a draft until Start")
    finish(app)
    check(savedApps() == [superwhisper] && hasFinished(), "S1c Start saves the choice")
    NSRunningApplication.running = [running(willow, 1), running(superwhisper, 2)]
    let again = relaunch(); again.audio.queue.drain()
    check(again.welcome == nil && again.audio.roots == ["/Applications/\(superwhisper).app/"], "S1d after a restart only the chosen app is watched, though both are running")
    let items = appsMenu(again)
    check(items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Willow", "superwhisper", "-", "Use another app…"]
          && items[0].state == .off && items[1].state == .on, "S1e the menu shows the same choice")
    check(items[1].toolTip?.contains("Playback when recording to Keep Playing") == true && items[1].toolTip?.hasSuffix("Sigá handles the volume.") == true,
          "S1f the chosen app's menu item carries what to switch off, by name")
    NSRunningApplication.running.append(running("com.apple.Music", 9)); again.audio.queue.drain()
    check(!again.audio.events.contains { $0.hasPrefix("roots") }, "S1g an app that was not chosen is never turned on later")
    again.toggleApp(items[0]); again.audio.queue.drain()
    check(savedApps() == [superwhisper, willow] && again.audio.events.last == "roots:/Applications/\(superwhisper).app/,\(willowRoot)", "S1h choosing in the menu saves and takes effect at once")
    again.toggleApp(appsMenu(again)[0]); again.audio.queue.drain()
    check(savedApps() == [superwhisper] && again.audio.events.last == "roots:/Applications/\(superwhisper).app/", "S1i and so does un-choosing")
}
do { // S2 nothing recognized is installed
    let app = launch(setupComplete: false)
    app.welcome!.windowBecameKey()
    check(app.welcome!.snapshots.last?.apps.isEmpty == true && app.welcome!.snapshots.last?.canContinue == false,
          "S2a with no recognized app, Use another app… stands alone and Continue is off")
    check(appsMenu(app).map(\.title) == ["Use another app…"], "S2b the menu offers the same")
}
do { // S3 choose, then un-choose
    let app = launch(setupComplete: false) { NSWorkspace.shared.installed = [willow] }
    app.setupAction(.choose(willow, true)); app.setupAction(.choose(willow, false))
    check(app.welcome!.snapshots.last?.canContinue == false && app.chosen.isEmpty, "S3a un-choosing the only app turns Continue off again")
    app.welcome!.close(); DispatchQueue.main.drain()
    check(savedApps() == nil && !hasFinished() && !app.audioStarted, "S3b nothing was saved and nothing started")
}
do { // S4 a setup finished before apps could be chosen
    resetWorld()
    UserDefaults.standard.set(true, forKey: "hasFinishedSetup"); UserDefaults.standard.set(45, forKey: "volumePercent")
    NSWorkspace.shared.installed = [willow]
    let app = relaunch()
    check(app.welcome?.firstRun == true && app.welcome?.percent == 45 && !app.audioStarted, "S4a it is asked to choose once, keeps its volume, and lowers nothing until then")
    app.setupAction(.choose(willow, true)); finish(app)
    check(savedApps() == [willow] && app.audioStarted, "S4b Start saves the choice and begins")
}
do { // (9) Use another app…
    let app = launch(setupComplete: false) { NSWorkspace.shared.installed = [willow, flow] }
    let welcome = app.welcome!
    bundleIDs = [flowRoot: flow, "/Applications/zoom.us.app/": "us.zoom.xos"]
    app.setupAction(.useAnotherApp); app.audio.queue.drain()
    let waiting = welcome.snapshots.last?.anotherApp
    check(waiting == AnotherAppSheet(.waiting, app: nil) && waiting?.canAdd == false, "9a the sheet opens waiting, with Add off")
    check(waiting?.note == "Turn off your dictation app’s automatic muting, pausing, and volume lowering. Sigá handles the volume.",
          "9b what to switch off is on the sheet before Add can be pressed")
    check(app.audio.events == ["watchAll:on"] && !app.audioStarted, "9c it only watches; the engine is not started and nothing is lowered")
    let report = app.audio.report!
    report([zoom, "/usr/libexec/tool"])
    report([zoom, flowHelper, "/Applications/NoInfo.app/Contents/MacOS/NoInfo"])
    let hearing = welcome.snapshots.last?.anotherApp
    check(hearing?.headline == "Hearing Wispr Flow. Stop dictating to finish." && hearing?.canAdd == false,
          "9d a call already under way is never offered; the app whose helper started is, by its outermost bundle")
    check(hearing?.note == "In Wispr Flow, keep Mute music while dictating turned off. Sigá also lowers the volume during Flow Notetaker. Sigá handles the volume.", "9e a known app's setting is named exactly")
    app.setupAction(.addApp); app.audio.queue.drain()
    check(app.chosen.isEmpty && welcome.snapshots.last?.anotherApp == nil && app.audio.events.last == "watchAll:off",
          "9f Add before a stop was heard chooses nothing, and the watching ends with the sheet")
    app.setupAction(.useAnotherApp); app.audio.queue.drain()
    app.audio.report!([]); app.audio.report!([flowHelper]); app.audio.report!([])
    let found = welcome.snapshots.last?.anotherApp
    check(found?.headline == "Found Wispr Flow." && found?.canAdd == true
          && found?.warning == "Sigá lowers everything your Mac plays whenever Wispr Flow uses the microphone, including calls.", "9g start then stop enables Add, beside the warning")
    app.setupAction(.tryAgain)
    check(welcome.snapshots.last?.anotherApp == AnotherAppSheet(.waiting, app: nil), "9h Try again starts over")
    app.audio.report!([flowHelper]); app.audio.report!([])
    check(welcome.snapshots.last?.anotherApp?.canAdd == false, "9i and what was already on the microphone then does not count")
    app.audio.report!([flowHelper]); app.audio.report!([])
    app.setupAction(.cancelAnotherApp); app.audio.queue.drain()
    check(app.chosen.isEmpty && savedApps() == nil && welcome.snapshots.last?.anotherApp == nil, "9j Cancel after a find saves nothing")
    app.setupAction(.useAnotherApp); app.audio.queue.drain()
    app.audio.report!([]); app.audio.report!([flowHelper]); app.audio.report!([])
    app.setupAction(.addApp); app.audio.queue.drain()
    let rows = welcome.snapshots.last?.apps ?? []
    check(app.chosen == [flow] && rows.map(\.id) == [willow, flow] && rows.last?.chosen == true && rows.last?.name == "Wispr Flow" && savedApps() == nil,
          "9k Add keeps installed tiles and shows the chosen custom app; during setup it is still a draft")
    app.setupAction(.useAnotherApp); app.audio.queue.drain()
    welcome.close(); DispatchQueue.main.drain(); app.audio.queue.drain()
    check(app.audio.events.last == "watchAll:off" && app.discovery == nil, "9l closing the window ends the watching")
}
do { // (9) from the menu, once set up: an app Sigá has no record of
    let app = launch(setupComplete: true)
    let root = "/Applications/Murmur.app/"; bundleIDs = [root: "app.murmur"]
    NSWorkspace.shared.installed = ["app.murmur"]; NSWorkspace.shared.locations = ["app.murmur": "/Applications/Murmur.app"]
    app.useAnotherApp(); app.audio.queue.drain()
    check(app.welcome?.presented == 1 && app.welcome?.firstRun == false, "9m Use another app… in the menu opens the window with the sheet")
    app.audio.report!([]); app.audio.report!([root + "Contents/MacOS/Murmur"]); app.audio.report!([])
    let found = app.welcome?.snapshots.last?.anotherApp
    check(found?.headline == "Found Murmur." && found?.note == anyAppNote + sigaHandlesIt && found?.canAdd == true, "9n an app without a record is named from its bundle and keeps the general note")
    NSRunningApplication.running = [NSRunningApplication(bundleIdentifier: "app.murmur", pid: 5, at: "/Applications/Murmur.app")]
    app.setupAction(.addApp); app.audio.queue.drain()
    check(savedApps() == [willow, "app.murmur"] && app.audio.events.suffix(2) == ["roots:\(root)", "watchAll:off"], "9o Add saves it and watches it at once")
    check(appsMenu(app).map(\.title) == ["Murmur", "", "Use another app…"], "9p it joins the Dictation apps menu")
}
do { // the done page only says it worked after it did
    let app = launch(setupComplete: false) { NSWorkspace.shared.installed = [superwhisper] }
    let welcome = app.welcome!
    app.setupAction(.choose(superwhisper, true)); finish(app)
    func line() -> String { welcome.snapshots.last.map { $0.session.line($0.apps) } ?? "" }
    check(line() == "Try it now. Play something, then dictate.", "M1 after Start the page invites a try and claims nothing")
    app.audio.display(AudioStatus(title: "Ready", detail: nil, lowered: false, enabled: true, restorable: false))
    check(line() == "Try it now. Play something, then dictate.", "M2 Ready is not success")
    app.audio.display(AudioStatus(title: "Volume was already off, so Sigá left it alone", detail: nil, lowered: false, enabled: true, restorable: false, skipped: true))
    check(line().hasPrefix("Your volume was already off, so Sigá left it alone. In superwhisper, set Playback when recording to Keep Playing.") && !line().contains("That’s it"),
          "M3 a dictation Sigá left alone says so, with what to switch off, and is not called success")
    app.audio.display(AudioStatus(title: "Volume lowered · 30%", detail: nil, lowered: true, enabled: true, restorable: true))
    check(line() == "That’s it. Sigá lowered the volume.", "M4 a real lowering is success")
    app.audio.display(AudioStatus(title: "Ready", detail: nil, lowered: false, enabled: true, restorable: false, skipped: true))
    check(line() == "That’s it. Sigá lowered the volume.", "M5 and stays so")
}

check(knownApps.filter(\.tile).map(\.id) == [willow, superwhisper]
      && knownApps.first { $0.id == willow }?.note == "In Willow, turn off Mute Audio While Dictating. Sigá also lowers the volume during Willow Scribe.",
      "R7 only completed tile records are offered with observed Willow audio guidance")

check(knownApps.first { $0.id == superwhisper }?.note == "In superwhisper, set Playback when recording to Keep Playing. Sigá also lowers the volume during superwhisper meetings.",
      "R3/R6 superwhisper guidance names the observed playback control and meeting scope")

do { // Compile the actual native tiles separately from this harness's AppKit doubles.
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Setup.swift"), encoding: .utf8)
        + "\n" + String(contentsOf: root.appendingPathComponent("Welcome.swift"), encoding: .utf8)
        + """

        private let custom = AppTile(nil)
        var record = DictationApp(id: "test.dictation", name: "Test Dictation")
        record.chosen = true
        private let selected = AppTile(record)
        exit(custom.accessibilityLabel() == "Use another app…"
             && selected.accessibilityLabel() == "Test Dictation"
             && selected.state == .on ? 0 : 1)
        """
    let script = root.appendingPathComponent("tests/.build/tile-accessibility.swift")
    try source.write(to: script, atomically: true, encoding: .utf8)
    let native = Process()
    native.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    native.arguments = ["swift", "-module-cache-path", "/private/tmp/siga-swift-cache", script.path]
    try native.run(); native.waitUntilExit()
    check(native.terminationStatus == 0, "R2 native tiles expose their visible names and retain selection state")
}

do {
    let app = launch(setupComplete: true, apps: [superwhisper])
    app.audio.queue.drain()
    var roots: [[String]] = []
    // The observed workspace list is current even when the separate bundle-id lookup is stale.
    for instances in [[running(superwhisper, 11)], [], [running(superwhisper, 12)],
                      [running(superwhisper, 12), running("com.apple.Music", 13)]] {
        NSWorkspace.shared.runningApplications = instances
        app.audio.queue.drain(); roots.append(app.audio.roots)
    }
    let root = "/Applications/\(superwhisper).app/"
    check(roots == [[root], [], [root], [root]],
          "R4 chosen background app launch, quit, and relaunch use the current workspace list without launch notifications")
}

do { // Exercise the actual bootstrap without creating an app or touching audio.
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
    let main = try String(contentsOf: root.appendingPathComponent("main.swift"), encoding: .utf8)
    let bootstrap = String(main[main.range(of: "let app = NSApplication.shared")!.lowerBound...])
    let fixture = """
        import Foundation
        import Darwin
        enum EngineLock { case acquired, heldByAnother, unavailable }
        func takeEngineLock() -> EngineLock { CommandLine.arguments.last == "held" ? .heldByAnother : .unavailable }
        var alertReady = false
        var delegateCreated = false
        class App { init() { delegateCreated = true } }
        class NSApplication {
            static let shared = NSApplication()
            enum Policy { case accessory }
            var finished = false
            var delegate: App?
            func setActivationPolicy(_ policy: Policy) {}
            func finishLaunching() { finished = true }
            func activate(ignoringOtherApps: Bool) {}
            func run() { Darwin.exit(3) }
        }
        class NSAlert {
            var messageText = ""
            func runModal() {
                let expected = CommandLine.arguments.last == "held" ? "Sigá is already running." : "Sigá couldn’t start."
                alertReady = NSApplication.shared.finished && !delegateCreated && messageText == expected
            }
        }
        func exit(_ code: Int32) -> Never { Darwin.exit(alertReady && code == 0 ? 0 : 1) }
        """ + "\n" + bootstrap
    let source = root.appendingPathComponent("tests/.build/lock-bootstrap.swift")
    let binary = root.appendingPathComponent("tests/.build/lock-bootstrap")
    try fixture.write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["swiftc", "-module-cache-path", "/private/tmp/siga-swift-cache", source.path, "-o", binary.path]
    try compiler.run(); compiler.waitUntilExit()
    var statuses: [Int32] = []
    if compiler.terminationStatus == 0 {
        for state in ["held", "unavailable"] {
            let process = Process(); process.executableURL = binary; process.arguments = [state]
            try process.run(); process.waitUntilExit(); statuses.append(process.terminationStatus)
        }
    }
    check(statuses == [0, 0], "R5 both lock failures finish app launch before a usable alert and never create the audio delegate")
}

// ───────────────────────────── summary ─────────────────────────────
print("SUMMARY passed=\(passed) failed=\(failed)")
if !failures.isEmpty { print("FAILED:"); failures.forEach { print("  - \($0)") } }
exit(failed == 0 ? 0 : 1)
