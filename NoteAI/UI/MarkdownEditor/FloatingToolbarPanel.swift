import AppKit

/// A non-activating floating panel that shows formatting options near the text selection.
/// Uses NSPanel with .nonactivatingPanel so it NEVER steals first-responder from the editor.
final class FloatingToolbarPanel: NSPanel {
    private weak var targetTextView: NSTextView?
    private var buttons: [ToolbarButton] = []
    private var imageButtons: [ToolbarButton] = []
    private let stack = NSStackView()
    private let imageStack = NSStackView()
    private let divider = NSBox()

    struct ToolbarButton {
        let label: String
        let view: NSButton
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 32),
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
        hasShadow = true

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)

        divider.boxType = .separator

        imageStack.orientation = .horizontal
        imageStack.spacing = 2
        imageStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 8)

        let outerStack = NSStackView(views: [stack, divider, imageStack])
        outerStack.orientation = .horizontal
        outerStack.spacing = 4

        container.addSubview(outerStack)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: container.topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        contentView = container

        let formatItems: [(String, MarkdownTransformStyle)] = [
            ("B", .bold), ("I", .italic), ("U", .underline),
            ("S", .strikethrough), ("</>", .inlineCode),
            ("H1", .heading(1)), ("H2", .heading(2)),
            ("•", .bullet), ("1.", .numbered), (">", .blockquote), ("☐", .checkbox),
            ("{ }", .codeBlock),
        ]

        for (label, style) in formatItems {
            let btn = makeButton(label) { [weak self] in
                self?.applyToggle(style)
            }
            buttons.append(ToolbarButton(label: label, view: btn))
            stack.addArrangedSubview(btn)
        }

        let shrinkBtn = makeButton("−") { [weak self] in
            self?.resizeImage(factor: 0.85)
        }
        let growBtn = makeButton("+") { [weak self] in
            self?.resizeImage(factor: 1.18)
        }
        imageButtons = [
            ToolbarButton(label: "−", view: shrinkBtn),
            ToolbarButton(label: "+", view: growBtn),
        ]
        imageStack.addArrangedSubview(shrinkBtn)
        imageStack.addArrangedSubview(growBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(to textView: NSTextView) {
        targetTextView = textView
    }

    func updatePosition() {
        guard let textView = targetTextView else { hide(); return }
        let selection = textView.selectedRange()

        let nearImage = isNearImage(in: textView)
        let hasTextSelection = selection.length > 0

        guard hasTextSelection || nearImage else { hide(); return }

        stack.isHidden = !hasTextSelection
        divider.isHidden = !hasTextSelection || !nearImage
        imageStack.isHidden = !nearImage

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { hide(); return }

        let rangeForPosition = hasTextSelection ? selection : NSRange(location: selection.location, length: 1)
        let safeRange = NSRange(
            location: min(rangeForPosition.location, max(0, (textView.string as NSString).length - 1)),
            length: min(rangeForPosition.length, (textView.string as NSString).length - min(rangeForPosition.location, (textView.string as NSString).length))
        )
        guard safeRange.location < (textView.string as NSString).length else { hide(); return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        let textOrigin = textView.textContainerOrigin
        let rectInTextView = NSRect(
            x: rect.origin.x + textOrigin.x,
            y: rect.origin.y + textOrigin.y,
            width: rect.width,
            height: rect.height
        )

        guard let window = textView.window else { hide(); return }
        let rectInWindow = textView.convert(rectInTextView, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        setContentSize(contentView!.fittingSize)
        let panelWidth = frame.width
        let x = max(rectOnScreen.minX, rectOnScreen.midX - panelWidth / 2)
        let y = rectOnScreen.maxY + 6

        setFrameOrigin(NSPoint(x: x, y: y))

        if !isVisible {
            orderFront(nil)
        }
    }

    private func isNearImage(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let loc = textView.selectedRange().location
        for offset in [0, -1, 1] {
            let pos = loc + offset
            guard pos >= 0, pos < storage.length else { continue }
            if storage.attribute(.attachment, at: pos, effectiveRange: nil) != nil {
                return true
            }
        }
        return false
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }

    private func makeButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let btn = ActionButton(title: title, action: action)
        btn.isBordered = false
        btn.refusesFirstResponder = true
        btn.font = NSFont.systemFont(ofSize: 12, weight: title.count <= 2 ? .semibold : .regular)
        btn.contentTintColor = .white
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return btn
    }

    private func applyToggle(_ style: MarkdownTransformStyle) {
        guard let textView = targetTextView else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }

        let nsText = textView.string as NSString
        let selectedText = nsText.substring(with: selection)

        if let unwrapped = style.unwrap(from: selectedText) {
            textView.insertText(unwrapped, replacementRange: selection)
        } else {
            let wrapped = style.apply(to: selectedText)
            textView.insertText(wrapped, replacementRange: selection)
        }
    }

    private func resizeImage(factor: CGFloat) {
        guard let coordinator = RichMarkdownEditor.Coordinator.activeCoordinator else { return }
        coordinator.resizeImageInMarkdown(factor: factor)
    }
}

private class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
