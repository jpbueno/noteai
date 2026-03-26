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
    private let edgeHitZone: CGFloat = 8

    override func resignFirstResponder() -> Bool {
        savedSelectedRange = selectedRange()
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        if imageEdgeHit(for: event) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = imageEdgeHit(for: event) {
            isDraggingImageEdge = true
            dragAttachmentRange = hit.range
            dragFilename = hit.filename
            dragStartX = event.locationInWindow.x
            dragStartWidth = hit.currentWidth
            NSCursor.resizeLeftRight.push()
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
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingImageEdge {
            isDraggingImageEdge = false
            dragAttachmentRange = nil
            dragFilename = nil
            NSCursor.pop()
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
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
        textView.backgroundColor = NSColor(red: 0.122, green: 0.122, blue: 0.122, alpha: 1)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView

        ImagePasteHelper.install(on: textView, coordinator: context.coordinator)
        context.coordinator.bind(to: textView)

        context.coordinator.applyRichFormatting(to: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
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
        private lazy var floatingToolbar: FloatingToolbarPanel = {
            let panel = FloatingToolbarPanel()
            return panel
        }()

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
            Self.lastActiveTextView = textView
            Self.activeCoordinator = self
            floatingToolbar.attach(to: textView)
            DispatchQueue.main.async { [weak self] in
                self?.floatingToolbar.updatePosition()
            }
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
            floatingToolbar.attach(to: textView)

            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak textView] event in
                guard let self, let textView else { return event }
                if textView.window?.firstResponder === textView {
                    self.savedSelection = textView.selectedRange()
                }
                let clickInToolbar = self.floatingToolbar.isVisible &&
                    NSPointInRect(NSEvent.mouseLocation, self.floatingToolbar.frame)
                if !clickInToolbar {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.floatingToolbar.updatePosition()
                    }
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

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // paste: and pasteAsPlainText: are the selectors called on Cmd+V
            if commandSelector == #selector(NSTextView.paste(_:)) ||
               commandSelector == #selector(NSTextView.pasteAsPlainText(_:)) {
                if let image = ImagePasteHelper.imageFromPasteboard() {
                    insertImage(image, into: textView)
                    return true // We handled it
                }
            }
            return false // Let the text view handle it normally
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

                    let attachmentString = NSMutableAttributedString(attachment: attachment)
                    attachmentString.addAttributes([
                        Self.imageFilenameKey: filename,
                        Self.imageWidthKey: NSNumber(value: Double(targetWidth))
                    ], range: NSRange(location: 0, length: attachmentString.length))
                    storage.replaceCharacters(in: match.range, with: attachmentString)
                }
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
            storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
                guard value is NSTextAttachment else { return }
                let filename =
                    (storage.attribute(Self.imageFilenameKey, at: range.location, effectiveRange: nil) as? String)
                    ?? "image.png"
                let width =
                    (storage.attribute(Self.imageWidthKey, at: range.location, effectiveRange: nil) as? NSNumber)?
                        .doubleValue
                let widthPart = width == nil ? "" : "?w=\(Int((width ?? 0).rounded()))"
                let markdown = "![\(filename)](\(ImageStore.scheme)://\(filename)\(widthPart))"
                replacementTuples.append((range, markdown))
            }

            for (range, replacement) in replacementTuples.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }
            return String(mutable)
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

    func apply(to text: String) -> String {
        switch self {
        case .bold: return "**\(text)**"
        case .italic: return "*\(text)*"
        case .underline: return "<u>\(text)</u>"
        case .strikethrough: return "~~\(text)~~"
        case .inlineCode: return "`\(text)`"
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
