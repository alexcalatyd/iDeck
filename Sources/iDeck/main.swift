import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, isFirstRun) = Config.load()
        let requested = CommandLine.arguments.contains("--pair")
        statusBar = StatusBarController(
            store: ConfigStore(config: config),
            showPairingOnLaunch: isFirstRun || requested,
            showSettingsOnLaunch: CommandLine.arguments.contains("--settings")
        )
    }

    /// Volver a abrirla desde Spotlight o el Finder con la app ya corriendo
    /// no hacía nada visible: no hay Dock ni ventanas. Ahora despliega el panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusBar?.presentPairing()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no app switcher entry — menu bar only.
app.setActivationPolicy(.accessory)
app.run()
