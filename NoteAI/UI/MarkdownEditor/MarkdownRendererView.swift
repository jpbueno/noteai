import SwiftUI
import AppKit

/// Renders Markdown text as styled attributed text using native AppKit.
struct MarkdownRendererView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block types

    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bullet(text: String)
        case numberedItem(number: String, text: String)
        case checkbox(checked: Bool, text: String)
        case blockquote(text: String)
        case codeBlock(code: String)
        case image(alt: String, src: String)
        case horizontalRule
        case empty
    }

    // MARK: - Parser

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                blocks.append(.empty)
                i += 1
                continue
            }

            // Headings
            if let match = trimmed.range(of: "^(#{1,6}) (.+)$", options: .regularExpression) {
                let full = String(trimmed[match])
                let hashCount = full.prefix(while: { $0 == "#" }).count
                let text = String(full.dropFirst(hashCount + 1))
                blocks.append(.heading(level: hashCount, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Code block
            if trimmed.hasPrefix("```") {
                var code = ""
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code += lines[i] + "\n"
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.codeBlock(code: code.trimmingCharacters(in: .newlines)))
                continue
            }

            // Checkbox
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                blocks.append(.checkbox(checked: true, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            }
            if trimmed.hasPrefix("- [ ] ") {
                blocks.append(.checkbox(checked: false, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            }

            // Bullet
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // Numbered list
            if let match = trimmed.range(of: "^(\\d+)\\. (.+)$", options: .regularExpression) {
                let full = String(trimmed[match])
                let dotIndex = full.firstIndex(of: ".")!
                let num = String(full[full.startIndex..<dotIndex])
                let text = String(full[full.index(dotIndex, offsetBy: 2)...])
                blocks.append(.numberedItem(number: num, text: text))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                blocks.append(.blockquote(text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            // Image: ![alt](src)
            if let match = trimmed.range(of: "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$", options: .regularExpression) {
                let full = String(trimmed[match])
                if let altEnd = full.firstIndex(of: "]"),
                   let srcStart = full.range(of: "](")?.upperBound,
                   let srcEnd = full.lastIndex(of: ")") {
                    let alt = String(full[full.index(full.startIndex, offsetBy: 2)..<altEnd])
                    let src = String(full[srcStart..<srcEnd])
                    blocks.append(.image(alt: alt, src: src))
                    i += 1
                    continue
                }
            }

            // Regular paragraph
            blocks.append(.paragraph(text: trimmed))
            i += 1
        }

        return blocks
    }

    // MARK: - Renderers

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)
                .padding(.top, level == 1 ? 16 : 12)
                .padding(.bottom, 4)

        case .paragraph(let text):
            renderInlineText(text)
                .padding(.vertical, 2)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .foregroundStyle(.secondary)
                renderInlineText(text)
            }
            .padding(.leading, 12)
            .padding(.vertical, 1)

        case .numberedItem(let number, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                renderInlineText(text)
            }
            .padding(.leading, 8)
            .padding(.vertical, 1)

        case .checkbox(let checked, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? .green : .secondary)
                renderInlineText(text)
                    .strikethrough(checked)
                    .foregroundStyle(checked ? .secondary : .primary)
            }
            .padding(.leading, 12)
            .padding(.vertical, 1)

        case .blockquote(let text):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.orange.opacity(0.6))
                    .frame(width: 3)
                renderInlineText(text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.vertical, 4)
            }
            .padding(.leading, 8)
            .padding(.vertical, 2)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.pink)
                    .padding(12)
            }
            .background(Theme.contentBG, in: RoundedRectangle(cornerRadius: 8))
            .padding(.vertical, 4)

        case .image(let alt, let src):
            renderImage(alt: alt, src: src)
                .padding(.vertical, 4)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 8)

        case .empty:
            Spacer()
                .frame(height: 8)
        }
    }

    private func renderHeading(level: Int, text: String) -> some View {
        let fontSize: CGFloat = switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        default: 16
        }

        return Text(text)
            .font(.system(size: fontSize, weight: .bold))
    }

    @ViewBuilder
    private func renderImage(alt: String, src: String) -> some View {
        if let filename = ImageStore.filename(from: src),
           let nsImage = ImageStore.load(filename: filename) {
            let preferredWidth = ImageStore.width(from: src).map { CGFloat($0) } ?? 500
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: max(120, min(700, preferredWidth)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(alt)
        } else {
            // Fallback for non-local images or broken references
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(alt.isEmpty ? "Image" : alt)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Renders inline Markdown: **bold**, _italic_, `code`, ~~strikethrough~~
    private func renderInlineText(_ text: String) -> Text {
        var result = Text("")
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Bold **text**
            if remaining.hasPrefix("**"),
               let endRange = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...].range(of: "**") {
                let content = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<endRange.lowerBound]
                result = result + Text(content).bold()
                remaining = remaining[endRange.upperBound...]
                continue
            }

            // Inline code `text`
            if remaining.hasPrefix("`"),
               let endIdx = remaining[remaining.index(after: remaining.startIndex)...].firstIndex(of: "`") {
                let content = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(content).font(.system(.body, design: .monospaced)).foregroundColor(.pink)
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Italic _text_
            if remaining.hasPrefix("_"),
               let endIdx = remaining[remaining.index(after: remaining.startIndex)...].firstIndex(of: "_") {
                let content = remaining[remaining.index(after: remaining.startIndex)..<endIdx]
                result = result + Text(content).italic()
                remaining = remaining[remaining.index(after: endIdx)...]
                continue
            }

            // Strikethrough ~~text~~
            if remaining.hasPrefix("~~"),
               let endRange = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...].range(of: "~~") {
                let content = remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<endRange.lowerBound]
                result = result + Text(content).strikethrough()
                remaining = remaining[endRange.upperBound...]
                continue
            }

            // Regular character
            let nextSpecial = remaining.dropFirst().firstIndex(where: { $0 == "*" || $0 == "`" || $0 == "_" || $0 == "~" }) ?? remaining.endIndex
            let chunk = remaining[remaining.startIndex..<nextSpecial]
            result = result + Text(chunk)
            remaining = remaining[nextSpecial...]
        }

        return result
    }
}
