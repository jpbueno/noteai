import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A split-pane Markdown editor with live preview for meeting notes.
/// Users can edit the raw Markdown on the left and see rendered output on the right.
struct MarkdownEditorView: View {
    @Binding var meeting: Meeting
    @State private var markdownText: String = ""
    @State private var isEditing = false
    @State private var showPreview = true
    @State private var hasUnsavedChanges = false
    @State private var lastSavedText: String = ""
    @State private var autoExportPath: String = UserDefaults.standard.string(forKey: "markdownExportPath") ?? ""

    var onSave: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            markdownText = ExportManager.exportAsMarkdown(meeting)
            lastSavedText = markdownText
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Mode toggle
            Picker("Mode", selection: $isEditing) {
                Label("Preview", systemImage: "eye").tag(false)
                Label("Edit", systemImage: "pencil").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if isEditing {
                Toggle("Split View", isOn: $showPreview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Spacer()

            if hasUnsavedChanges {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Insert helpers
            if isEditing {
                Menu {
                    Button("Heading 1") { insertMarkdown("# ") }
                    Button("Heading 2") { insertMarkdown("## ") }
                    Button("Heading 3") { insertMarkdown("### ") }
                    Divider()
                    Button("Bold") { wrapSelection("**") }
                    Button("Italic") { wrapSelection("_") }
                    Button("Strikethrough") { wrapSelection("~~") }
                    Divider()
                    Button("Bullet List") { insertMarkdown("- ") }
                    Button("Numbered List") { insertMarkdown("1. ") }
                    Button("Checkbox") { insertMarkdown("- [ ] ") }
                    Divider()
                    Button("Code Block") { insertMarkdown("```\n\n```", offset: -4) }
                    Button("Blockquote") { insertMarkdown("> ") }
                    Button("Horizontal Rule") { insertMarkdown("\n---\n") }
                    Divider()
                    Button("Annotation") { insertAnnotation() }
                    Button("Timestamp Note") { insertTimestampNote() }
                } label: {
                    Label("Insert", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
            }

            // Actions
            Button {
                saveMarkdown()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasUnsavedChanges)

            Menu {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdownText, forType: .string)
                }
                Button("Export as .md File...") {
                    exportToFile()
                }
                Button("Export as PDF...") {
                    exportPDFToFile()
                }
                if !autoExportPath.isEmpty {
                    Button("Save to Vault (\(URL(fileURLWithPath: autoExportPath).lastPathComponent))") {
                        saveToVault()
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Editor Content

    @ViewBuilder
    private var editorContent: some View {
        if isEditing {
            if showPreview {
                HSplitView {
                    markdownEditor
                        .frame(minWidth: 300)
                    markdownPreview
                        .frame(minWidth: 300)
                }
            } else {
                markdownEditor
            }
        } else {
            markdownPreview
        }
    }

    private var markdownEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(markdownText.count) chars")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3))

            MarkdownTextEditor(text: $markdownText, onChange: {
                hasUnsavedChanges = markdownText != lastSavedText
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markdownPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3))

            ScrollView {
                MarkdownRendererView(markdown: markdownText)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func insertMarkdown(_ text: String, offset: Int = 0) {
        markdownText += "\n" + text
        hasUnsavedChanges = true
    }

    private func wrapSelection(_ wrapper: String) {
        markdownText += wrapper + "text" + wrapper
        hasUnsavedChanges = true
    }

    private func insertAnnotation() {
        let timestamp = Date().formatted(date: .abbreviated, time: .shortened)
        markdownText += "\n\n> **Note** (\(timestamp)): \n\n"
        hasUnsavedChanges = true
    }

    private func insertTimestampNote() {
        let timestamp = Date().formatted(date: .abbreviated, time: .shortened)
        markdownText += "\n\n---\n**[\(timestamp)]** \n\n"
        hasUnsavedChanges = true
    }

    private func saveMarkdown() {
        lastSavedText = markdownText
        hasUnsavedChanges = false
        onSave?(markdownText)

        // Auto-export if vault path configured
        if !autoExportPath.isEmpty {
            saveToVault()
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = ExportManager.markdownFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdownText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportPDFToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ExportManager.pdfFilename(for: meeting)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let pdfData = try? ExportManager.exportMarkdownAsPDFData(markdownText) {
                try? pdfData.write(to: url, options: .atomic)
            }
        }
    }

    private func saveToVault() {
        guard !autoExportPath.isEmpty else { return }
        let dir = URL(fileURLWithPath: autoExportPath)
        let fileURL = dir.appendingPathComponent(ExportManager.markdownFilename(for: meeting))
        try? markdownText.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - NSTextView wrapper for the Markdown editor

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text

        // Syntax highlighting
        context.coordinator.applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
            textView.setSelectedRange(selectedRange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onChange()
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let storage = textView.textStorage!

            // Reset to default
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)

            let patterns: [(String, NSColor, NSFont.Weight)] = [
                ("^#{1,6} .+$", NSColor.systemBlue, .bold),           // Headings
                ("\\*\\*[^*]+\\*\\*", NSColor.labelColor, .bold),      // Bold
                ("_[^_]+_", NSColor.secondaryLabelColor, .regular),    // Italic
                ("^- \\[[ x]\\] .+$", NSColor.systemGreen, .regular), // Checkboxes
                ("^>.*$", NSColor.systemOrange, .regular),             // Blockquotes
                ("^---$", NSColor.tertiaryLabelColor, .regular),       // Horizontal rule
                ("`[^`]+`", NSColor.systemPink, .regular),             // Inline code
                ("^```[\\s\\S]*?```$", NSColor.systemPink, .regular),  // Code blocks
            ]

            for (pattern, color, weight) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { continue }
                let matches = regex.matches(in: text, range: fullRange)
                for match in matches {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    if weight == .bold {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: match.range)
                    }
                }
            }
        }
    }
}
