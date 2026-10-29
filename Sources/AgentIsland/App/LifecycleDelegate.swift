import AppKit

@MainActor
final class LifecycleDelegate: NSObject, NSApplicationDelegate {
    private var signals: [DispatchSourceSignal] = []
    private static var lockFD: Int32 = -1

    override init() {
        super.init()
        #if AGENTISLAND_ISOLATED_PREVIEW
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentIslandIsolatedPreview", isDirectory: true)
        #else
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland")
        #endif
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.lockFD = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard Self.lockFD >= 0, flock(Self.lockFD, LOCK_EX | LOCK_NB) == 0 else {
            print("Another instance of AgentIsland is already running. Exiting.")
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AgentIsland launched successfully!")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume(); signals.append(source)
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func sleeping() {}
    @objc private func waking() {}
    func applicationWillTerminate(_ notification: Notification) {}
}
