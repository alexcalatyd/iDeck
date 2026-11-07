import Foundation

/// Ajustes persistidos. Viven en ~/Library/Application Support/iDeck/config.json
struct Config: Codable {
    var port: UInt16
    var token: String
    var apps: [AppEntry]
    /// "es", "en", o ausente para seguir al sistema.
    var language: String?
    var controls: Controls
    /// Apariencia y comportamiento del panel. Se guarda en el Mac y no en el
    /// móvil para que cualquier dispositivo que se empareje herede el mismo
    /// mando en vez de empezar de cero.
    var ui: Appearance

    struct AppEntry: Codable, Equatable {
        var name: String
        var path: String

        /// Una app desinstalada deja su entrada apuntando a la nada.
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    /// Lo que se manda al móvil: solo lo que se puede abrir de verdad.
    var installedApps: [AppEntry] { apps.filter(\.exists) }

    /// Qué aparece en el panel del móvil. Cada campo apaga el control tanto
    /// en la interfaz como en el servidor: una petición de algo apagado se
    /// rechaza aunque el panel llevara abierto desde antes del cambio.
    struct Controls: Codable {
        var music = true
        var apps = true
        var brightness = true
        var volume = true
        var appearance = true
        var displaySleep = true
        var lock = true
        var sleep = true
        /// Apagar y reiniciar van apagados de serie: son irreversibles y no
        /// es lo que se espera al emparejar un mando de música.
        var restart = false
        var shutdown = false
        var shortcuts = true

        init() {}

        /// Tolerante con los campos que falten: un config.json viejo sigue
        /// abriendo y simplemente estrena los ajustes nuevos.
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            func flag(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
                try box.decodeIfPresent(Bool.self, forKey: key) ?? fallback
            }
            music = try flag(.music, true)
            apps = try flag(.apps, true)
            brightness = try flag(.brightness, true)
            volume = try flag(.volume, true)
            appearance = try flag(.appearance, true)
            displaySleep = try flag(.displaySleep, true)
            lock = try flag(.lock, true)
            sleep = try flag(.sleep, true)
            restart = try flag(.restart, false)
            shutdown = try flag(.shutdown, false)
            shortcuts = try flag(.shortcuts, true)
        }

        var asJSON: [String: Any] {
            [
                "music": music, "apps": apps,
                "brightness": brightness, "volume": volume,
                "appearance": appearance, "displaySleep": displaySleep,
                "lock": lock, "sleep": sleep,
                "restart": restart, "shutdown": shutdown,
                "shortcuts": shortcuts,
            ]
        }
    }

    /// Lo que el usuario cambia desde el propio panel.
    struct Appearance: Codable {
        /// "dark", "light" o "auto".
        var theme = "dark"
        var haptics = true
        var animations = true
        /// "off", "subtle" o "full": cuánto cristal se pinta.
        var glass = "full"
        /// "es", "en" o "auto": el idioma del panel del móvil. Se guarda en
        /// el Mac para que cualquier dispositivo emparejado lo herede.
        var lang = "auto"
        /// Orden y presencia de los botones de la rejilla. Son identificadores
        /// que solo entiende el panel; el servidor no decide con ellos, solo
        /// los guarda. Vacío significa "los que haya, en el orden de serie".
        var deck: [String] = []
        /// Mandos que el usuario ha quitado desde el panel ("−" de Mando).
        /// Va por boton y no por interruptor: los tres atajos comparten
        /// interruptor y quitar uno no tiene por que quitar los otros dos.
        var hidden: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            theme = try box.decodeIfPresent(String.self, forKey: .theme) ?? "dark"
            haptics = try box.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
            animations = try box.decodeIfPresent(Bool.self, forKey: .animations) ?? true
            glass = try box.decodeIfPresent(String.self, forKey: .glass) ?? "full"
            lang = try box.decodeIfPresent(String.self, forKey: .lang) ?? "auto"
            deck = try box.decodeIfPresent([String].self, forKey: .deck) ?? []
            hidden = try box.decodeIfPresent([String].self, forKey: .hidden) ?? []
            sanitize()
        }

        /// El panel manda estos valores por la red: no se guarda lo que no se
        /// entiende.
        mutating func sanitize() {
            if !["dark", "light", "auto"].contains(theme) { theme = "dark" }
            if !["off", "subtle", "full"].contains(glass) { glass = "full" }
            if !["auto", "es", "en"].contains(lang) { lang = "auto" }
            // Un identificador raro no rompe nada, pero una lista infinita sí.
            if deck.count > 64 { deck = Array(deck.prefix(64)) }
            if hidden.count > 64 { hidden = Array(hidden.prefix(64)) }
        }

        var asJSON: [String: Any] {
            [
                "theme": theme, "haptics": haptics,
                "animations": animations, "glass": glass, "lang": lang,
                "deck": deck, "hidden": hidden,
            ]
        }
    }

    init(
        port: UInt16 = 8787,
        token: String,
        apps: [AppEntry],
        language: String? = nil,
        controls: Controls = Controls(),
        ui: Appearance = Appearance()
    ) {
        self.port = port
        self.token = token
        self.apps = apps
        self.language = language
        self.controls = controls
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        port = try box.decodeIfPresent(UInt16.self, forKey: .port) ?? 8787
        token = try box.decodeIfPresent(String.self, forKey: .token) ?? Config.randomToken()
        apps = try box.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
        language = try box.decodeIfPresent(String.self, forKey: .language)
        controls = try box.decodeIfPresent(Controls.self, forKey: .controls) ?? Controls()
        ui = try box.decodeIfPresent(Appearance.self, forKey: .ui) ?? Appearance()
    }

    // MARK: - Disco

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iDeck", isDirectory: true)
    }()

    static let fileURL = directory.appendingPathComponent("config.json")

    /// `isFirstRun` indica que acabamos de crear la configuración, para
    /// mostrar el emparejamiento sin que haya que buscarlo.
    static func load() -> (config: Config, isFirstRun: Bool) {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Config.self, from: data) {
            return (stored, false)
        }
        let fresh = Config(token: randomToken(), apps: discoverApps())
        fresh.save()
        return (fresh, true)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.fileURL)
    }

    static func randomToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    /// Las apps instaladas de una lista pensada para llenar la primera
    /// pagina de Apps (4 x 6), para que el primer arranque ya sirva de algo.
    /// Lo que no este instalado se salta.
    private static func discoverApps() -> [AppEntry] {
        let candidates = [
            "Finder", "Safari", "Mail", "Messages", "Calendar", "Notes",
            "Reminders", "Photos", "Music", "Spotify", "WhatsApp", "Ghostty",
            "Visual Studio Code", "Claude", "ChatGPT", "Brave Browser", "Google Chrome",
            "Figma", "Canva", "Notion", "Discord", "Slack", "IntelliJ IDEA",
            "TablePlus", "VLC", "Preview", "System Settings",
        ]
        let roots = [
            "/Applications", "/System/Applications", "/System/Library/CoreServices",
            NSHomeDirectory() + "/Applications",
        ]
        var found: [AppEntry] = []
        for name in candidates {
            for root in roots {
                let path = "\(root)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    found.append(AppEntry(name: name, path: path))
                    break
                }
            }
            if found.count == 24 { break }
        }
        return found
    }
}
