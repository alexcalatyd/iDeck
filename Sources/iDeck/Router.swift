import AppKit
import Foundation

/// Maps HTTP requests onto SystemControl calls and serves the panel.
struct Router {
    let store: ConfigStore
    let nowPlaying: NowPlayingMonitor
    let hub: EventHub
    /// Se avisa después de cada acción: así el móvil que la ha pedido y
    /// cualquier otro que esté mirando ven el cambio a la vez.
    let broadcaster: () -> Broadcaster?

    private var config: Config { store.config }

    private static let webRoot: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Development: running via `swift run` from the package root.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Web")
    }()

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch request.path {
        case "/", "/index.html":
            return staticFile("index.html")

        case "/api/state":
            guard authorized(request) else { return .json(["error": "unauthorized"], status: 401) }
            return .json(state())

        case "/api/action":
            guard authorized(request) else { return .json(["error": "unauthorized"], status: 401) }
            return perform(request)

        case "/api/events":
            guard authorized(request) else { return .json(["error": "unauthorized"], status: 401) }
            return .eventStream { stream in
                hub.add(stream)
                broadcaster()?.sendNow()
            }

        case "/api/appicon":
            return appIcon(request)

        case "/api/catalog":
            // Lo que se puede añadir con el "+" de Apps.
            guard authorized(request) else { return .json(["error": "unauthorized"], status: 401) }
            return .json(["apps": AppCatalog.all().map { ["name": $0.name, "path": $0.path] }])

        case "/api/artwork":
            // La portada no lleva token: es una imagen, va en una etiqueta
            // <img> y la clave ya es un identificador que no se adivina. Así
            // el navegador la puede cachear de verdad.
            return artwork(request)

        default:
            return staticFile(String(request.path.dropFirst()))
        }
    }

    // MARK: - Auth

    private func authorized(_ request: HTTPRequest) -> Bool {
        let supplied = request.query["t"] ?? request.headers["x-ideck-token"]
        guard let supplied, supplied.count == config.token.count else { return false }
        // Comparación en tiempo constante: el token se adivina byte a byte si
        // el servidor tarda distinto en rechazarlo.
        var difference: UInt8 = 0
        for (a, b) in zip(supplied.utf8, config.token.utf8) { difference |= a ^ b }
        return difference == 0
    }

    // MARK: - State

    /// El mismo estado que contesta `/api/state`, para quien lo necesite sin
    /// pasar por HTTP (el canal de eventos).
    func snapshot() -> [String: Any] { state() }

    private func state() -> [String: Any] {
        var payload: [String: Any] = [
            "volume": AudioOutput.shared.volume(),
            "muted": AudioOutput.shared.isMuted(),
            "dark": SystemControl.isDarkMode,
            "accessibility": SystemControl.hasAccessibility,
            "apps": config.controls.apps ? config.installedApps.map { ["name": $0.name, "path": $0.path] } : [],
            "controls": config.controls.asJSON,
            "ui": config.ui.asJSON,
            "system": SystemInfo.snapshot(),
            // El panel solo avisa del permiso cuando lo que suena de verdad
            // lo necesita: con Spotify delante no hace falta pedir nada.
            "needsAccessibility": nowPlaying.needsAccessibility,
            // Navegadores abiertos que no pueden decir lo que suena. El panel
            // lo explica en vez de dejar el hueco sin motivo.
            "blockedBrowsers": nowPlaying.blockedBrowsers,
        ]

        // `nil` significa "esta pantalla no sabe decir su nivel": el panel
        // cambia el slider por los botones de subir y bajar.
        if let level = Brightness.level() {
            payload["brightness"] = level
        }

        if let track = nowPlaying.current {
            var media: [String: Any] = [
                "title": track.title,
                "artist": track.artist,
                "album": track.album,
                "source": track.source,
                "kind": track.kind.rawValue,
                "playing": track.playing,
                "duration": track.duration,
                "position": track.position,
                "canSkip": track.canSkip,
                // Decide los controles que enseña el panel: un vídeo de un
                // navegador lleva ±10 s; una canción, anterior y siguiente.
                "canSeek": nowPlaying.canSeek,
            ]
            if let key = track.artworkKey {
                media["art"] = "/api/artwork?k=" + key
            }
            payload["track"] = media
        }
        return payload
    }

    // MARK: - Artwork

    private func artwork(_ request: HTTPRequest) -> HTTPResponse {
        guard let key = request.query["k"], let (data, type) = ArtworkStore.shared.data(for: key) else {
            return .text("Not found", status: 404)
        }
        return HTTPResponse(
            status: 200,
            contentType: type,
            body: data,
            // La clave cambia con la imagen, así que esta nunca caduca.
            extraHeaders: ["Cache-Control": "public, max-age=31536000, immutable"]
        )
    }

    /// Solo se sirven iconos de las apps que están en la lista: la ruta viene
    /// de la URL y no se puede dejar que pida cualquier fichero del disco.
    private func appIcon(_ request: HTTPRequest) -> HTTPResponse {
        // Las de la lista, sin token (van en <img> y se cachean); las del
        // catálogo, solo con token: son las del selector del "+".
        guard let path = request.query["p"],
              config.installedApps.contains(where: { $0.path == path })
                || (authorized(request) && AppCatalog.contains(path)),
              let png = AppIcons.png(forAppAt: path) else {
            return .text("Not found", status: 404)
        }
        return HTTPResponse(
            status: 200,
            contentType: "image/png",
            body: png,
            extraHeaders: ["Cache-Control": "public, max-age=86400"]
        )
    }

    // MARK: - Actions

    private func perform(_ request: HTTPRequest) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let id = json["id"] as? String else {
            return .json(["error": "missing id"], status: 400)
        }

        let controls = config.controls

        switch id {
        case "volume.set":
            guard controls.volume else { return disabled() }
            guard let value = number(json["value"]) else { return .json(["error": "missing value"], status: 400) }
            AudioOutput.shared.setVolume(value)

        case "volume.mute":
            guard controls.volume else { return disabled() }
            AudioOutput.shared.toggleMuted()

        case "brightness.set":
            guard controls.brightness else { return disabled() }
            guard let value = number(json["value"]) else { return .json(["error": "missing value"], status: 400) }
            // Sin DisplayServices no hay nivel absoluto; las teclas al menos
            // mueven la pantalla en la dirección correcta.
            if !Brightness.setLevel(value) {
                SystemControl.press(value >= (Brightness.level() ?? 50) ? .brightnessUp : .brightnessDown)
            }

        case "brightness.up", "brightness.down":
            guard controls.brightness else { return disabled() }
            let up = id.hasSuffix("up")
            if !Brightness.nudge(up: up) {
                SystemControl.press(up ? .brightnessUp : .brightnessDown)
            }

        case "media.playpause":
            guard controls.music else { return disabled() }
            nowPlaying.transport(.playPause)

        case "media.next":
            guard controls.music else { return disabled() }
            nowPlaying.transport(.next)

        case "media.previous":
            guard controls.music else { return disabled() }
            nowPlaying.transport(.previous)

        case "media.seek":
            guard controls.music else { return disabled() }
            guard let value = number(json["value"]) else { return .json(["error": "missing value"], status: 400) }
            // Los saltos grandes son de un dedo resbalado, no de un botón.
            nowPlaying.seek(delta: Double(max(-600, min(600, value))))

        case "media.position":
            guard controls.music else { return disabled() }
            guard let value = number(json["value"]) else { return .json(["error": "missing value"], status: 400) }
            nowPlaying.seek(to: Double(max(0, value)))

        case "appearance.toggle":
            guard controls.appearance else { return disabled() }
            SystemControl.toggleDarkMode()

        case "display.sleep":
            guard controls.displaySleep else { return disabled() }
            SystemControl.sleepDisplay()

        case "system.lock":
            guard controls.lock else { return disabled() }
            SystemControl.lockScreen()

        case "system.sleep":
            guard controls.sleep else { return disabled() }
            SystemControl.sleepSystem()

        case "system.restart":
            guard controls.restart else { return disabled() }
            SystemControl.restart()

        case "system.shutdown":
            guard controls.shutdown else { return disabled() }
            SystemControl.shutDown()

        case "shortcut.missionControl", "shortcut.spotlight", "shortcut.screenshot":
            guard controls.shortcuts else { return disabled() }
            let name = String(id.dropFirst("shortcut.".count))
            guard let shortcut = SystemControl.Shortcut(rawValue: name) else {
                return .json(["error": "unknown shortcut"], status: 400)
            }
            SystemControl.systemShortcut(shortcut)

        case "app.open":
            guard controls.apps else { return disabled() }
            guard let path = json["value"] as? String,
                  config.installedApps.contains(where: { $0.path == path }) else {
                return .json(["error": "unknown app"], status: 400)
            }
            SystemControl.open(appAt: path)

        case "apps.add":
            guard let path = json["value"] as? String, AppCatalog.contains(path),
                  let entry = AppCatalog.all().first(where: { $0.path == path }) else {
                return .json(["error": "unknown app"], status: 400)
            }
            store.update { config in
                if !config.apps.contains(where: { $0.path == path }) { config.apps.append(entry) }
            }

        case "apps.remove":
            // Varias de golpe: el "−" de Apps manda todas las marcadas al
            // pulsar Listo.
            guard let paths = json["value"] as? [String] else {
                return .json(["error": "missing value"], status: 400)
            }
            let gone = Set(paths)
            store.update { config in config.apps.removeAll { gone.contains($0.path) } }

        case "apps.reorder":
            // El orden que se ha dejado al arrastrar en el panel. Lo que no
            // venga en la lista (una app añadida desde otro sitio mientras
            // tanto) se queda detrás, en el orden que tenía.
            guard let paths = json["value"] as? [String] else {
                return .json(["error": "missing value"], status: 400)
            }
            store.update { config in
                let rank = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                let indexed = config.apps.enumerated().map { ($0, $1) }
                config.apps = indexed.sorted { a, b in
                    (rank[a.1.path] ?? paths.count + a.0) < (rank[b.1.path] ?? paths.count + b.0)
                }.map(\.1)
            }

        case "prefs.set":
            guard let patch = json["value"] as? [String: Any] else {
                return .json(["error": "missing value"], status: 400)
            }
            apply(prefs: patch)

        case "accessibility.request":
            DispatchQueue.main.async { SystemControl.requestAccessibility() }

        default:
            return .json(["error": "unknown action \(id)"], status: 400)
        }

        // Volumen y brillo responden al instante; lo que suena tarda un poco
        // en enterarse, y de eso ya se encarga `refreshSoon` del monitor.
        broadcaster()?.poke()
        return .json(state())
    }

    /// El JSON del móvil puede traer el número como entero o como doble según
    /// cómo lo haya serializado.
    private func number(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double.rounded()) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Los ajustes de apariencia se guardan en el Mac. Solo se tocan los
    /// campos que vengan, para que el panel pueda mandar uno suelto.
    private func apply(prefs: [String: Any]) {
        store.update { config in
            var ui = config.ui
            if let theme = prefs["theme"] as? String { ui.theme = theme }
            if let glass = prefs["glass"] as? String { ui.glass = glass }
            if let haptics = prefs["haptics"] as? Bool { ui.haptics = haptics }
            if let animations = prefs["animations"] as? Bool { ui.animations = animations }
            if let lang = prefs["lang"] as? String { ui.lang = lang }
            if let deck = prefs["deck"] as? [String] { ui.deck = deck }
            if let hidden = prefs["hidden"] as? [String] { ui.hidden = Array(Set(hidden)).sorted() }
            ui.sanitize()
            config.ui = ui

            // Qué controles existen lo decide el Mac, pero poder apagar un
            // botón desde el propio móvil es justo lo que se pedía de Ajustes.
            if let flags = prefs["controls"] as? [String: Bool] {
                var controls = config.controls
                for (name, value) in flags {
                    switch name {
                    case "music": controls.music = value
                    case "apps": controls.apps = value
                    case "brightness": controls.brightness = value
                    case "volume": controls.volume = value
                    case "appearance": controls.appearance = value
                    case "displaySleep": controls.displaySleep = value
                    case "lock": controls.lock = value
                    case "sleep": controls.sleep = value
                    case "restart": controls.restart = value
                    case "shutdown": controls.shutdown = value
                    case "shortcuts": controls.shortcuts = value
                    default: break
                    }
                }
                config.controls = controls
            }
        }
    }

    /// Un control apagado en los ajustes no se ejecuta aunque llegue la
    /// petición: el panel puede estar abierto desde antes del cambio.
    private func disabled() -> HTTPResponse {
        .json(["error": "control disabled"], status: 403)
    }

    // MARK: - Static files

    /// Sirve cualquier fichero del panel. Antes había un `case` por fichero y
    /// añadir uno nuevo se olvidaba; ahora basta con dejarlo en `Web/`.
    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/manifest+json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "woff2": "font/woff2",
    ]

    private func staticFile(_ name: String) -> HTTPResponse {
        // Nada de subir por el árbol desde la URL.
        guard !name.isEmpty, !name.contains(".."), !name.hasPrefix("/") else {
            return .text("Not found", status: 404)
        }
        let url = Self.webRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            return .text("Not found", status: 404)
        }
        let type = Self.contentTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
        return HTTPResponse(status: 200, contentType: type, body: data)
    }
}
