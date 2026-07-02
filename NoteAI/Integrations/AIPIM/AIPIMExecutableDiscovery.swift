import Foundation

protocol AIPIMExecutableLocating: Sendable {
    func executableURL(for source: AIPIMSource) -> URL?
}

struct AIPIMExecutableDiscovery: AIPIMExecutableLocating, Sendable {
    let candidateDirectories: [URL]

    init(
        configuredDirectories: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        var directories = configuredDirectories

        if let configuredDirectory = environment["AI_PIM_UTILS_BIN_DIR"], !configuredDirectory.isEmpty {
            directories.append(URL(fileURLWithPath: configuredDirectory, isDirectory: true))
        }

        if let path = environment["PATH"] {
            directories.append(contentsOf: path
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0), isDirectory: true) })
        }

        directories.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        ])

        var seen = Set<String>()
        self.candidateDirectories = directories.filter { directory in
            seen.insert(directory.standardizedFileURL.path).inserted
        }
    }

    func executableURL(for source: AIPIMSource) -> URL? {
        for directory in candidateDirectories {
            let candidate = directory.appendingPathComponent(source.binaryName, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
