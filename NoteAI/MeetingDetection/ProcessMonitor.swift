import AppKit

/// Monitors running processes to find active meeting applications.
enum ProcessMonitor {
    /// Known meeting app bundle identifiers
    private static let meetingBundleIDs: [String] = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.apple.Safari",
    ]

    /// Finds the first running meeting app, preferring Teams over browsers.
    static func findMeetingApp() -> NSRunningApplication? {
        let workspace = NSWorkspace.shared
        return findMeetingApp(in: workspace.runningApplications)
    }

    /// Finds the first meeting app in a provided process snapshot.
    static func findMeetingApp(in runningApps: [NSRunningApplication]) -> NSRunningApplication? {

        // Prefer dedicated meeting apps (Teams) over browsers
        for bundleID in meetingBundleIDs {
            if let app = runningApps.first(where: {
                $0.bundleIdentifier == bundleID && $0.isActive
            }) {
                return app
            }
        }

        // Fall back to any running meeting app (not necessarily active)
        for bundleID in meetingBundleIDs {
            if let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
                return app
            }
        }

        return nil
    }

    /// Checks if any known meeting app is currently running.
    static func isMeetingAppRunning() -> Bool {
        findMeetingApp() != nil
    }

    /// Returns all currently running meeting apps.
    static func allRunningMeetingApps() -> [NSRunningApplication] {
        let workspace = NSWorkspace.shared
        return workspace.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return meetingBundleIDs.contains(bundleID)
        }
    }
}
