import SwiftUI
import AppKit

/// NSTextView subclass that preserves its selection when it loses first-responder status.
/// This is required because toolbar clicks (even onTapGesture) steal focus on macOS,
/// collapsing the selection before any command can read it.
class RichEditorTextView: NSTextView {
    var savedSelectedRange: NSRange = NSRange(location: 0, length: 0)

    private var isDraggingImageEdge = false
    private var dragAttachmentRange: NSRange?
    private var dragFilename: String?
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private let edgeHitZone: CGFloat = 10

    private lazy var imageOverlay: ImageOverlayPanel = {
        let panel = ImageOverlayPanel(editor: self)
        panel.onDownload = { [weak self] filename in self?.downloadImage(filename) }
        panel.onAlignmentChange = { [weak self] alignment in self?.applyAlignment(alignment) }
        return panel
    }()

    override func resignFirstResponder() -> Bool {
        savedSelectedRange = selectedRange()
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if let hit = fullImageHit(for: event) {
            imageOverlay.show(filename: hit.filename, range: hit.range, imageRect: hit.rect)
            if imageEdgeHit(for: event) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        } else if !isDraggingImageEdge {
            let mouseOnOverlay = imageOverlay.isVisible && NSPointInRect(NSEvent.mouseLocation, imageOverlay.frame)
            if !mouseOnOverlay {
                imageOverlay.hide()
            }
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDraggingImageEdge {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let mouseOnOverlay = self.imageOverlay.isVisible && NSPointInRect(NSEvent.mouseLocation, self.imageOverlay.frame)
                if !mouseOnOverlay { self.imageOverlay.hide() }
            }
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = imageEdgeHit(for: event) {
            isDraggingImageEdge = true
            dragAttachmentRange = hit.range
            dragFilename = hit.filename
            dragStartX = event.locationInWindow.x
            dragStartWidth = hit.currentWidth
            NSCursor.resizeLeftRight.push()
            imageOverlay.hide()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingImageEdge, let range = dragAttachmentRange else {
            super.mouseDragged(with: event)
            return
        }
        let deltaX = event.locationInWindow.x - dragStartX
        let newWidth = max(80, min(900, dragStartWidth + deltaX))

        guard let storage = textStorage,
              range.location < storage.length,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              let filename = dragFilename,
              let image = ImageStore.load(filename: filename) else { return }

        let scale = image.size.width > 0 ? newWidth / image.size.width : 1.0
        let displaySize = NSSize(width: newWidth, height: max(1, image.size.height * scale))
        let cell = NSTextAttachmentCell(imageCell: image)
        cell.image?.size = displaySize
        attachment.attachmentCell = cell

        let widthKey = NSAttributedString.Key("NoteAIImageWidth")
        storage.addAttribute(widthKey, value: NSNumber(value: Double(newWidth)), range: range)
        needsDisplay = true

        let imgRect = imageRectForRange(range)
        imageOverlay.show(filename: dragFilename ?? "", range: range, imageRect: imgRect)
        imageOverlay.showWidthDuringDrag(width: newWidth, imageRect: imgRect)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingImageEdge {
            isDraggingImageEdge = false
            dragAttachmentRange = nil
            dragFilename = nil
            NSCursor.pop()
            imageOverlay.hideWidthLabel()
            imageOverlay.hide()
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: self)
        } else {
            super.mouseUp(with: event)
        }
    }

    private struct ImageEdgeHit {
        let range: NSRange
        let filename: String
        let currentWidth: CGFloat
    }

    private func imageEdgeHit(for event: NSEvent) -> ImageEdgeHit? {
        guard let storage = textStorage,
              let layoutManager = layoutManager,
              let textContainer = textContainer else { return nil }

        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }

        var effectiveRange = NSRange(location: 0, length: 0)
        guard let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: &effectiveRange) as? NSTextAttachment else {
            return nil
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
        let attachRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let attachRectInView = NSRect(
            x: attachRect.origin.x + textContainerOrigin.x,
            y: attachRect.origin.y + textContainerOrigin.y,
            width: attachRect.width,
            height: attachRect.height
        )

        let rightEdge = attachRectInView.maxX
        guard abs(point.x - rightEdge) < edgeHitZone else { return nil }

        let filenameKey = NSAttributedString.Key("NoteAIImageFilename")
        let widthKey = NSAttributedString.Key("NoteAIImageWidth")
        let filename = storage.attribute(filenameKey, at: effectiveRange.location, effectiveRange: nil) as? String ?? ""
        let storedWidth = (storage.attribute(widthKey, at: effectiveRange.location, effectiveRange: nil) as? NSNumber)
            .flatMap { CGFloat($0.doubleValue) }
        let currentWidth = storedWidth ?? attachment.attachmentCell?.cellSize().width ?? 300

        guard !filename.isEmpty else { return nil }
        return ImageEdgeHit(range: effectiveRange, filename: filename, currentWidth: currentWidth)
    }

    struct FullImageHit {
        let range: NSRange
        let filename: String
        let rect: NSRect
    }

    private func fullImageHit(for event: NSEvent) -> FullImageHit? {
        guard let storage = textStorage,
              let lm = layoutManager,
              let tc = textContainer else { return nil }

        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)

        var fraction: CGFloat = 0
        let gi = lm.glyphIndex(for: textPoint, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let ci = lm.characterIndexForGlyph(at: gi)
        guard ci < storage.length else { return nil }

        var er = NSRange(location: 0, length: 0)
        guard storage.attribute(.attachment, at: ci, effectiveRange: &er) is NSTextAttachment else { return nil }

        let rect = imageRectForRange(er)
        guard NSPointInRect(point, rect.insetBy(dx: -12, dy: -8)) else { return nil }

        let fnKey = NSAttributedString.Key("NoteAIImageFilename")
        let fn = storage.attribute(fnKey, at: er.location, effectiveRange: nil) as? String ?? ""
        guard !fn.isEmpty else { return nil }
        return FullImageHit(range: er, filename: fn, rect: rect)
    }

    private func imageRectForRange(_ range: NSRange) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: gr, in: tc)
        return NSRect(x: r.origin.x + textContainerOrigin.x, y: r.origin.y + textContainerOrigin.y,
                      width: r.width, height: r.height)
    }

    private func downloadImage(_ filename: String) {
        guard let image = ImageStore.load(filename: filename),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    static let imageAlignKey = NSAttributedString.Key("NoteAIImageAlign")

    private func applyAlignment(_ alignment: NSTextAlignment) {
        guard let storage = textStorage,
              let range = imageOverlay.currentRange,
              range.location < storage.length else { return }
        let alignValue: String = switch alignment {
            case .center: "center"
            case .right: "right"
            default: "left"
        }
        storage.addAttribute(Self.imageAlignKey, value: alignValue, range: range)
        let lineRange = (storage.string as NSString).lineRange(for: range)
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineSpacing = 4
        para.paragraphSpacing = 6
        storage.addAttribute(.paragraphStyle, value: para, range: lineRange)
        needsDisplay = true
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: self)
    }
}

private enum RichMarkdownEditorTheme {
    static let background = Theme.contentBGNSColor
    static let codeBlockBackground = Theme.contentBGNSColor
}

/// Fixed toolbar with Notion-style SF Symbol icons. Uses refusesFirstResponder
/// so the NSTextView keeps focus and selection when toolbar buttons are clicked.
final class EditorFixedToolbar: NSView {
    private weak var coordinator: RichMarkdownEditor.Coordinator?

    init(coordinator: RichMarkdownEditor.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        applyTheme()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let sep = { () -> NSView in
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            v.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return v
        }

        let row1: [BtnDef] = [
            BtnDef(style: .bold, tip: "Bold", icon: "bold", label: nil),
            BtnDef(style: .italic, tip: "Italic", icon: "italic", label: nil),
            BtnDef(style: .underline, tip: "Underline", icon: "underline", label: nil),
        ]
        let row2: [BtnDef] = [
            BtnDef(style: .codeBlock, tip: "Code Block", icon: "chevron.left.forwardslash.chevron.right", label: nil),
            BtnDef(style: .heading(1), tip: "Heading 1", icon: nil, label: "H1"),
            BtnDef(style: .heading(2), tip: "Heading 2", icon: nil, label: "H2"),
        ]
        let row3: [BtnDef] = [
            BtnDef(style: .bullet, tip: "Bullet List", icon: "list.bullet", label: nil),
            BtnDef(style: .numbered, tip: "Numbered List", icon: "list.number", label: nil),
            BtnDef(style: .hyperlink, tip: "Hyperlink", icon: "link", label: nil),
        ]

        for def in row1 { stack.addArrangedSubview(makeButton(def)) }
        stack.addArrangedSubview(sep())
        for def in row2 { stack.addArrangedSubview(makeButton(def)) }
        stack.addArrangedSubview(sep())
        for def in row3 { stack.addArrangedSubview(makeButton(def)) }

        let bottomBorder = NSView()
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)
        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = RichMarkdownEditorTheme.background.cgColor
        }
    }

    private struct BtnDef {
        let style: MarkdownTransformStyle
        let tip: String
        let icon: String?
        let label: String?
    }

    private func makeButton(_ def: BtnDef) -> NSButton {
        let btn = ToolbarActionButton(handler: { [weak self] in
            self?.coordinator?.applyToggleFromToolbar(def.style)
        })
        btn.refusesFirstResponder = true
        btn.isBordered = false
        if let icon = def.icon {
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: def.tip)
            btn.imageScaling = .scaleProportionallyDown
        } else if let label = def.label {
            btn.title = label
            btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
        btn.contentTintColor = NSColor(white: 0.65, alpha: 1)
        btn.toolTip = def.tip
        btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }
}

private class ToolbarActionButton: NSButton {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A Notion-style markdown editor that renders formatting inline as you type.
/// Headings display large, bold text is bold, lists are indented — all while editing raw markdown.
/// Supports pasting images from the clipboard (Cmd+V).
struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    static func execute(command: RichMarkdownEditorCommand) {
        Coordinator.activeCoordinator?.execute(command: command)
    }

    static func selectedText() -> String? {
        Coordinator.activeCoordinator?.selectedMarkdownText()
    }

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true

        let toolbar = EditorFixedToolbar(coordinator: context.coordinator)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(toolbar)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = RichMarkdownEditorTheme.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: wrapper.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        let contentSize = NSSize(width: 400, height: 300)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = RichEditorTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.backgroundColor = RichMarkdownEditorTheme.background
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView

        ImagePasteHelper.install(on: textView, coordinator: context.coordinator)
        context.coordinator.bind(to: textView)

        context.coordinator.applyRichFormatting(to: textView)

        return wrapper
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let scrollView = nsView.subviews.compactMap({ $0 as? NSScrollView }).first,
              let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.backgroundColor = RichMarkdownEditorTheme.background
        textView.backgroundColor = RichMarkdownEditorTheme.background
        if context.coordinator.currentMarkdown(from: textView) != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            context.coordinator.applyRichFormatting(to: textView)
            let safeRange = NSRange(location: min(selectedRange.location, textView.string.count), length: 0)
            textView.setSelectedRange(safeRange)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        private static let imageFilenameKey = NSAttributedString.Key("NoteAIImageFilename")
        private static let imageWidthKey = NSAttributedString.Key("NoteAIImageWidth")
        private static weak var lastActiveTextView: NSTextView?
        static weak var activeCoordinator: Coordinator?

        var parent: RichMarkdownEditor
        private weak var boundTextView: NSTextView?
        private var commandObserver: NSObjectProtocol?
        private var mouseDownMonitor: Any?
        private var savedSelection: NSRange = NSRange(location: 0, length: 0)

        init(_ parent: RichMarkdownEditor) {
            self.parent = parent
        }

        deinit {
            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
            }
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingFormatting else { return }
            guard let textView = notification.object as? NSTextView else { return }
            Self.lastActiveTextView = textView
            Self.activeCoordinator = self
            parent.text = currentMarkdown(from: textView)
            parent.onChange()
            applyRichFormatting(to: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            Self.lastActiveTextView = textView
            Self.activeCoordinator = self
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            savedSelection = textView.selectedRange()
            Self.lastActiveTextView = textView
            Self.activeCoordinator = self
        }

        /// Called by ImagePasteHelper when an image paste is detected.
        func insertImage(_ image: NSImage, into textView: NSTextView) {
            guard let markdownRef = ImageStore.save(image) else { return }
            let insertion = "\n\(markdownRef)\n"
            let range = textView.selectedRange()
            textView.insertText(insertion, replacementRange: range)
        }

        func bind(to textView: NSTextView) {
            boundTextView = textView

            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak textView] event in
                guard let self, let textView else { return event }
                if textView.window?.firstResponder === textView {
                    self.savedSelection = textView.selectedRange()
                }
                return event
            }

            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
            }
            commandObserver = NotificationCenter.default.addObserver(
                forName: .richMarkdownEditorCommand,
                object: nil,
                queue: .main
            ) { [weak self, weak textView] notification in
                guard let self, let textView else { return }
                guard let raw = notification.object as? String,
                      let command = RichMarkdownEditorCommand(rawValue: raw) else { return }
                guard Self.activeCoordinator === self || Self.lastActiveTextView === textView else { return }
                self.execute(command: command)
            }
        }

        func execute(command: RichMarkdownEditorCommand) {
            guard let textView = boundTextView else { return }
            textView.window?.makeFirstResponder(textView)
            if savedSelection.length > 0,
               NSMaxRange(savedSelection) <= (textView.string as NSString).length {
                textView.setSelectedRange(savedSelection)
            }
            switch command {
            case .heading1: transformSelection(in: textView, style: .heading(1))
            case .heading2: transformSelection(in: textView, style: .heading(2))
            case .heading3: transformSelection(in: textView, style: .heading(3))
            case .bullet: transformSelection(in: textView, style: .bullet)
            case .numbered: transformSelection(in: textView, style: .numbered)
            case .blockquote: transformSelection(in: textView, style: .blockquote)
            case .checkbox: transformSelection(in: textView, style: .checkbox)
            case .codeBlock: transformSelection(in: textView, style: .codeBlock)
            case .imageGrow:
                if !resizeSelectedImage(in: textView, factor: 1.10) {
                    resizeImageReferenceNearCursor(in: textView, factor: 1.10)
                }
            case .imageShrink:
                if !resizeSelectedImage(in: textView, factor: 0.90) {
                    resizeImageReferenceNearCursor(in: textView, factor: 0.90)
                }
            }
            Self.activeCoordinator = self
            Self.lastActiveTextView = textView
        }

        @discardableResult
        func resizeSelectedImage(in textView: NSTextView, factor: CGFloat) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let selected = textView.selectedRange()
            let locationCandidates = [selected.location, max(0, selected.location - 1), min(storage.length, NSMaxRange(selected))]
            var targetRange: NSRange?
            var attachment: NSTextAttachment?

            if selected.length > 0 {
                var foundRange: NSRange?
                var foundAttachment: NSTextAttachment?
                storage.enumerateAttribute(.attachment, in: selected, options: []) { value, range, stop in
                    if let a = value as? NSTextAttachment {
                        foundAttachment = a
                        foundRange = range
                        stop.pointee = true
                    }
                }
                if let foundRange, let foundAttachment {
                    targetRange = foundRange
                    attachment = foundAttachment
                }
            }

            for location in locationCandidates where attachment == nil {
                guard location < storage.length else { continue }
                var effectiveRange = NSRange(location: 0, length: 0)
                if let found = storage.attribute(.attachment, at: location, effectiveRange: &effectiveRange) as? NSTextAttachment {
                    attachment = found
                    targetRange = effectiveRange
                    break
                }
            }

            guard let imageAttachment = attachment, let range = targetRange else { return false }

            let currentWidth = (storage.attribute(Self.imageWidthKey, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue
                ?? Double(imageAttachment.attachmentCell?.cellSize().width ?? 300)
            let nextWidth = max(120, min(700, currentWidth * Double(factor)))

            let filename =
                (storage.attribute(Self.imageFilenameKey, at: range.location, effectiveRange: nil) as? String)
                ?? ""
            if let image = ImageStore.load(filename: filename) {
                let scale = image.size.width > 0 ? nextWidth / Double(image.size.width) : 1.0
                let displaySize = NSSize(width: nextWidth, height: max(1, Double(image.size.height) * scale))
                let cell = NSTextAttachmentCell(imageCell: image)
                cell.image?.size = displaySize
                imageAttachment.attachmentCell = cell
            }

            storage.addAttribute(Self.imageWidthKey, value: NSNumber(value: nextWidth), range: range)
            parent.text = currentMarkdown(from: textView)
            parent.onChange()
            return true
        }

        func applyToggleFromToolbar(_ style: MarkdownTransformStyle) {
            guard let textView = boundTextView else { return }
            textView.window?.makeFirstResponder(textView)
            if savedSelection.length > 0,
               NSMaxRange(savedSelection) <= (textView.string as NSString).length {
                textView.setSelectedRange(savedSelection)
            }
            let selection = textView.selectedRange()

            if case .hyperlink = style {
                promptForLink(textView: textView, selection: selection)
                return
            }

            guard selection.length > 0 else {
                if case .codeBlock = style {
                    let insertionPoint = selection.location
                    let block = "```\n\n```"
                    textView.insertText(block, replacementRange: selection)
                    DispatchQueue.main.async {
                        let cursorPos = insertionPoint + 4
                        if cursorPos <= (textView.string as NSString).length {
                            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                        }
                    }
                } else if case .bullet = style {
                    textView.insertText("- ", replacementRange: selection)
                } else if case .numbered = style {
                    textView.insertText("1. ", replacementRange: selection)
                } else {
                    let inserted = style.apply(to: "text")
                    textView.insertText(inserted, replacementRange: selection)
                }
                return
            }
            let nsText = textView.string as NSString
            let selectedText = nsText.substring(with: selection)
            if let unwrapped = style.unwrap(from: selectedText) {
                textView.insertText(unwrapped, replacementRange: selection)
            } else {
                let wrapped = style.apply(to: selectedText)
                textView.insertText(wrapped, replacementRange: selection)
            }
        }

        private func promptForLink(textView: NSTextView, selection: NSRange) {
            let nsText = textView.string as NSString
            let selectedText = selection.length > 0 ? nsText.substring(with: selection) : ""

            if selectedText.hasPrefix("[") && selectedText.contains("](") && selectedText.hasSuffix(")") {
                if let unwrapped = MarkdownTransformStyle.hyperlink.unwrap(from: selectedText) {
                    textView.insertText(unwrapped, replacementRange: selection)
                }
                return
            }

            let alert = NSAlert()
            alert.messageText = "Paste Link"
            alert.informativeText = selectedText.isEmpty ? "Enter URL:" : "Enter URL for \"\(selectedText)\":"
            alert.addButton(withTitle: "Add Link")
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "https://"

            let pb = NSPasteboard.general
            if let clipText = pb.string(forType: .string),
               clipText.hasPrefix("http://") || clipText.hasPrefix("https://") {
                input.stringValue = clipText
            }

            alert.accessoryView = input
            alert.window.initialFirstResponder = input

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }

            let linkText = selectedText.isEmpty ? url : selectedText
            let markdown = "[\(linkText)](\(url))"

            textView.window?.makeFirstResponder(textView)
            textView.insertText(markdown, replacementRange: selection)
        }

        func transformSelection(in textView: NSTextView, style: MarkdownTransformStyle) {
            let nsText = textView.string as NSString
            var selection = textView.selectedRange()
            if selection.length == 0 {
                selection = nsText.lineRange(for: selection)
            }
            guard NSMaxRange(selection) <= nsText.length else { return }
            let selectedText = nsText.substring(with: selection)
            let transformed = style.apply(to: selectedText)
            textView.insertText(transformed, replacementRange: selection)
        }

        // MARK: - NSTextViewDelegate — intercept paste via textView(_:doCommandBy:)

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let urlStr = link as? String, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.paste(_:)) ||
               commandSelector == #selector(NSTextView.pasteAsPlainText(_:)) {
                if let image = ImagePasteHelper.imageFromPasteboard() {
                    insertImage(image, into: textView)
                    return true
                }
            }

            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                return handleEnterKey(in: textView)
            }

            return false
        }

        private func handleEnterKey(in textView: NSTextView) -> Bool {
            let nsText = textView.string as NSString
            let cursor = textView.selectedRange().location
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if line == "- " || line == "* " {
                textView.insertText("", replacementRange: lineRange)
                return true
            }
            if line.range(of: #"^\d+\.\s$"#, options: .regularExpression) != nil {
                textView.insertText("", replacementRange: lineRange)
                return true
            }

            if line.hasPrefix("- ") && line.count > 2 {
                textView.insertText("\n- ", replacementRange: textView.selectedRange())
                return true
            }
            if line.hasPrefix("* ") && line.count > 2 {
                textView.insertText("\n* ", replacementRange: textView.selectedRange())
                return true
            }

            if let nsMatch = try? NSRegularExpression(pattern: #"^(\d+)\.\s"#).firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               nsMatch.numberOfRanges > 1 {
                let numRange = nsMatch.range(at: 1)
                let numStr = (line as NSString).substring(with: numRange)
                if let num = Int(numStr) {
                    textView.insertText("\n\(num + 1). ", replacementRange: textView.selectedRange())
                    return true
                }
            }

            return false
        }

        /// Flag to prevent textDidChange recursion when we insert attachments
        private var isApplyingFormatting = false

        func applyRichFormatting(to textView: NSTextView) {
            guard !isApplyingFormatting else { return }
            isApplyingFormatting = true
            defer { isApplyingFormatting = false }

            let text = textView.string
            let storage = textView.textStorage!
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard fullRange.length > 0 else { return }

            // Base style
            let bodyFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            let bodyColor = NSColor(white: 0.92, alpha: 1) // Theme.textPrimary
            let secondaryColor = NSColor(white: 0.6, alpha: 1) // Theme.textSecondary
            let tertiaryColor = NSColor(white: 0.35, alpha: 1)

            let baseParagraph = NSMutableParagraphStyle()
            baseParagraph.lineSpacing = 4
            baseParagraph.paragraphSpacing = 6

            storage.beginEditing()

            storage.addAttributes([
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: baseParagraph
            ], range: fullRange)

            let nsText = text as NSString

            // Process line by line for block-level formatting
            nsText.enumerateSubstrings(in: fullRange, options: .byLines) { line, lineRange, _, _ in
                guard let line else { return }

                // # Headings — render large and bold, hide the # prefix
                if line.hasPrefix("# ") {
                    let headingFont = NSFont.systemFont(ofSize: 28, weight: .bold)
                    storage.addAttribute(.font, value: headingFont, range: lineRange)
                    let prefixRange = NSRange(location: lineRange.location, length: 2)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: prefixRange)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: prefixRange)
                } else if line.hasPrefix("## ") {
                    let headingFont = NSFont.systemFont(ofSize: 22, weight: .bold)
                    storage.addAttribute(.font, value: headingFont, range: lineRange)
                    let prefixRange = NSRange(location: lineRange.location, length: 3)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: prefixRange)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: prefixRange)
                } else if line.hasPrefix("### ") {
                    let headingFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
                    storage.addAttribute(.font, value: headingFont, range: lineRange)
                    let prefixRange = NSRange(location: lineRange.location, length: 4)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: prefixRange)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: prefixRange)
                }

                // Image lines — hide the markdown text, we'll show images after endEditing
                if line.range(of: "^!\\[.*\\]\\(noteai-image://.*\\)$", options: .regularExpression) != nil {
                    // Make the markdown reference tiny and dim so images take visual priority
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: lineRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                }

                // > Blockquote — orange left accent + italic
                if line.hasPrefix("> ") {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemOrange.withAlphaComponent(0.8), range: lineRange)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(.italicFontMask), range: lineRange)
                    let prefixRange = NSRange(location: lineRange.location, length: min(2, lineRange.length))
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: prefixRange)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: prefixRange)
                }

                // - [ ] / - [x] Checkboxes — green for checked
                if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: lineRange)
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: lineRange.location + 6, length: max(0, lineRange.length - 6)))
                } else if line.hasPrefix("- [ ] ") {
                    let prefixRange = NSRange(location: lineRange.location, length: min(6, lineRange.length))
                    storage.addAttribute(.foregroundColor, value: secondaryColor, range: prefixRange)
                }

                // - Bullet — dim the dash
                if line.hasPrefix("- ") && !line.hasPrefix("- [") {
                    let prefixRange = NSRange(location: lineRange.location, length: min(2, lineRange.length))
                    storage.addAttribute(.foregroundColor, value: tertiaryColor, range: prefixRange)
                }

                // --- Horizontal rule
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    storage.addAttribute(.foregroundColor, value: tertiaryColor, range: lineRange)
                }
            }

            // Fenced code blocks: ```...``` — monospace pink with dark background, fences hidden
            if let codeRegex = try? NSRegularExpression(pattern: "```[^`]*?\n([\\s\\S]*?)\n```", options: []) {
                for match in codeRegex.matches(in: text, range: fullRange) {
                    guard match.numberOfRanges > 1 else { continue }
                    let contentRange = match.range(at: 1)

                    let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    storage.addAttribute(.font, value: codeFont, range: contentRange)
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: contentRange)
                    storage.addAttribute(.backgroundColor, value: RichMarkdownEditorTheme.codeBlockBackground, range: contentRange)

                    let codeParagraph = NSMutableParagraphStyle()
                    codeParagraph.lineSpacing = 3
                    codeParagraph.paragraphSpacing = 2
                    codeParagraph.headIndent = 12
                    codeParagraph.firstLineHeadIndent = 12
                    storage.addAttribute(.paragraphStyle, value: codeParagraph, range: contentRange)

                    let openFenceEnd = contentRange.location - 1
                    if openFenceEnd > match.range.location {
                        let openFence = NSRange(location: match.range.location, length: openFenceEnd - match.range.location)
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: openFence)
                        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: openFence)
                        let hidePara = NSMutableParagraphStyle()
                        hidePara.maximumLineHeight = 0.1
                        hidePara.lineSpacing = 0
                        hidePara.paragraphSpacing = 0
                        hidePara.paragraphSpacingBefore = 0
                        storage.addAttribute(.paragraphStyle, value: hidePara, range: openFence)
                    }

                    let closeStart = contentRange.location + contentRange.length + 1
                    let closeLen = (match.range.location + match.range.length) - closeStart
                    if closeLen > 0 {
                        let closeFence = NSRange(location: closeStart, length: closeLen)
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: closeFence)
                        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: closeFence)
                        let hidePara = NSMutableParagraphStyle()
                        hidePara.maximumLineHeight = 0.1
                        hidePara.lineSpacing = 0
                        hidePara.paragraphSpacing = 0
                        hidePara.paragraphSpacingBefore = 0
                        storage.addAttribute(.paragraphStyle, value: hidePara, range: closeFence)
                    }
                }
            }

            // Inline patterns (across the full text) — markers are hidden (clear + size 1)
            applyInlinePattern("\\*\\*(.+?)\\*\\*", to: storage, in: text, fullRange: fullRange) { matchRange, innerRange in
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: innerRange)
                let startMarker = NSRange(location: matchRange.location, length: 2)
                let endMarker = NSRange(location: matchRange.location + matchRange.length - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: startMarker)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: endMarker)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: startMarker)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: endMarker)
            }

            applyInlinePattern("(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", to: storage, in: text, fullRange: fullRange) { matchRange, innerRange in
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .regular).withTraits(.italicFontMask), range: innerRange)
                let startM = NSRange(location: matchRange.location, length: 1)
                let endM = NSRange(location: matchRange.location + matchRange.length - 1, length: 1)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: startM)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: endM)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: startM)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: endM)
            }

            applyInlinePattern("(?<!`)`(?!`)([^`]+)`(?!`)", to: storage, in: text, fullRange: fullRange) { matchRange, innerRange in
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: innerRange)
                storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: innerRange)
                let startM = NSRange(location: matchRange.location, length: 1)
                let endM = NSRange(location: matchRange.location + matchRange.length - 1, length: 1)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: startM)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: endM)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: startM)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: endM)
            }

            // <u>underline</u>
            applyInlinePattern("<u>(.+?)</u>", to: storage, in: text, fullRange: fullRange) { matchRange, innerRange in
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: innerRange)
                let startTag = NSRange(location: matchRange.location, length: 3)
                let endTag = NSRange(location: matchRange.location + matchRange.length - 4, length: 4)
                storage.addAttribute(.foregroundColor, value: tertiaryColor, range: startTag)
                storage.addAttribute(.foregroundColor, value: tertiaryColor, range: endTag)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: startTag)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: endTag)
            }

            // [link text](url) — render as blue underlined + clickable, hide markdown syntax
            let linkPattern = "\\[([^\\]]+)\\]\\(([^)]+)\\)"
            if let linkRegex = try? NSRegularExpression(pattern: linkPattern) {
                for match in linkRegex.matches(in: text, range: fullRange) {
                    guard match.numberOfRanges > 2 else { continue }
                    let fullMatch = match.range
                    let textRange = match.range(at: 1)
                    let urlRange = match.range(at: 2)
                    let urlStr = nsText.substring(with: urlRange)

                    storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: textRange)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                    if let url = URL(string: urlStr) {
                        storage.addAttribute(.link, value: url, range: textRange)
                        storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: textRange)
                    }

                    let beforeText = NSRange(location: fullMatch.location, length: 1)
                    let afterTextStart = textRange.location + textRange.length
                    let afterText = NSRange(location: afterTextStart, length: fullMatch.location + fullMatch.length - afterTextStart)
                    storage.addAttribute(.foregroundColor, value: tertiaryColor, range: beforeText)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: beforeText)
                    storage.addAttribute(.foregroundColor, value: tertiaryColor, range: afterText)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: afterText)
                }
            }

            // Replace image markdown lines with NSTextAttachment containing the actual image
            // Process in reverse order so range offsets stay valid
            let imagePattern = "!\\[[^\\]]*\\]\\((noteai-image://[^)]+)\\)"
            if let regex = try? NSRegularExpression(pattern: imagePattern) {
                let matches = regex.matches(in: text, range: fullRange).reversed()
                for match in matches {
                    guard match.numberOfRanges > 1 else { continue }
                    let sourceRange = match.range(at: 1)
                    let source = nsText.substring(with: sourceRange)
                    guard let filename = ImageStore.filename(from: source),
                          let nsImage = ImageStore.load(filename: filename) else { continue }

                    // Scale image to fit editor width (max ~500pt)
                    let editorWidth = max(300, textView.visibleRect.width - 40)
                    let defaultWidth = min(editorWidth, nsImage.size.width)
                    let preferredWidth = ImageStore.width(from: source).map { CGFloat($0) } ?? defaultWidth
                    let targetWidth = max(80, preferredWidth)
                    let scale = nsImage.size.width > 0 ? targetWidth / nsImage.size.width : 1.0
                    let displaySize = NSSize(
                        width: targetWidth,
                        height: max(1, nsImage.size.height * scale)
                    )

                    let attachment = NSTextAttachment()
                    let cell = NSTextAttachmentCell(imageCell: nsImage)
                    cell.image?.size = displaySize
                    attachment.attachmentCell = cell

                    let alignStr = ImageStore.alignment(from: source)
                    var attrs: [NSAttributedString.Key: Any] = [
                        Self.imageFilenameKey: filename,
                        Self.imageWidthKey: NSNumber(value: Double(targetWidth))
                    ]
                    if let alignStr { attrs[RichEditorTextView.imageAlignKey] = alignStr }

                    let attachmentString = NSMutableAttributedString(attachment: attachment)
                    attachmentString.addAttributes(attrs, range: NSRange(location: 0, length: attachmentString.length))
                    storage.replaceCharacters(in: match.range, with: attachmentString)
                }
            }

            let alignKey = RichEditorTextView.imageAlignKey
            let updatedFullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(alignKey, in: updatedFullRange) { value, range, _ in
                guard let alignStr = value as? String else { return }
                let alignment: NSTextAlignment = switch alignStr {
                    case "center": .center
                    case "right": .right
                    default: .left
                }
                let lineRange = (storage.string as NSString).lineRange(for: range)
                let para = NSMutableParagraphStyle()
                para.alignment = alignment
                para.lineSpacing = 4
                para.paragraphSpacing = 6
                storage.addAttribute(.paragraphStyle, value: para, range: lineRange)
            }

            storage.endEditing()
        }

        private func applyInlinePattern(
            _ pattern: String,
            to storage: NSTextStorage,
            in text: String,
            fullRange: NSRange,
            apply: (NSRange, NSRange) -> Void
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            for match in regex.matches(in: text, range: fullRange) {
                let matchRange = match.range
                if match.numberOfRanges > 1 {
                    let innerRange = match.range(at: 1)
                    apply(matchRange, innerRange)
                }
            }
        }

        func currentMarkdown(from textView: NSTextView) -> String {
            guard let storage = textView.textStorage else { return textView.string }
            let mutable = NSMutableString(string: storage.string)
            let fullRange = NSRange(location: 0, length: storage.length)

            var replacementTuples: [(NSRange, String)] = []
            let alignKey = RichEditorTextView.imageAlignKey
            storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
                guard value is NSTextAttachment else { return }
                let filename =
                    (storage.attribute(Self.imageFilenameKey, at: range.location, effectiveRange: nil) as? String)
                    ?? "image.png"
                let width =
                    (storage.attribute(Self.imageWidthKey, at: range.location, effectiveRange: nil) as? NSNumber)?
                        .doubleValue
                let align = storage.attribute(alignKey, at: range.location, effectiveRange: nil) as? String
                var params: [String] = []
                if let w = width { params.append("w=\(Int(w.rounded()))") }
                if let a = align, a != "left" { params.append("a=\(a)") }
                let query = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
                let markdown = "![\(filename)](\(ImageStore.scheme)://\(filename)\(query))"
                replacementTuples.append((range, markdown))
            }

            for (range, replacement) in replacementTuples.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }
            return String(mutable)
        }

        func selectedMarkdownText() -> String? {
            guard let textView = boundTextView else { return nil }
            let ranges = [
                textView.selectedRange(),
                (textView as? RichEditorTextView)?.savedSelectedRange ?? NSRange(location: 0, length: 0),
                savedSelection,
            ]

            for range in ranges {
                if let selected = ReadAloudTextResolver.selectedText(in: textView.string, range: range) {
                    return selected
                }
            }

            return nil
        }

        func resizeNearestImage(factor: CGFloat) {
            guard let textView = boundTextView else { return }
            if !resizeSelectedImage(in: textView, factor: factor) {
                resizeImageReferenceNearCursor(in: textView, factor: factor)
            }
        }

        func resizeImageInMarkdown(factor: CGFloat) {
            let markdown = parent.text
            let nsMarkdown = markdown as NSString
            let fullRange = NSRange(location: 0, length: nsMarkdown.length)
            guard fullRange.length > 0 else { return }

            let pattern = "!\\[[^\\]]*\\]\\((noteai-image://[^)]+)\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let matches = regex.matches(in: markdown, range: fullRange)
            guard !matches.isEmpty else { return }

            var bestMatch = matches.first!
            if let textView = boundTextView {
                let cursorInDisplay = textView.selectedRange().location
                let totalDisplayLength = (textView.string as NSString).length
                let totalMarkdownLength = nsMarkdown.length
                let ratio = totalMarkdownLength > 0 ? Double(totalDisplayLength) / Double(totalMarkdownLength) : 1.0
                let approxMarkdownPos = Int(Double(cursorInDisplay) / max(ratio, 0.01))
                var bestDist = Int.max
                for m in matches {
                    let dist = abs(m.range.location - approxMarkdownPos)
                    if dist < bestDist { bestDist = dist; bestMatch = m }
                }
            }

            guard bestMatch.numberOfRanges > 1 else { return }
            let sourceRange = bestMatch.range(at: 1)
            let source = nsMarkdown.substring(with: sourceRange)
            guard let filename = ImageStore.filename(from: source) else { return }

            let currentWidth = ImageStore.width(from: source) ?? 500
            let nextWidth = max(120, min(700, currentWidth * Double(factor)))
            let newSource = "\(ImageStore.scheme)://\(filename)?w=\(Int(nextWidth.rounded()))"

            let updated = nsMarkdown.replacingCharacters(in: sourceRange, with: newSource)
            parent.text = updated
            parent.onChange()
        }

        func resizeImageReferenceNearCursor(in textView: NSTextView, factor: CGFloat) {
            let markdown = currentMarkdown(from: textView)
            let nsMarkdown = markdown as NSString
            let fullRange = NSRange(location: 0, length: nsMarkdown.length)
            guard fullRange.length > 0 else { return }

            let pattern = "!\\[[^\\]]*\\]\\((noteai-image://[^)]+)\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let matches = regex.matches(in: markdown, range: fullRange)
            guard !matches.isEmpty else { return }

            let cursor = min(textView.selectedRange().location, nsMarkdown.length)
            let selectedMatch: NSTextCheckingResult? =
                matches.first(where: { NSLocationInRange(cursor, $0.range) })
                ?? matches.last(where: { $0.range.location <= cursor })
                ?? matches.first
            guard let match = selectedMatch, match.numberOfRanges > 1 else { return }

            let sourceRange = match.range(at: 1)
            let source = nsMarkdown.substring(with: sourceRange)
            guard let filename = ImageStore.filename(from: source) else { return }

            let currentWidth = ImageStore.width(from: source) ?? 500
            let nextWidth = max(120, min(700, currentWidth * Double(factor)))
            let newSource = "\(ImageStore.scheme)://\(filename)?w=\(Int(nextWidth.rounded()))"

            let updated = NSMutableString(string: markdown)
            updated.replaceCharacters(in: sourceRange, with: newSource)
            textView.string = updated as String
            applyRichFormatting(to: textView)
            parent.text = currentMarkdown(from: textView)
            parent.onChange()
            Self.activeCoordinator = self
        }
    }
}

// Helper to add font traits
extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits(rawValue: UInt32(traits.rawValue)))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Image Paste Helper

/// Handles image paste detection and installs a keyboard monitor on the text view.
enum ImagePasteHelper {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    /// Check if the general pasteboard contains image data.
    static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general

        for imageType in imageTypes {
            if let data = pb.data(forType: imageType), let image = NSImage(data: data) {
                return image
            }
        }

        // Check for image file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: ["public.image"]
        ]) as? [URL], let url = urls.first, let image = NSImage(contentsOf: url) {
            return image
        }

        return nil
    }

    /// Installs a local key-event monitor that intercepts Cmd+V when the text view is first responder.
    static func install(on textView: NSTextView, coordinator: RichMarkdownEditor.Coordinator) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept Cmd+V
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "v" else {
                // Markdown transforms and image resizing shortcuts (Cmd+Option+...)
                if event.modifierFlags.contains([.command, .option]),
                   let key = event.charactersIgnoringModifiers?.lowercased() {
                    switch key {
                    case "=":
                        if !coordinator.resizeSelectedImage(in: textView, factor: 1.10) {
                            coordinator.resizeImageReferenceNearCursor(in: textView, factor: 1.10)
                        }
                        return nil
                    case "-":
                        if !coordinator.resizeSelectedImage(in: textView, factor: 0.90) {
                            coordinator.resizeImageReferenceNearCursor(in: textView, factor: 0.90)
                        }
                        return nil
                    case "1":
                        coordinator.transformSelection(in: textView, style: .heading(1))
                        return nil
                    case "2":
                        coordinator.transformSelection(in: textView, style: .heading(2))
                        return nil
                    case "3":
                        coordinator.transformSelection(in: textView, style: .heading(3))
                        return nil
                    case "b":
                        coordinator.transformSelection(in: textView, style: .bullet)
                        return nil
                    case "n":
                        coordinator.transformSelection(in: textView, style: .numbered)
                        return nil
                    case "q":
                        coordinator.transformSelection(in: textView, style: .blockquote)
                        return nil
                    case "x":
                        coordinator.transformSelection(in: textView, style: .checkbox)
                        return nil
                    case "c":
                        coordinator.transformSelection(in: textView, style: .codeBlock)
                        return nil
                    default:
                        break
                    }
                }
                return event
            }

            // Only if our text view is the first responder
            guard let window = textView.window,
                  window.firstResponder === textView else {
                return event
            }

            // Only if there's an image on the pasteboard
            guard let image = imageFromPasteboard() else {
                return event
            }

            // Handle the image paste
            coordinator.insertImage(image, into: textView)
            return nil // Consume the event
        }
    }
}

enum MarkdownTransformStyle {
    case heading(Int)
    case bullet
    case numbered
    case blockquote
    case checkbox
    case codeBlock
    case bold
    case italic
    case underline
    case strikethrough
    case inlineCode
    case hyperlink

    func apply(to text: String) -> String {
        switch self {
        case .bold: return "**\(text)**"
        case .italic: return "*\(text)*"
        case .underline: return "<u>\(text)</u>"
        case .strikethrough: return "~~\(text)~~"
        case .inlineCode: return "`\(text)`"
        case .hyperlink: return "[\(text)](url)"
        case .codeBlock:
            let trimmed = text.trimmingCharacters(in: .newlines)
            return "```\n\(trimmed)\n```"
        default:
            let lines = text.components(separatedBy: "\n")
            switch self {
            case .heading(let level):
                let prefix = String(repeating: "#", count: max(1, min(6, level))) + " "
                return lines.map { line in
                    let trimmed = line.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
                    return trimmed.isEmpty ? line : "\(prefix)\(trimmed)"
                }.joined(separator: "\n")
            case .bullet:
                return lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : "- \($0)" }
                    .joined(separator: "\n")
            case .numbered:
                var index = 1
                return lines.map { line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                    defer { index += 1 }
                    return "\(index). \(line)"
                }.joined(separator: "\n")
            case .blockquote:
                return lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : "> \($0)" }
                    .joined(separator: "\n")
            case .checkbox:
                return lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : "- [ ] \($0)" }
                    .joined(separator: "\n")
            default: return text
            }
        }
    }

    func unwrap(from text: String) -> String? {
        switch self {
        case .bold:
            if text.hasPrefix("**") && text.hasSuffix("**") && text.count > 4 {
                return String(text.dropFirst(2).dropLast(2))
            }
        case .italic:
            if text.hasPrefix("*") && text.hasSuffix("*") && !text.hasPrefix("**") && text.count > 2 {
                return String(text.dropFirst(1).dropLast(1))
            }
        case .underline:
            if text.hasPrefix("<u>") && text.hasSuffix("</u>") {
                return String(text.dropFirst(3).dropLast(4))
            }
        case .strikethrough:
            if text.hasPrefix("~~") && text.hasSuffix("~~") && text.count > 4 {
                return String(text.dropFirst(2).dropLast(2))
            }
        case .inlineCode:
            if text.hasPrefix("`") && text.hasSuffix("`") && !text.hasPrefix("``") && text.count > 2 {
                return String(text.dropFirst(1).dropLast(1))
            }
        case .hyperlink:
            if text.hasPrefix("[") && text.contains("](") && text.hasSuffix(")") {
                if let bracketEnd = text.firstIndex(of: "]") {
                    return String(text[text.index(after: text.startIndex)..<bracketEnd])
                }
            }
        case .codeBlock:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
                var inner = String(trimmed.dropFirst(3))
                if let newline = inner.firstIndex(of: "\n") { inner = String(inner[inner.index(after: newline)...]) }
                if inner.hasSuffix("```") { inner = String(inner.dropLast(3)) }
                return inner.trimmingCharacters(in: .newlines)
            }
        case .heading:
            let lines = text.components(separatedBy: "\n")
            let allHeadings = lines.allSatisfy { $0.isEmpty || $0.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) != nil }
            if allHeadings {
                return lines.map { $0.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression) }
                    .joined(separator: "\n")
            }
        case .bullet:
            let lines = text.components(separatedBy: "\n")
            let allBullets = lines.allSatisfy { $0.isEmpty || $0.hasPrefix("- ") }
            if allBullets { return lines.map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n") }
        case .numbered:
            let lines = text.components(separatedBy: "\n")
            let allNumbered = lines.allSatisfy { $0.isEmpty || $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }
            if allNumbered {
                return lines.map { $0.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression) }
                    .joined(separator: "\n")
            }
        case .blockquote:
            let lines = text.components(separatedBy: "\n")
            let allQuotes = lines.allSatisfy { $0.isEmpty || $0.hasPrefix("> ") }
            if allQuotes { return lines.map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n") }
        case .checkbox:
            let lines = text.components(separatedBy: "\n")
            let allCheckboxes = lines.allSatisfy { $0.isEmpty || $0.hasPrefix("- [ ] ") || $0.hasPrefix("- [x] ") || $0.hasPrefix("- [X] ") }
            if allCheckboxes {
                return lines.map {
                    if $0.hasPrefix("- [ ] ") { return String($0.dropFirst(6)) }
                    if $0.hasPrefix("- [x] ") || $0.hasPrefix("- [X] ") { return String($0.dropFirst(6)) }
                    return $0
                }.joined(separator: "\n")
            }
        }
        return nil
    }
}

enum RichMarkdownEditorCommand: String {
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case blockquote
    case checkbox
    case codeBlock
    case imageGrow
    case imageShrink
}

extension Notification.Name {
    static let richMarkdownEditorCommand = Notification.Name("richMarkdownEditorCommand")
}
