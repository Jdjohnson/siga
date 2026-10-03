// Inspect the real AppKit controls without presenting a window or accessing audio.
// VoiceOver and keyboard interaction still need a separate live check.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
var assertions = 0
func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
    assertions += 1
    if !condition() { print("FAIL: \(reason)"); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
for firstRun in [false, true] {
    for muffle in [false, true] {
        for percent in [0, 30, 100] {
            let welcome = Welcome(percent: percent, firstRun: firstRun, initialStep: .volume,
                onRefresh: {}, onAction: { _ in }, onVolume: { _ in }, onFinish: { _ in }, onClose: {})
            var value = SetupSnapshot(apps: []); value.muffle = muffle; welcome.update(value)
            let views = descendants(welcome.window!.contentView!)
            let slider = views.compactMap { $0 as? NSSlider }.first!
            // AppKit exposes the cell, while its control view is ignored by accessibility clients.
            expect(slider.cell?.accessibilityRole() == .slider, "native slider role")
            expect(slider.cell?.accessibilityLabel() == "Volume while dictating", "slider name reaches its cell")
            expect((slider.cell?.accessibilityValue() as? NSNumber)?.intValue == percent, "slider value stays numeric")
            expect(slider.cell?.accessibilityValueDescription() == "\(percent) percent of your usual volume", "spoken percentage")
            expect(slider.minValue == 0 && slider.maxValue == 100, "slider bounds")
            let effects = views.compactMap { $0 as? NSPopUpButton }
            expect(effects.count == (firstRun ? 0 : 1), "effect choice only appears in Settings")
            if let effect = effects.first {
                expect(effect.cell?.accessibilityRole() == .popUpButton, "native popup role")
                expect(effect.cell?.accessibilityLabel() == "Audio effect while dictating", "effect name reaches its cell")
                expect(effect.cell?.accessibilityValue() as? String == (muffle ? "Muffle" : "Lower volume"), "selected effect is accessible")
                expect(effect.itemTitles == ["Lower volume", "Muffle"], "both effects are available")
            }
            welcome.close()
        }
    }
}
print("SUMMARY: \(assertions) native control accessibility assertions passed")
