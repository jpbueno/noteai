import AppKit

/// Notion-style floating overlay that appears when hovering over an image in the editor.
/// Uses NSPanel with .nonactivatingPanel so it never steals focus.
/// Shows: download button, alignment cycle (left/center/right), and decorative resize handles.
final class ImageOverlayPanel: NSPanel {
    private var actionBar: NSView!
    private var leftHandle: NSView!
    private var rightHandle: NSView!
    private var widthLabel: NSTextField!
    private(set) var currentFilename: String?
    private(set) var currentRange: NSRange?
    private weak var editor: NSTextView?

    var onAlignmentChange: ((NSTextAlignment) -> Void)?
    var onDownload: ((String) -> Void)?

    private var currentAlignment: NSTextAlignment = .left

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(editor: NSTextView) {
        self.editor = editor
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false

        setupViews()
    }

    private func setupViews() {
        let container = NSView()
        container.wantsLayer = true
        contentView = container

        actionBar = makeActionBar()
        container.addSubview(actionBar)

        leftHandle = makeHandle()
        rightHandle = makeHandle()
        container.addSubview(leftHandle)
        container.addSubview(rightHandle)

        widthLabel = NSTextField(labelWithString: "")
        widthLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        widthLabel.textColor = .white
        widthLabel.backgroundColor = NSColor(white: 0.1, alpha: 0.85)
        widthLabel.isBezeled = false
        widthLabel.alignment = .center
        widthLabel.wantsLayer = true
        widthLabel.layer?.cornerRadius = 4
        widthLabel.isHidden = true
        container.addSubview(widthLabel)
    }

    private func makeActionBar() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        bar.layer?.cornerRadius = 6

        let download = makeBtn(icon: "arrow.down.circle", tooltip: "Save image") { [weak self] in
            guard let fn = self?.currentFilename else { return }
            self?.onDownload?(fn)
        }
        download.frame = NSRect(x: 4, y: 2, width: 24, height: 24)

        let alignLeft = makeBtn(icon: "text.alignleft", tooltip: "Align left") { [weak self] in
            self?.setAlignment(.left)
        }
        alignLeft.frame = NSRect(x: 30, y: 2, width: 24, height: 24)

        let alignCenter = makeBtn(icon: "text.aligncenter", tooltip: "Center") { [weak self] in
            self?.setAlignment(.center)
        }
        alignCenter.frame = NSRect(x: 52, y: 2, width: 24, height: 24)

        let alignRight = makeBtn(icon: "text.alignright", tooltip: "Align right") { [weak self] in
            self?.setAlignment(.right)
        }
        alignRight.frame = NSRect(x: 74, y: 2, width: 24, height: 24)

        bar.addSubview(download)
        bar.addSubview(alignLeft)
        bar.addSubview(alignCenter)
        bar.addSubview(alignRight)
        return bar
    }

    private func makeBtn(icon: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = OverlayActionButton(handler: action)
        btn.isBordered = false
        btn.refusesFirstResponder = true
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
        btn.contentTintColor = .white
        btn.imageScaling = .scaleProportionallyDown
        btn.toolTip = tooltip
        return btn
    }

    private func makeHandle() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 36))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        v.layer?.cornerRadius = 3
        return v
    }

    func show(filename: String, range: NSRange, imageRect: NSRect) {
        currentFilename = filename
        currentRange = range

        guard let editorWindow = editor?.window else { return }

        let rectInEditor = imageRect
        let rectInWindow = editor!.convert(rectInEditor, to: nil)
        let rectOnScreen = editorWindow.convertToScreen(rectInWindow)

        let panelRect = NSRect(
            x: rectOnScreen.origin.x - 8,
            y: rectOnScreen.origin.y - 4,
            width: rectOnScreen.width + 16,
            height: rectOnScreen.height + 8
        )
        setFrame(panelRect, display: false)

        let contentW = panelRect.width
        let contentH = panelRect.height

        actionBar.frame = NSRect(x: contentW - 104, y: contentH - 36, width: 96, height: 28)
        leftHandle.frame = NSRect(x: 4, y: contentH / 2 - 18, width: 6, height: 36)
        rightHandle.frame = NSRect(x: contentW - 10, y: contentH / 2 - 18, width: 6, height: 36)

        if !isVisible { orderFront(nil) }
    }

    func showWidthDuringDrag(width: CGFloat, imageRect: NSRect) {
        guard let editorWindow = editor?.window, let editor = editor else { return }
        let rectInWindow = editor.convert(imageRect, to: nil)
        let rectOnScreen = editorWindow.convertToScreen(rectInWindow)

        widthLabel.stringValue = "\(Int(width))px"
        widthLabel.sizeToFit()
        let labelW = max(50, widthLabel.frame.width + 16)
        widthLabel.frame = NSRect(
            x: frame.width / 2 - labelW / 2,
            y: frame.height / 2 - 10,
            width: labelW, height: 20
        )
        widthLabel.isHidden = false

        let panelRect = NSRect(
            x: rectOnScreen.origin.x - 8,
            y: rectOnScreen.origin.y - 4,
            width: rectOnScreen.width + 16,
            height: rectOnScreen.height + 8
        )
        setFrame(panelRect, display: true)
    }

    func hideWidthLabel() {
        widthLabel.isHidden = true
    }

    func hide() {
        if isVisible { orderOut(nil) }
        currentFilename = nil
        currentRange = nil
    }

    private func setAlignment(_ alignment: NSTextAlignment) {
        currentAlignment = alignment
        onAlignmentChange?(alignment)
    }
}

private class OverlayActionButton: NSButton {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
