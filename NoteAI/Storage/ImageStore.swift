import AppKit
import Foundation

/// Saves and loads images from the NoteAI images directory.
/// Images are referenced in markdown as `![alt](noteai-image://UUID.png)`.
enum ImageStore {
    static let scheme = "noteai-image"

    private static var imagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("NoteAI/images", isDirectory: true)
    }

    /// Saves an NSImage to disk and returns the markdown reference string to insert.
    static func save(_ image: NSImage) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let id = UUID().uuidString
        let filename = "\(id).png"
        let fileURL = imagesDirectory.appendingPathComponent(filename)

        do {
            try pngData.write(to: fileURL)
            return "![\(filename)](\(scheme)://\(filename))"
        } catch {
            print("[ImageStore] Failed to save image: \(error)")
            return nil
        }
    }

    /// Loads an image from the store by filename.
    static func load(filename: String) -> NSImage? {
        let fileURL = imagesDirectory.appendingPathComponent(filename)
        return NSImage(contentsOf: fileURL)
    }

    /// Extracts the filename from a `noteai-image://UUID.png` reference.
    static func filename(from reference: String) -> String? {
        guard let components = URLComponents(string: reference),
              components.scheme == scheme else { return nil }
        let path = components.path
        if path.hasPrefix("/") {
            return String(path.dropFirst())
        }
        return path.isEmpty ? components.host : path
    }

    /// Optional width hint encoded in a markdown image source query, e.g. `...?w=320`.
    static func width(from reference: String) -> Double? {
        guard let components = URLComponents(string: reference) else { return nil }
        return components.queryItems?.first(where: { $0.name == "w" }).flatMap { item in
            guard let value = item.value, let width = Double(value), width > 0 else { return nil }
            return width
        }
    }

    /// Optional alignment hint, e.g. `...?a=center`. Returns "left", "center", or "right".
    static func alignment(from reference: String) -> String? {
        guard let components = URLComponents(string: reference) else { return nil }
        return components.queryItems?.first(where: { $0.name == "a" })?.value
    }
}
