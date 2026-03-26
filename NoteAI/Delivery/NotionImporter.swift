import Foundation

/// Imports Notion-exported Markdown files into NoteAI Notes.
///
/// Notion exports pages as Markdown files with a hash suffix in the filename:
///   "My Page Title abc123def456.md"
/// This importer strips that suffix to recover the clean page title.
struct NotionImporter {

    struct ImportResult {
        let imported: [Note]
        let skipped: [String]   // filenames that failed to parse
        let totalFilesFound: Int
    }

    /// Recursively scans `directoryURL` for `.md` files and converts each to a `Note`.
    static func importNotes(from directoryURL: URL) throws -> ImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else {
            throw ImportError.directoryNotFound(directoryURL.path)
        }

        let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var imported: [Note] = []
        var skipped: [String] = []
        var totalFiles = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            totalFiles += 1

            do {
                let note = try parseNotionFile(at: fileURL)
                imported.append(note)
            } catch {
                skipped.append(fileURL.lastPathComponent)
            }
        }

        return ImportResult(imported: imported, skipped: skipped, totalFilesFound: totalFiles)
    }

    // MARK: - Private

    private static func parseNotionFile(at url: URL) throws -> Note {
        let content = try String(contentsOf: url, encoding: .utf8)
        let filename = url.deletingPathExtension().lastPathComponent
        let title = cleanNotionTitle(filename)

        // Try to get file dates for the note
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let createdDate = (attributes?[.creationDate] as? Date) ?? Date()
        let modifiedDate = (attributes?[.modificationDate] as? Date) ?? Date()

        // Derive tags from the parent folder name (Notion exports use folder hierarchy)
        let parentFolder = url.deletingLastPathComponent().lastPathComponent
        var tags = ["notion-import"]
        if !parentFolder.isEmpty && parentFolder != "/" {
            let folderTag = cleanNotionTitle(parentFolder)
            if !folderTag.isEmpty {
                tags.append(folderTag)
            }
        }

        return Note(
            title: title,
            content: content,
            tags: tags,
            createdDate: createdDate,
            modifiedDate: modifiedDate
        )
    }

    /// Strips the Notion hash suffix from a filename.
    /// "My Page Title abc123def456" → "My Page Title"
    /// Notion appends a space + 32-char hex ID to exported filenames.
    static func cleanNotionTitle(_ filename: String) -> String {
        // Notion hash is a 32-character hex string at the end, preceded by a space
        let pattern = #"\s+[0-9a-f]{32}$"#
        if let range = filename.range(of: pattern, options: .regularExpression) {
            return String(filename[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return filename.trimmingCharacters(in: .whitespaces)
    }

    enum ImportError: LocalizedError {
        case directoryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .directoryNotFound(let path):
                return "Directory not found: \(path)"
            }
        }
    }
}
