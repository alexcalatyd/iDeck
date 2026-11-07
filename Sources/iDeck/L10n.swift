import Foundation

/// Textos en español e inglés. Por defecto sigue al sistema, pero se puede
/// fijar desde el propio panel.
enum L10n {
    enum Language: String {
        case auto
        case spanish = "es"
        case english = "en"
    }

    static var current: Language = .auto

    static var isSpanish: Bool {
        switch current {
        case .spanish: return true
        case .english: return false
        case .auto: return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("es")
        }
    }

    static func t(_ spanish: String, _ english: String) -> String {
        isSpanish ? spanish : english
    }

    static var scan: String { t("Escanea con la cámara del móvil", "Scan with your phone camera") }
    static var reveal: String { t("Mostrar QR", "Show QR") }
    static var hidden: String { t("Oculto: cualquiera que lo vea entra", "Hidden: anyone who sees it gets in") }
    static var copyLink: String { t("Copiar enlace", "Copy link") }
    static var copied: String { t("Copiado", "Copied") }
    static var openHere: String { t("Abrir aquí", "Open here") }
    static var quit: String { t("Salir", "Quit") }
    static var settings: String { t("Ajustes", "Settings") }
    static var running: String { t("Activo", "Running") }
    static var stopped: String { t("Detenido", "Stopped") }
    static var noNetwork: String { t("Sin red", "No network") }
    /// El brillo y el volumen ya no lo necesitan: solo los atajos del
    /// sistema y los controles de música de un navegador.
    static var permissionNeeded: String {
        t("Los atajos necesitan Accesibilidad", "Shortcuts need Accessibility")
    }
    static var grant: String { t("Conceder", "Grant") }

    // Ventana de ajustes
    static var settingsTitle: String { t("Ajustes de iDeck", "iDeck Settings") }
    static var connection: String { t("Conexión", "Connection") }
    static var portLabel: String { t("Puerto", "Port") }
    static var tokenLabel: String { t("Token de acceso", "Access token") }
    static var regenerate: String { t("Regenerar", "Regenerate") }
    static var regenerateWarning: String {
        t("Se perderá el emparejamiento: habrá que volver a escanear el QR en cada móvil.",
          "This breaks pairing: every phone will have to scan the QR again.")
    }
    static var regenerateConfirm: String { t("¿Regenerar el token?", "Regenerate the token?") }
    static var cancel: String { t("Cancelar", "Cancel") }
    static var panels: String { t("En el panel del móvil", "On the phone panel") }
    static var systemTiles: String { t("Sistema", "System") }
    static var musicPanel: String { t("Ahora suena", "Now playing") }
    static var appsPanel: String { t("Apps", "Apps") }
    static var volumeTile: String { t("Volumen", "Volume") }
    static var brightnessTile: String { t("Brillo", "Brightness") }
    static var appearanceTile: String { t("Apariencia del Mac", "Mac appearance") }
    static var displaySleepTile: String { t("Apagar pantalla", "Turn off display") }
    static var lockTile: String { t("Bloquear", "Lock") }
    static var sleepTile: String { t("Reposo", "Sleep") }
    static var shortcutsTile: String { t("Atajos del sistema", "System shortcuts") }
    static var restartTile: String { t("Reiniciar", "Restart") }
    static var shutdownTile: String { t("Apagar", "Shut down") }
    static var dangerNote: String {
        t("Reiniciar y apagar se piden con confirmación desde el móvil.",
          "Restart and shut down ask for confirmation on the phone.")
    }
    static var appsHeading: String { t("Apps del panel", "Panel apps") }
    static var addApp: String { t("Añadir", "Add") }
    static var removeApp: String { t("Quitar", "Remove") }
    static var moveUp: String { t("Subir", "Move up") }
    static var moveDown: String { t("Bajar", "Move down") }
    static var noApps: String { t("Ninguna app todavía", "No apps yet") }
    static var portTaken: String { t("Puerto no válido o en uso", "Invalid port or already in use") }
    static var revealJSON: String { t("Ver config.json", "Show config.json") }
    static var advanced: String { t("Opciones avanzadas", "Advanced options") }
    static var missingApp: String { t("Ya no está en el Mac", "No longer on this Mac") }
    static var cleanMissing: String { t("Quitar las que faltan", "Remove missing") }
}
