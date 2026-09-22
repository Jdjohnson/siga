import AppKit

// Keep the usual composition on roomy displays. On smaller displays the header,
// level, and spacing tighten so each page fits; shorter still, the page scrolls
// and navigation stays within reach.
private struct WelcomeLayout {
    let size: NSSize
    init(available: NSSize) {
        size = NSSize(width: min(600, max(1, available.width)), height: min(680, max(1, available.height)))
    }
    var compact: Bool { size.height < 680 }
    var margin: CGFloat { min(48, max(20, size.width * 0.08)) }
    var pageWidth: CGFloat { max(1, size.width - margin * 2) }
    // Compact pages fit from 488 points; extra room grows the header and the pages together.
    var slack: CGFloat { compact ? max(0, size.height - 488) : 0 }
    var logoTop: CGFloat { compact ? 36 + min(28, (slack / 4).rounded()) : 64 }
    var logoHeight: CGFloat { y(58, 48) }
    var logoWidth: CGFloat { (logoHeight * 520 / 278).rounded() }  // Wordmark.png is 520 × 278.
    var pageTop: CGFloat { y(200, 104) }
    var footerBottom: CGFloat { 64 }
    var pageBottom: CGFloat { footerBottom + BrandButton.height + (compact ? 16 : 20) }
    func pageHeight(for step: SetupStep, firstRun: Bool) -> CGFloat {
        switch step {
        case .volume: return firstRun ? y(340, 278) : y(272, 210)
        case .attention: return y(260, 224)
        default: return y(260, 220)
        }
    }
    // Small and regular values blend across the compact range, so nothing jumps at 680 points.
    var ease: CGFloat { compact ? min(1, slack / 192) : 1 }
    func y(_ regular: CGFloat, _ small: CGFloat) -> CGFloat { small + ((regular - small) * ease).rounded() }
}

private final class WelcomeWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let view = responder as? NSView, view.enclosingScrollView != nil {
            view.scrollToVisible(view.bounds.insetBy(dx: -8, dy: -12))
        }
        return accepted
    }
}

private final class PaperView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Welcome.paper.setFill(); dirtyRect.fill() }
}

private final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}

private final class WavesView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Welcome.teal.setStroke()
        // Canonical brand/assets/mark-teal.svg paths, also used by the menu icon.
        let transform = AffineTransform(translationByX: 0, byY: bounds.height)
        var scale = transform
        scale.scale(x: bounds.width / 300, y: -bounds.height / 220)
        scale.translate(x: -100, y: -155)
        for points: [CGFloat] in [[119,201,210,150,263,267,381,205],
                                 [140,261,207,228,253,310,343,275],
                                 [159,318,213,292,237,354,303,337]] {
            let path = NSBezierPath(); path.lineWidth = 26; path.lineCapStyle = .round
            path.move(to: NSPoint(x: points[0], y: points[1]))
            path.curve(to: NSPoint(x: points[6], y: points[7]),
                       controlPoint1: NSPoint(x: points[2], y: points[3]),
                       controlPoint2: NSPoint(x: points[4], y: points[5]))
            path.transform(using: scale); path.lineWidth = 26 * bounds.width / 300
            path.stroke()
        }
    }
}

private final class QuietPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0.992, blue: 0.973, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
    }
}

// Keep native slider tracking, keyboard control and accessibility; only thicken its track.
private final class QuietSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 5, width: rect.width, height: 10)
        NSColor(srgbRed: 0.88, green: 0.91, blue: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let fraction = CGFloat((doubleValue - minValue) / max(1, maxValue - minValue))
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        Welcome.blue.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5).fill()
    }
}

// Buttons match the website: Teal fill, Paper text, a 9-point corner, and semibold type.
private final class BrandButton: NSButton {
    static let height: CGFloat = 52
    private static let pressed = NSColor(srgbRed: 8/255, green: 60/255, blue: 63/255, alpha: 1)
    private var styling = false
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryPushIn); self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var title: String { didSet { if !styling { restyle() } } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    private func restyle() {
        styling = true
        attributedTitle = NSAttributedString(string: title, attributes:
            [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: Welcome.paper])
        styling = false
    }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 48, height: Self.height) }
    override func draw(_ dirtyRect: NSRect) {
        (!isEnabled ? Welcome.body : isHighlighted ? Self.pressed : Welcome.teal).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        // The native cell replaces our text color when disabled. Draw the label in Paper ourselves.
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

// One choice on the choose screen: the app’s own icon over its name, outlined in Teal when chosen.
// Without an app it is Use another app…, a plain button.
private final class AppTile: NSButton {
    static let height: CGFloat = 92
    let id: String?
    init(_ app: DictationApp?) {
        id = app?.id
        super.init(frame: .zero)
        isBordered = false; setButtonType(app == nil ? .momentaryPushIn : .pushOnPushOff)
        title = app?.name ?? "Use another app…"; toolTip = app?.name
        setAccessibilityLabel(title)
        image = app?.path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .medium).applying(.init(paletteColors: [Welcome.teal])))
        state = app?.chosen == true ? .on : .off
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 1, green: 0.992, blue: 0.973, alpha: isHighlighted ? 0.6 : 1).setFill(); panel.fill()
        if id != nil, state == .on { Welcome.teal.setStroke(); panel.lineWidth = 2; panel.stroke() }
        if let image {
            let size = id == nil ? image.size : NSSize(width: 36, height: 36)
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: 32 - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                       .foregroundColor: Welcome.teal, .paragraphStyle: centered])
            .draw(with: NSRect(x: 3, y: 58, width: bounds.width - 6, height: 30), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

// The same native view is used by the app and the isolated, simulated preview.
final class Welcome: NSWindowController, NSWindowDelegate {
    static let blue = NSColor(srgbRed: 98/255, green: 159/255, blue: 200/255, alpha: 1)
    static let teal = NSColor(srgbRed: 6/255, green: 75/255, blue: 78/255, alpha: 1)
    static let paper = NSColor(srgbRed: 247/255, green: 243/255, blue: 234/255, alpha: 1)
    static let body = NSColor(srgbRed: 66/255, green: 99/255, blue: 104/255, alpha: 1)
    private var step: SetupStep
    private var finishing = false
    private let firstRun: Bool
    private var pages: [NSView] = []
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = BrandButton(title: "Continue")
    private let pageScroll = NSScrollView()
    private let pageDocument = PaperView()
    private var pageHeight: NSLayoutConstraint!
    private let layout: WelcomeLayout
    private let slider: NSSlider
    private let level = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "Open Sigá when I log in", target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let loginItems = NSButton(title: "Open Login Items", target: nil, action: nil)
    private let callout = NSTextField(wrappingLabelWithString: "")
    private let soundSettings = NSButton(title: "Open Sound settings", target: nil, action: nil)
    // Tiles and the note beneath them, laid out by hand each time the apps change.
    private let chooser = TopDownView()
    private var chooserTop: CGFloat = 0, chooseHeight: CGFloat = 0
    private var apps: [DictationApp] = [], canContinue = false
    private var tiles: [AppTile] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    private let sessionLine = NSTextField(wrappingLabelWithString: "")
    private let sessionTop: CGFloat = 156
    private var anotherApp: AnotherAppSheet?
    private(set) var sheet: NSWindow?
    private let onRefresh: () -> Void
    private let onAction: (SetupAction) -> Void
    private let onVolume: (Int) -> Void
    private let onFinish: (Int) -> Void
    private let onClose: () -> Void

    init(percent: Int, firstRun: Bool, initialStep: SetupStep? = nil,
         onRefresh: @escaping () -> Void, onAction: @escaping (SetupAction) -> Void,
         onVolume: @escaping (Int) -> Void, onFinish: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.firstRun = firstRun; step = initialStep ?? (firstRun ? .choose : .volume)
        self.onRefresh = onRefresh; self.onAction = onAction; self.onVolume = onVolume
        self.onFinish = onFinish; self.onClose = onClose
        slider = NSSlider(value: Double(min(100, max(0, percent))), minValue: 0, maxValue: 100, target: nil, action: nil)
        let sliderCell = QuietSliderCell()
        sliderCell.minValue = 0; sliderCell.maxValue = 100
        sliderCell.doubleValue = Double(min(100, max(0, percent)))
        slider.cell = sliderCell
        let style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 800)
        let available = NSWindow.contentRect(forFrameRect: visible.insetBy(dx: 16, dy: 12), styleMask: style).size
        #if SIGA_PREVIEW
        let previewHeight = ProcessInfo.processInfo.environment["SIGA_PREVIEW_HEIGHT"].flatMap(Double.init)
        layout = WelcomeLayout(available: NSSize(width: available.width, height: previewHeight.map { CGFloat($0) } ?? available.height))
        #else
        layout = WelcomeLayout(available: available)
        #endif
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: layout.size),
                              styleMask: style, backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Sigá"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.paper; window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = PaperView(frame: NSRect(origin: .zero, size: layout.size))
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        let root = window.contentView!
        if let url = Bundle.main.url(forResource: "Wordmark", withExtension: "png"), let image = NSImage(contentsOf: url) {
            let mark = NSImageView(image: image); mark.imageScaling = .scaleProportionallyUpOrDown
            mark.setAccessibilityLabel("Sigá")
            place(mark, in: root, x: layout.margin, top: layout.logoTop, width: layout.logoWidth, height: layout.logoHeight)
        }
        let symbol = WavesView()
        symbol.setAccessibilityLabel("Sigá, three waves")
        place(symbol, in: root, x: layout.size.width - layout.margin - 44,
              top: layout.logoTop + 8, width: 44, height: 44 * 220 / 300)
        callout.font = .systemFont(ofSize: 12); callout.textColor = Self.body
        callout.alignment = .left
        root.addSubview(callout); callout.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.drawsBackground = false; pageScroll.borderType = .noBorder
        pageScroll.hasVerticalScroller = true; pageScroll.hasHorizontalScroller = false
        pageScroll.autohidesScrollers = true; pageScroll.scrollerStyle = .overlay
        pageScroll.setAccessibilityLabel(firstRun ? "Sigá setup" : "Sigá settings")
        pageScroll.documentView = pageDocument
        pageDocument.translatesAutoresizingMaskIntoConstraints = false
        pageHeight = pageDocument.heightAnchor.constraint(equalToConstant: 0)
        root.addSubview(pageScroll); pageScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: layout.margin),
            pageScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -layout.margin),
            pageScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: layout.pageTop),
            pageScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -layout.pageBottom),
            pageDocument.leadingAnchor.constraint(equalTo: pageScroll.contentView.leadingAnchor),
            pageDocument.topAnchor.constraint(equalTo: pageScroll.contentView.topAnchor),
            pageDocument.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor),
            pageHeight
        ])
        for _ in SetupStep.allCases {
            let page = NSView()
            fill(page, in: pageDocument)
            pages.append(page)
        }
        buildChoose(); buildVolume(); buildAttention(); buildComplete()
        back.isBordered = false; back.alignment = .left; back.target = self; back.action = #selector(goBack)
        back.attributedTitle = NSAttributedString(string: back.title, attributes:
            [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: Self.teal])
        next.target = self; next.action = #selector(advance); next.keyEquivalent = "\r"
        // Named as the default button so assistive technology can find the page's primary action.
        window.defaultButtonCell = next.cell as? NSButtonCell
        for view in [back, next] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            next.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -layout.margin),
            next.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -layout.footerBottom),
            next.widthAnchor.constraint(equalToConstant: 140), next.heightAnchor.constraint(equalToConstant: BrandButton.height),
            back.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -16),
            back.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 52), back.heightAnchor.constraint(equalToConstant: 40),
            callout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: layout.margin),
            callout.trailingAnchor.constraint(equalTo: back.leadingAnchor, constant: -20),
            callout.centerYAnchor.constraint(equalTo: next.centerYAnchor)
        ])
        updateLevel(); update(SetupSnapshot()); showStep(); window.center()
        // NSWindow's optical centering can extend beyond a short visible frame.
        window.setFrameOrigin(NSPoint(x: max(visible.minX, min(window.frame.minX, visible.maxX - window.frame.width)),
                                      y: max(visible.minY, min(window.frame.minY, visible.maxY - window.frame.height))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func place(_ view: NSView, in parent: NSView, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
        parent.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: x),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)
        ])
    }
    // Fills its parent below `top`, so its height follows the page’s.
    private func fill(_ view: NSView, in parent: NSView, top: CGFloat = 0) {
        parent.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: top), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
    // Measured, so whatever follows sits below the text however it wraps.
    private func fitted(_ field: NSTextField, _ width: CGFloat) -> CGFloat {
        field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 2000)).height.rounded(.up)
    }
    // A left-aligned line of views; hidden views take no room.
    private func row(_ views: [NSView], in parent: NSView, x: CGFloat, top: CGFloat, height: CGFloat) {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        parent.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: x),
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            stack.heightAnchor.constraint(equalToConstant: height),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)
        ])
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false, tracking: CGFloat = 0) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = muted ? Self.body : Self.teal
        if tracking != 0 { field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: field.font!, .foregroundColor: field.textColor!, .kern: tracking]) }
        return field
    }
    private func link(_ button: NSButton, _ action: Selector) {
        button.isBordered = false; button.target = self; button.action = action
        button.attributedTitle = NSAttributedString(string: button.title, attributes:
            [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Self.teal,
             .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
    private func heading(_ text: String, in page: NSView) {
        place(label(text, size: 36, weight: .semibold, tracking: -2), in: page, x: 0, top: 0, width: layout.pageWidth, height: 50)
        page.setAccessibilityLabel(text)
    }
    private func buildChoose() {
        let page = pages[SetupStep.choose.rawValue], title = "Keep your music on while you dictate."
        page.setAccessibilityLabel(title)
        var top: CGFloat = 0
        for (field, gap) in [(label(title, size: layout.y(32, 26), weight: .semibold, tracking: -1.5), layout.y(12, 8)),
                             (label("Sigá lowers your Mac’s volume while you speak, then gently brings it back.",
                                    size: layout.y(17, 15), muted: true), layout.y(24, 14)),
                             (label("Choose your dictation app.", size: 14, weight: .semibold), 10)] {
            let height = fitted(field, layout.pageWidth)
            place(field, in: page, x: 0, top: top, width: layout.pageWidth, height: height)
            top += height + gap
        }
        chooserTop = top
        fill(chooser, in: page, top: top)
        note.font = .systemFont(ofSize: 13); note.textColor = Self.body
        layoutChooser()
    }
    private func layoutChooser() {
        if tiles.compactMap(\.id) != apps.map(\.id) || tiles.isEmpty {
            chooser.subviews.forEach { $0.removeFromSuperview() }
            tiles = apps.map(AppTile.init) + [AppTile(nil)]
            let gap: CGFloat = 12, width = ((layout.pageWidth - gap * 3) / 4).rounded(.down)
            for (index, tile) in tiles.enumerated() {
                tile.target = self; tile.action = #selector(tileChanged)
                tile.frame = NSRect(x: CGFloat(index % 4) * (width + gap), y: CGFloat(index / 4) * (AppTile.height + gap),
                                    width: width, height: AppTile.height)
                chooser.addSubview(tile)
            }
            chooser.addSubview(note)
        }
        for (tile, app) in zip(tiles, apps) { tile.state = app.chosen ? .on : .off }
        let bottom = CGFloat((tiles.count + 3) / 4) * (AppTile.height + 12)
        note.stringValue = chosenNotes(apps)
        note.frame = NSRect(x: -2, y: bottom, width: layout.pageWidth, height: fitted(note, layout.pageWidth))
        chooseHeight = chooserTop + (note.stringValue.isEmpty ? bottom - 12 : note.frame.maxY)
    }
    @objc private func tileChanged(_ tile: AppTile) {
        onAction(tile.id.map { .choose($0, tile.state == .on) } ?? .useAnotherApp)
    }
    // Use another app…: one sheet that follows the search. Add works only once an app was heard to start and stop.
    private func showSheet(_ value: AnotherAppSheet?) {
        guard value != anotherApp else { return }
        anotherApp = value
        guard let value else {
            if let sheet { window?.endSheet(sheet) }
            sheet = nil; return
        }
        let content = PaperView(), width: CGFloat = 404
        var top: CGFloat = 28
        for (text, field) in [(value.headline, label(value.headline, size: 20, weight: .semibold, tracking: -0.5)),
                              (value.note, label(value.note, size: 14)),
                              (value.warning ?? "", label(value.warning ?? "", size: 13, muted: true)),
                              (AnotherAppSheet.footnote, label(AnotherAppSheet.footnote, size: 12, muted: true))] where !text.isEmpty {
            let height = fitted(field, width)
            place(field, in: content, x: 28, top: top, width: width, height: height)
            top += height + 12
        }
        let cancel = NSButton(title: "Cancel", target: nil, action: nil), again = NSButton(title: "Try again", target: nil, action: nil)
        let add = BrandButton(title: "Add")
        link(cancel, #selector(cancelAnotherApp)); cancel.keyEquivalent = "\u{1b}"
        link(again, #selector(tryAgain))
        add.target = self; add.action = #selector(addApp); add.isEnabled = value.canAdd; add.keyEquivalent = "\r"
        row([cancel, again], in: content, x: 26, top: top + 22, height: 24)
        place(add, in: content, x: 28 + width - 110, top: top + 12, width: 110, height: 44)
        let panel = sheet ?? NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width + 56, height: top + 12 + 44 + 24)).size
        // A sheet hangs from its top edge, so growing for the found app's lines keeps that edge still.
        panel.contentView = content
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height),
                       display: true, animate: panel.isVisible)
        if sheet == nil { sheet = panel; window?.beginSheet(panel) }
    }
    @objc private func cancelAnotherApp() { onAction(.cancelAnotherApp) }
    @objc private func tryAgain() { onAction(.tryAgain) }
    @objc private func addApp() { onAction(.addApp) }
    private func buildVolume() {
        let page = pages[SetupStep.volume.rawValue]
        page.setAccessibilityLabel("Find your quiet.")
        let panel = QuietPanel()
        let panelHeight = layout.y(272, 210)
        place(panel, in: page, x: 0, top: 0, width: layout.pageWidth, height: panelHeight)
        let inset: CGFloat = 32, width = layout.pageWidth - 64
        let title = label("Find your quiet.", size: layout.y(30, 26), weight: .semibold, tracking: -1)
        title.alignment = .center
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        title.attributedStringValue = NSAttributedString(string: "Find your quiet.", attributes:
            [.font: title.font!, .foregroundColor: Self.teal, .kern: -1, .paragraphStyle: centered])
        place(title, in: panel, x: inset, top: layout.y(22, 14), width: width, height: 40)
        let caption = label("Choose your volume while you dictate.", size: 14, muted: true)
        caption.alignment = .center
        place(caption, in: panel, x: inset, top: layout.y(68, 54), width: width, height: 24)
        level.font = .monospacedDigitSystemFont(ofSize: layout.y(72, 56), weight: .bold)
        level.textColor = Self.blue; level.alignment = .center
        place(level, in: panel, x: inset, top: layout.y(108, 82), width: width, height: layout.y(90, 68))
        slider.target = self; slider.action = #selector(volumeChanged); slider.isContinuous = true
        slider.setAccessibilityLabel("Volume while dictating")
        place(slider, in: panel, x: inset, top: layout.y(206, 148), width: width, height: 32)
        place(label("Silent", size: 12, muted: true), in: panel, x: inset, top: layout.y(242, 180), width: 100, height: 18)
        let end = label("Unchanged", size: 12, muted: true); end.alignment = .right
        place(end, in: panel, x: layout.pageWidth - inset - 100, top: layout.y(242, 180), width: 100, height: 18)
        guard firstRun else { return }
        login.target = self; login.action = #selector(loginChanged)
        login.attributedTitle = NSAttributedString(string: login.title, attributes:
            [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Self.teal])
        place(login, in: page, x: 20, top: panelHeight + 20, width: layout.pageWidth - 20, height: 22)
        loginNote.font = .systemFont(ofSize: 13); loginNote.textColor = Self.body
        link(loginItems, #selector(openLoginItems))
        row([loginNote, loginItems], in: page, x: 42, top: panelHeight + 46, height: 20)
    }

    private func buildAttention() {
        let page = pages[SetupStep.attention.rawValue]; heading("One thing first.", in: page)
        let body = label("Sigá needs speakers or headphones with Mac volume controls.\nChoose an output in Sound settings, then check again.", size: 17, muted: true)
        let width = min(490, layout.pageWidth), top = layout.y(66, 58)
        // Measured, so the link sits one line below the text however it wraps.
        let fitted = fitted(body, width)
        place(body, in: page, x: 0, top: top, width: width, height: fitted)
        // A link, so Check again stays the page's one primary action.
        link(soundSettings, #selector(openSoundSettings))
        // The borderless button pads its title; 2 points left puts the text on the body's edge.
        row([soundSettings], in: page, x: -2, top: top + fitted + 16, height: 24)
    }
    private func buildComplete() {
        let page = pages[SetupStep.complete.rawValue]
        heading("You’re all set.", in: page)
        place(label("Dictate just as you always do.\nSigá takes care of the volume.", size: 19, muted: true),
              in: page, x: 0, top: 72, width: layout.pageWidth, height: 68)
        // What Sigá has seen since Start, so the first real dictation is answered on the page.
        sessionLine.preferredMaxLayoutWidth = layout.pageWidth
        page.addSubview(sessionLine); sessionLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sessionLine.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            sessionLine.topAnchor.constraint(equalTo: page.topAnchor, constant: sessionTop),
            sessionLine.widthAnchor.constraint(equalToConstant: layout.pageWidth)
        ])
    }
    private func height(of step: SetupStep) -> CGFloat {
        switch step {
        case .choose: return chooseHeight
        case .complete: return max(layout.pageHeight(for: step, firstRun: firstRun), sessionTop + fitted(sessionLine, layout.pageWidth))
        default: return layout.pageHeight(for: step, firstRun: firstRun)
        }
    }
    func showComplete() {
        if !firstRun { close(); return }
        finishing = false; step = .complete; showStep()
    }
    func update(_ value: SetupSnapshot) {
        let approval = value.startup == .needsApproval
        login.state = value.startup == .on || approval ? .on : .off
        loginNote.stringValue = value.startupError ?? (approval ? "Allow Sigá in Login Items to turn this on." : "")
        loginNote.isHidden = loginNote.stringValue.isEmpty
        loginItems.isHidden = !approval || value.startupError != nil
        if value.apps != apps { apps = value.apps; layoutChooser() }
        canContinue = value.canContinue
        sessionLine.stringValue = value.session.line(apps)
        sessionLine.font = .systemFont(ofSize: 15, weight: value.session == .lowered ? .semibold : .regular)
        sessionLine.textColor = value.session == .lowered ? Self.teal : Self.body
        pageHeight.constant = height(of: step)
        showSheet(value.anotherApp)
        updateNavigation()
    }
    private func showStep() {
        for (index, page) in pages.enumerated() { page.isHidden = index != step.rawValue }
        pageHeight.constant = height(of: step)
        pageDocument.scroll(.zero)
        back.isHidden = step == .choose || step == .complete || !firstRun
        callout.stringValue = step == .choose || step == .attention
            ? "Sigá never hears you. It only controls your volume."
            : "Find Sigá in your menu bar."
        updateNavigation()
        // Keyboard focus, and its ring, only when the person has asked for it system-wide.
        if NSApp.isFullKeyboardAccessEnabled { window?.makeFirstResponder(next) }
        if step == .volume { onRefresh() }
        announceStep()
    }
    private func announceStep() {
        guard window?.isVisible == true else { return }
        let title = pages[step.rawValue].accessibilityLabel() ?? "Sigá"
        NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
            userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func updateNavigation() {
        switch step {
        case .choose: next.title = "Continue"
        case .complete: next.title = "Done"
        case .volume: next.title = finishing ? "Checking…" : (firstRun ? "Start Sigá" : "Done")
        case .attention: next.title = finishing ? "Checking…" : "Check again"
        }
        for control in [next, back, slider, login, loginItems, soundSettings] { control.isEnabled = !finishing }
        if step == .choose { next.isEnabled = canContinue }
    }
    func setFinishing(_ value: Bool) { finishing = value; updateNavigation() }
    private func updateLevel() {
        let value = Int(slider.doubleValue.rounded()); level.stringValue = "\(value)%"
        slider.setAccessibilityValue("\(value) percent of your usual volume")
    }
    @objc private func volumeChanged() {
        guard !finishing else { return }
        slider.doubleValue = slider.doubleValue.rounded(); updateLevel()
        // First-run values remain a draft until the person starts Sigá.
        if !firstRun { onVolume(slider.integerValue) }
    }
    @objc private func loginChanged() { onAction(.login(login.state == .on)) }
    @objc private func openLoginItems() { onAction(.openLoginItems) }
    @objc private func openSoundSettings() { onAction(.soundSettings) }
    @objc private func goBack() {
        guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = previous; showStep()
    }
    @objc private func advance() {
        guard next.isEnabled else { return }
        if step == .complete { close() }
        else if step == .choose { step = .volume; showStep() } else { onFinish(slider.integerValue) }
    }
    func windowDidBecomeKey(_ notification: Notification) { onRefresh() }
    func windowWillClose(_ notification: Notification) { onClose() }
    func showAttention() { step = .attention; showStep() }
    func present() {
        let wasVisible = window?.isVisible == true
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        // Announce the page when the window appears, not each time the menu brings it forward.
        if !wasVisible { announceStep() }
    }
}
