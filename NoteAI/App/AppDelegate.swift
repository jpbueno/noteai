import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let meetingManager = MeetingManager()
    let authManager = GoogleAuthManager()
    let chatManager = ChatManager()
    let ttsService = TextToSpeechService()
    private var mainWindow: NSWindow?
    private var localCaptureHelperServer: LocalCaptureHelperServer?
    private let localCapturePairingPresenter = LocalCapturePairingPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.processInfo.isRunningXCTest else { return }

        chatManager.meetingManager = meetingManager
        APIKeyStore.migrateLegacyKeysFromUserDefaults()
        requestNotificationPermission()
        registerGlobalShortcut()
        // Ensure Dock icon stays the branded NoteAI icon even when launched via swift run.
        if let appIcon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApplication.shared.applicationIconImage = appIcon
        }
        NSApplication.shared.setActivationPolicy(.regular)
        showMainWindow()
        startLocalCaptureHelper()

    }

    func applicationWillTerminate(_ notification: Notification) {
        localCaptureHelperServer?.stop()
        localCaptureHelperServer = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        meetingManager.refreshOnboardingChecklistState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        meetingManager.refreshOnboardingChecklistState()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "noteai" && $0.host == "capture-helper" }) else { return }
        startLocalCaptureHelper()
        showMainWindow()
    }

    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let contentView = RootView(
            meetingManager: meetingManager,
            authManager: authManager,
            chatManager: chatManager,
            ttsService: ttsService
        )
        .frame(minWidth: 900, minHeight: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "NoteAI"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.098, green: 0.098, blue: 0.098, alpha: 1)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard event.clickCount == 2, let w = event.window, w == NSApp.keyWindow else { return event }
            let locationInWindow = event.locationInWindow
            let windowHeight = w.frame.height
            let titleBarZone = windowHeight - locationInWindow.y
            if titleBarZone < 38 {
                w.zoom(nil)
                return nil
            }
            return event
        }

        self.mainWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func registerGlobalShortcut() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                NotificationCenter.default.post(name: .toggleRecording, object: nil)
            }
        }
    }

    private func startLocalCaptureHelper() {
        guard localCaptureHelperServer == nil else { return }

        let router = LocalCaptureHelperRouter(
            statusProvider: LocalCaptureHelperStatusProvider(),
            pairingStore: LocalCaptureHelperPairingStore(),
            captureController: meetingManager,
            pairingPresenter: localCapturePairingPresenter
        )
        let server = LocalCaptureHelperServer(router: router)
        do {
            try server.start()
            localCaptureHelperServer = server
            print("[LocalCaptureHelper] Listening on 127.0.0.1:\(LocalCaptureHelperProtocol.defaultPort)")
        } catch {
            print("[LocalCaptureHelper] Failed to start: \(error)")
        }
    }
}

extension Notification.Name {
    static let toggleRecording = Notification.Name("toggleRecording")
    static let navigateToNote = Notification.Name("navigateToNote")
    static let navigateToSource = Notification.Name("navigateToSource")
    static let toggleChatPanel = Notification.Name("toggleChatPanel")
}

extension ProcessInfo {
    var isRunningXCTest: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Root view that shows either Login or the main app.
struct RootView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var authManager: GoogleAuthManager
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var ttsService: TextToSpeechService

    var body: some View {
        if authManager.isAuthenticated || UserDefaults.standard.bool(forKey: "skippedAuth") {
            MeetingLibraryView(meetingManager: meetingManager, authManager: authManager, chatManager: chatManager, ttsService: ttsService)
        } else {
            LoginView(authManager: authManager)
        }
    }
}
