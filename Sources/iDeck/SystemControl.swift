import AppKit
import Foundation

/// Everything that actually touches macOS.
enum SystemControl {

    // MARK: - Shell helpers

    @discardableResult
    static func osascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Volume

    /// Delegado en CoreAudio: ver `AudioOutput` para el porqué.
    static func volume() -> Int { AudioOutput.shared.volume() }
    static func isMuted() -> Bool { AudioOutput.shared.isMuted() }
    static func setVolume(_ value: Int) { AudioOutput.shared.setVolume(value) }
    static func setMuted(_ muted: Bool) { AudioOutput.shared.setMuted(muted) }

    // MARK: - Media & brightness (hardware keys)

    /// NX_KEYTYPE constants from IOKit/hidsystem/ev_keymap.h
    enum MediaKey: Int32 {
        case brightnessUp = 2
        case brightnessDown = 3
        case playPause = 16
        case next = 17
        case previous = 18
    }

    /// Posts a system-defined key event. Needs Accessibility permission.
    static func press(_ key: MediaKey) {
        for isDown in [true, false] {
            let state = isDown ? 0x0A00 : 0x0B00
            let data1 = Int((key.rawValue << 16) | Int32(state))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // El diálogo del sistema es fácil de perder; abrimos el panel también.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Apps & system

    static func open(appAt path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    static func toggleDarkMode() {
        osascript("""
        tell application "System Events" to tell appearance preferences
            set dark mode to not dark mode
        end tell
        """)
    }

    /// Sin proceso nuevo: el ajuste vive en el dominio global y se lee de
    /// corrido, que es lo que hace falta para pintar el estado del botón.
    static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    // MARK: - Energía y sesión

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        return true
    }

    static func sleepDisplay() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Bloquear de verdad, no solo apagar la pantalla.
    ///
    /// Lo que había antes era `pmset displaysleepnow`, que apaga el panel pero
    /// no cierra la sesión: si el Mac no pide la contraseña de inmediato, se
    /// desbloquea con mover el ratón. El `CGSession -suspend` de siempre ya no
    /// existe en macOS 26, así que se usa la función de `login.framework` que
    /// es la que invoca el propio menú de Apple, y si un día desaparece queda
    /// el atajo de teclado (que sí necesita Accesibilidad).
    static func lockScreen() {
        typealias LockScreen = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework"
        if let bundle = CFBundleCreate(nil, URL(fileURLWithPath: path) as CFURL) {
            CFBundleLoadExecutable(bundle)
            if let pointer = CFBundleGetFunctionPointerForName(bundle, "SACLockScreenImmediate" as CFString) {
                _ = unsafeBitCast(pointer, to: LockScreen.self)()
                return
            }
        }
        osascript("tell application \"System Events\" to keystroke \"q\" using {command down, control down}")
    }

    static func sleepSystem() {
        run("/usr/bin/pmset", ["sleepnow"])
    }

    /// Reiniciar y apagar pasan por System Events, que es quien avisa a las
    /// apps con documentos sin guardar en vez de llevárselas por delante.
    static func restart() {
        osascript("tell application \"System Events\" to restart")
    }

    static func shutDown() {
        osascript("tell application \"System Events\" to shut down")
    }

    // MARK: - Teclado del sistema

    /// Atajos de macOS que no tienen API: se mandan como pulsaciones.
    /// Necesitan Accesibilidad, igual que las teclas de brillo.
    static func systemShortcut(_ shortcut: Shortcut) {
        osascript(shortcut.script)
    }

    enum Shortcut: String {
        case missionControl
        case spotlight
        case screenshot

        var script: String {
            switch self {
            case .missionControl:
                return "tell application \"System Events\" to key code 126 using {control down}"
            case .spotlight:
                return "tell application \"System Events\" to keystroke space using {command down}"
            case .screenshot:
                return "tell application \"System Events\" to keystroke \"4\" using {command down, shift down}"
            }
        }
    }
}
