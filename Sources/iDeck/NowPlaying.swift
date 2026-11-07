import AppKit
import Foundation

/// Lo que suena ahora mismo en el Mac, venga de donde venga.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    /// Lo que se le enseña al usuario: "Spotify", "Brave Browser"...
    var source: String
    /// Para el icono y para saber a quién mandar los controles.
    var kind: Kind
    var playing: Bool
    /// Clave en `ArtworkStore`, ya descargada, o `nil` si no hay portada.
    var artworkKey: String?
    /// Segundos. `0` cuando la fuente no lo dice.
    var duration: Double
    var position: Double
    /// Un navegador no siempre tiene anterior/siguiente; Spotify siempre.
    var canSkip: Bool

    enum Kind: String, Equatable {
        case spotify
        case music
        case browser
    }
}

/// De dónde se saca, y por qué así.
///
/// Lo natural sería `MediaRemote`, el framework privado que alimenta el
/// widget «Ahora suena» del sistema y que lo sabe todo de cualquier app. Desde
/// macOS 15.4 Apple le puso un control de entitlement: las funciones siguen
/// ahí y el callback se dispara, pero llega un diccionario vacío a cualquier
/// app que no sea de Apple. Comprobado en macOS 26.
///
/// Así que no hay una única puerta y hay que preguntar fuente por fuente:
///
/// - Spotify y Música tienen diccionario de AppleScript: título, artista,
///   portada, posición y estado. No piden Accesibilidad.
/// - Los navegadores no lo tienen, pero sí pueden ejecutar JavaScript por
///   AppleScript, y las páginas que reproducen algo rellenan
///   `navigator.mediaSession` (YouTube lo hace, y casi cualquier reproductor
///   serio). De ahí salen los mismos datos, portada incluida.
///
/// El coste de preguntar a los navegadores es alto (ejecuta un script en cada
/// pestaña), así que se hace poco y en segundo plano: el panel lee siempre de
/// la caché y el móvil recibe un aviso cuando cambia.
final class NowPlayingMonitor {

    /// Se dispara cuando la foto de lo que suena cambia de verdad.
    var onChange: ((NowPlaying?) -> Void)?

    private let queue = DispatchQueue(label: "ideck.nowplaying")
    private let lock = NSLock()

    private var snapshot: NowPlaying?
    /// A quién mandar play/pausa. Se recuerda para que pausar no cambie de
    /// fuente de golpe solo porque haya dejado de sonar.
    private var pinned: NowPlaying.Kind?
    private var pinnedBrowser: BrowserTab?
    private var timer: DispatchSourceTimer?
    private var lastBrowserScan = Date.distantPast
    private var musicArtworkTrack: String?
    /// Si un navegador puede ejecutar JavaScript por AppleScript, y si no,
    /// por que. Se consulta de vez en cuando, no en cada vuelta.
    private var browserStatus: [String: BrowserStatus] = [:]

    struct BrowserStatus: Equatable {
        var name: String
        /// nil = todo bien. Si no, "scripting" o "permission".
        var blocked: String?
        var checkedAt: Date
    }

    /// Navegadores a los que preguntar, por orden. La familia Chromium usa
    /// `execute … javascript`; Safari usa `do JavaScript … in tab`.
    private static let browsers: [Browser] = [
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", family: .chromium),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", family: .chromium),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", family: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", family: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", family: .chromium),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", family: .chromium),
        Browser(name: "Safari", bundleID: "com.apple.Safari", family: .safari),
    ]

    private struct Browser {
        var name: String
        var bundleID: String
        var family: Family
        enum Family { case chromium, safari }
    }

    private struct BrowserTab: Equatable {
        var browser: String
        var window: Int
        var tab: Int
    }

    // MARK: - Ciclo

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var current: NowPlaying? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Tras pulsar play o siguiente, el estado real tarda un instante en
    /// cambiar. Sin esto el botón se quedaría un segundo entero mintiendo.
    func refreshSoon() {
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
        queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var candidates: [NowPlaying] = []
        if running.contains("com.spotify.client"), let track = readSpotify() { candidates.append(track) }
        if running.contains("com.apple.Music"), let track = readMusic() { candidates.append(track) }

        // Preguntar a los navegadores cuesta caro. Si ya hay algo sonando en
        // un reproductor de verdad, no hace falta molestarlos.
        let somethingPlaying = candidates.contains(where: \.playing)
        if !somethingPlaying, let track = readBrowsers(running: running) {
            candidates.append(track)
        } else if somethingPlaying {
            // Aun asi hay que saber si podrian contestar: Ajustes explica por
            // que un navegador no sale, y esa respuesta no puede depender de
            // que ahora mismo suene otra cosa. La caché lo deja en una
            // consulta cada 45 s.
            for browser in Self.browsers where running.contains(browser.bundleID) {
                _ = status(of: browser)
            }
        }

        publish(choose(from: candidates))
    }

    /// Manda el que esté sonando. Si no suena ninguno, se queda el que ya
    /// estaba, para que pausar no borre la pantalla.
    private func choose(from candidates: [NowPlaying]) -> NowPlaying? {
        if let pinned, let held = candidates.first(where: { $0.kind == pinned && $0.playing }) { return held }
        if let playing = candidates.first(where: \.playing) { return playing }
        if let pinned, let held = candidates.first(where: { $0.kind == pinned }) { return held }
        return candidates.first
    }

    private func publish(_ next: NowPlaying?) {
        lock.lock()
        let changed = next != snapshot
        snapshot = next
        if let next { pinned = next.kind }
        lock.unlock()
        if changed { onChange?(next) }
    }

    // MARK: - Spotify

    private func readSpotify() -> NowPlaying? {
        let script = """
        tell application "Spotify"
            if player state is stopped then return ""
            set tr to current track
            return (name of tr) & "\\t" & (artist of tr) & "\\t" & (album of tr) & "\\t" \
                & (player state as text) & "\\t" & (player position as text) & "\\t" \
                & ((duration of tr) as text) & "\\t" & (artwork url of tr) & "\\t" & (id of tr)
        end tell
        """
        guard let fields = SystemControl.osascript(script)?.components(separatedBy: "\t"), fields.count >= 8 else { return nil }

        var track = NowPlaying(
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            source: "Spotify",
            kind: .spotify,
            playing: fields[3] == "playing",
            artworkKey: nil,
            // Spotify da la duración en milisegundos; Música en segundos.
            duration: (Self.number(fields[5]) ?? 0) / 1000,
            position: Self.number(fields[4]) ?? 0,
            canSkip: true
        )
        track.artworkKey = remoteArtwork(urlString: fields[6], identity: fields[7])
        return track
    }

    // MARK: - Música

    private func readMusic() -> NowPlaying? {
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            set tr to current track
            return (name of tr) & "\\t" & (artist of tr) & "\\t" & (album of tr) & "\\t" \
                & (player state as text) & "\\t" & (player position as text) & "\\t" \
                & ((duration of tr) as text) & "\\t" & ((database id of tr) as text)
        end tell
        """
        guard let fields = SystemControl.osascript(script)?.components(separatedBy: "\t"), fields.count >= 7 else { return nil }

        let identity = "music:" + fields[6]
        return NowPlaying(
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            source: "Música",
            kind: .music,
            playing: fields[3] == "playing",
            artworkKey: musicArtwork(identity: identity),
            duration: Self.number(fields[5]) ?? 0,
            position: Self.number(fields[4]) ?? 0,
            canSkip: true
        )
    }

    /// Música no da una URL: da los bytes. Se piden una sola vez por pista,
    /// porque sacar una imagen por AppleScript no es precisamente rápido.
    private func musicArtwork(identity: String) -> String? {
        let key = ArtworkStore.key(for: identity)
        if ArtworkStore.shared.has(key) { return key }
        guard musicArtworkTrack != identity else { return nil }
        musicArtworkTrack = identity

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ideck-art-\(key)")
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            if (count of artworks of current track) is 0 then return ""
            set bytes to raw data of artwork 1 of current track
        end tell
        set target to open for access (POSIX file "\(file.path)") with write permission
        set eof target to 0
        write bytes to target
        close access target
        return "ok"
        """
        queue.async { [weak self] in
            guard SystemControl.osascript(script) == "ok",
                  let data = try? Data(contentsOf: file) else { return }
            try? FileManager.default.removeItem(at: file)
            ArtworkStore.shared.store(data: data, key: key, contentType: "image/jpeg") {
                self?.refresh()
            }
        }
        return nil
    }

    private func remoteArtwork(urlString: String, identity: String) -> String? {
        guard !urlString.isEmpty, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        let key = ArtworkStore.key(for: identity.isEmpty ? urlString : identity)
        if ArtworkStore.shared.has(key) { return key }
        ArtworkStore.shared.fetch(url: url, key: key) { [weak self] in self?.queue.async { self?.refresh() } }
        return nil
    }

    // MARK: - Navegadores

    /// Lo que se ejecuta dentro de la página. Busca el `<video>` o `<audio>`
    /// que de verdad está sonando y lo completa con `mediaSession`, que es de
    /// donde salen el título, el canal y la portada buenos.
    private static let probe = """
    (function(){var b=null,e=document.querySelectorAll('video,audio');\
    for(var i=0;i<e.length;i++){var x=e[i];if(x.readyState<1)continue;\
    if(!x.paused&&!x.ended){b=x;break}if(!b&&x.currentTime>0)b=x}\
    var s=navigator.mediaSession,m=s&&s.metadata;if(!b&&!m)return '';\
    if(!m&&b&&(b.muted||!(b.duration>5)))return '';\
    function abs(u){if(!u)return '';try{return new URL(u,location.href).href}catch(_){return ''}}\
    function meta(q){var n=document.querySelector(q);return n?abs(n.content||n.href):''}\
    var a='';\
    if(m&&m.artwork&&m.artwork.length){var k=m.artwork[m.artwork.length-1];a=abs(k&&k.src)}\
    if(!a&&b&&b.poster)a=abs(b.poster);\
    if(!a)a=meta('meta[property="og:image"]')||meta('meta[name="twitter:image"]');\
    if(!a)a=meta('link[rel="apple-touch-icon"]')||meta('link[rel="icon"][sizes]');\
    var p=b?(!b.paused&&!b.ended):(s&&s.playbackState==='playing');\
    return JSON.stringify({t:(m&&m.title)||'',r:(m&&m.artist)||'',l:(m&&m.album)||'',\
    a:a,p:!!p,d:(b&&isFinite(b.duration))?b.duration:0,c:b?b.currentTime:0,h:document.title||''})})()
    """

    /// Por que un navegador puede no contestar.
    ///
    /// Chromium trae apagado "Permitir JavaScript desde Eventos de Apple" y
    /// no lo conserva entre arranques, asi que esto no es un caso raro: es
    /// lo normal hasta que el usuario lo enciende. Da el error 12. Si falla
    /// por otra cosa con una ventana abierta, lo habitual es que falte el
    /// permiso de Automatizacion.
    private func status(of browser: Browser) -> BrowserStatus {
        lock.lock()
        let cached = browserStatus[browser.name]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.checkedAt) < 45 { return cached }
        let call: String
        switch browser.family {
        case .chromium: call = "execute active tab of window 1 javascript \"1\""
        case .safari: call = "do JavaScript \"1\" in tab 1 of window 1"
        }
        let script = """
        with timeout of 5 seconds
            tell application "\(browser.name)"
                if (count of windows) is 0 then return "idle"
                try
                    set probe to \(call)
                    return "ok"
                on error errorText number errorNumber
                    return "err:" & errorNumber
                end try
            end tell
        end timeout
        """
        let answer = SystemControl.osascript(script) ?? "err:0"
        var blocked: String?
        if answer.hasPrefix("err:") {
            // -1743 es "el usuario no ha concedido Automatizacion".
            blocked = answer.contains("-1743") ? "permission" : "scripting"
        }
        let fresh = BrowserStatus(name: browser.name, blocked: blocked, checkedAt: Date())
        lock.lock()
        browserStatus[browser.name] = fresh
        lock.unlock()
        return fresh
    }

    /// Lo que el panel enseña para explicar un hueco: navegadores abiertos
    /// que no pueden contestar y por que.
    var blockedBrowsers: [[String: Any]] {
        lock.lock()
        let statuses = browserStatus.values.filter { $0.blocked != nil }
        lock.unlock()
        return statuses
            .sorted { $0.name < $1.name }
            .map { ["name": $0.name, "reason": $0.blocked ?? ""] }
    }

    private func readBrowsers(running: Set<String>) -> NowPlaying? {
        // La pestaña que ganó la última vez se pregunta siempre: es una sola
        // llamada y acierta mientras no se cambie de vídeo.
        lock.lock()
        let pinnedTab = pinnedBrowser
        lock.unlock()
        if let tab = pinnedTab,
           let browser = Self.browsers.first(where: { $0.name == tab.browser }),
           running.contains(browser.bundleID),
           status(of: browser).blocked == nil,
           let track = readBrowserTab(browser, window: tab.window, tab: tab.tab) {
            return track
        }

        // El barrido completo sí es caro, así que va con el freno puesto.
        guard Date().timeIntervalSince(lastBrowserScan) > 3 else { return nil }
        lastBrowserScan = Date()

        for browser in Self.browsers where running.contains(browser.bundleID) {
            guard status(of: browser).blocked == nil else { continue }
            if let found = scan(browser) { return found }
        }
        lock.lock()
        pinnedBrowser = nil
        lock.unlock()
        return nil
    }

    private func readBrowserTab(_ browser: Browser, window: Int, tab: Int) -> NowPlaying? {
        let call: String
        switch browser.family {
        case .chromium:
            call = "execute tab \(tab) of window \(window) javascript \"\(Self.escaped(Self.probe))\""
        case .safari:
            call = "do JavaScript \"\(Self.escaped(Self.probe))\" in tab \(tab) of window \(window)"
        }
        let script = """
        with timeout of 5 seconds
            tell application "\(browser.name)"
                try
                    return \(call)
                on error
                    return ""
                end try
            end tell
        end timeout
        """
        guard let raw = SystemControl.osascript(script), !raw.isEmpty else { return nil }
        return decode(raw, browser: browser, window: window, tab: tab)
    }

    private func scan(_ browser: Browser) -> NowPlaying? {
        let call: String
        switch browser.family {
        case .chromium:
            call = "execute tab t of window w javascript theProbe"
        case .safari:
            call = "do JavaScript theProbe in tab t of window w"
        }
        let script = """
        with timeout of 20 seconds
            tell application "\(browser.name)"
                set theProbe to "\(Self.escaped(Self.probe))"
                set out to ""
                repeat with w from 1 to (count of windows)
                    try
                        repeat with t from 1 to (count of tabs of window w)
                            try
                                set r to \(call)
                                if r is not missing value and (r as text) is not "" then
                                    set out to out & w & ":" & t & "|" & r & linefeed
                                end if
                            end try
                        end repeat
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
        guard let raw = SystemControl.osascript(script), !raw.isEmpty else { return nil }

        var fallback: NowPlaying?
        for line in raw.components(separatedBy: "\n") where line.contains("|") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let coordinates = parts[0].split(separator: ":").compactMap { Int($0) }
            guard coordinates.count == 2 else { continue }
            guard let track = decode(parts[1], browser: browser, window: coordinates[0], tab: coordinates[1]) else { continue }
            if track.playing { return track }
            if fallback == nil { fallback = track }
        }
        return fallback
    }

    private func decode(_ raw: String, browser: Browser, window: Int, tab: Int) -> NowPlaying? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let metadataTitle = (json["t"] as? String) ?? ""
        let pageTitle = (json["h"] as? String) ?? ""
        let title = metadataTitle.isEmpty ? Self.tidy(pageTitle, browser: browser.name) : metadataTitle
        guard !title.isEmpty else { return nil }

        let playing = (json["p"] as? Bool) ?? false
        if playing {
            lock.lock()
            pinnedBrowser = BrowserTab(browser: browser.name, window: window, tab: tab)
            lock.unlock()
        }

        let artworkURL = (json["a"] as? String) ?? ""
        var track = NowPlaying(
            title: title,
            artist: (json["r"] as? String) ?? "",
            album: (json["l"] as? String) ?? "",
            source: browser.name,
            kind: .browser,
            playing: playing,
            artworkKey: nil,
            duration: (json["d"] as? Double) ?? 0,
            position: (json["c"] as? Double) ?? 0,
            // Un navegador solo pasa de pista si la página se ha apuntado a
            // los controles del sistema; con `mediaSession` puesto, lo normal
            // es que sí. Sin metadatos no se promete lo que no se puede dar.
            canSkip: !metadataTitle.isEmpty
        )
        if !artworkURL.isEmpty {
            track.artworkKey = remoteArtwork(urlString: artworkURL, identity: artworkURL)
        }
        return track
    }

    /// Sin `mediaSession` solo queda el título de la pestaña, que arrastra el
    /// nombre del sitio detrás.
    private static func tidy(_ pageTitle: String, browser: String) -> String {
        var title = pageTitle
        for suffix in [" - YouTube", " — YouTube", " - Twitch", " | Twitch"] {
            if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        }
        // Chromium le mete el contador de no leídos al título.
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"), title.distance(from: title.startIndex, to: close) <= 5 {
            title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// AppleScript escribe los decimales con el separador del sistema, así
    /// que en un Mac en español la posición llega como "66,02" y `Double`
    /// la rechaza entera: el reproductor se quedaba siempre en el segundo 0.
    private static func number(_ text: String) -> Double? {
        Double(text) ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// El JavaScript viaja dentro de una cadena de AppleScript, que a su vez
    /// viaja en un argumento de `osascript`.
    private static func escaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Controles

    /// A quién van play, pausa, anterior y siguiente.
    ///
    /// Spotify y Música se controlan por su propio diccionario, que no pide
    /// ningún permiso. Un navegador no tiene diccionario de reproducción, así
    /// que ahí sí hacen falta las teclas de hardware (y con ellas,
    /// Accesibilidad): Chromium las recoge y las traduce a los manejadores de
    /// `mediaSession` de la página, que es justo lo que queremos.
    func transport(_ command: Transport) {
        let kind = current?.kind ?? pinned

        switch kind {
        case .spotify:
            let verb = ["playpause", "next track", "previous track"][command.index]
            SystemControl.osascript("tell application \"Spotify\" to \(verb)")
        case .music:
            let verb = ["playpause", "next track", "previous track"][command.index]
            SystemControl.osascript("tell application \"Music\" to \(verb)")
        case .browser, .none:
            SystemControl.press(command.mediaKey)
        }
        refreshSoon()
    }

    /// Adelantar o atrasar.
    ///
    /// `delta` mueve en relativo (los +/-10 s de un vídeo); `to` salta a un
    /// punto exacto (la barra de progreso arrastrada desde el móvil).
    ///
    /// Spotify y Música lo hacen por su diccionario. En un navegador no hace
    /// falta Accesibilidad: el mismo canal de JavaScript que lee lo que suena
    /// sirve para mover el `<video>`, y es más fino que una tecla de medios
    /// (que ni siquiera tiene un equivalente de «10 segundos»).
    func seek(delta: Double? = nil, to absolute: Double? = nil) {
        let kind = current?.kind ?? pinned

        switch kind {
        case .spotify, .music:
            let app = kind == .spotify ? "Spotify" : "Music"
            let target = absolute.map { String(format: "%.2f", $0) }
                ?? "(player position + \(String(format: "%.2f", delta ?? 0)))"
            SystemControl.osascript("""
            tell application "\(app)"
                if player state is stopped then return ""
                set player position to \(target)
            end tell
            """)

        case .browser:
            // `fastSeek` cuando existe: en un vídeo largo evita esperar al
            // fotograma clave exacto y el salto se nota al instante.
            let move = absolute.map { "var n=\(String(format: "%.2f", $0));" }
                ?? "var n=v.currentTime+(\(String(format: "%.2f", delta ?? 0)));"
            let js = "(function(){var e=document.querySelectorAll('video,audio'),v=null;"
                + "for(var i=0;i<e.length;i++){var x=e[i];if(x.readyState<1)continue;"
                + "if(!x.paused&&!x.ended){v=x;break}if(!v&&x.currentTime>0)v=x}"
                + "if(!v)return '';" + move
                + "if(isFinite(v.duration))n=Math.max(0,Math.min(v.duration-0.4,n));else n=Math.max(0,n);"
                // Netflix NO deja mover el <video> a mano: lo detecta, corta
                // la reproducción y enseña el error M7375. Hay que pedírselo
                // a su propio reproductor, que cuenta en milisegundos.
                //
                // Y no vale llamarlo desde aquí: el JavaScript de AppleScript
                // corre en un mundo aislado (en Chrome y Brave), donde el
                // objeto `netflix` de la página no existe. Así que se mete un
                // <script> en la página, que sí corre en su mundo. El salto se
                // calcula contra el <video> (lo que lee el panel) y se aplica
                // sobre el reloj del reproductor.
                + "if(/(^|\\.)netflix\\./.test(location.hostname)){"
                + "var d=Math.round((n-v.currentTime)*1000),k=document.createElement('script');"
                + "k.textContent='try{var a=netflix.appContext.state.playerApp.getAPI().videoPlayer,"
                + "i=a.getAllPlayerSessionIds(),p=a.getVideoPlayerBySessionId(i[i.length-1]);"
                + "p.seek(Math.max(0,p.getCurrentTime()+('+d+')))}catch(e){}';"
                + "(document.head||document.documentElement).appendChild(k);k.remove();return '1'}"
                + "try{v.fastSeek?v.fastSeek(n):(v.currentTime=n)}catch(_){v.currentTime=n}"
                + "return '1'})()"
            runInPinnedTab(js)

        case .none:
            break
        }
        refreshSoon()
    }

    /// Ejecuta JavaScript en la pestaña que está sonando. Devuelve lo que
    /// conteste la página, o `nil` si no hay pestaña fijada.
    @discardableResult
    private func runInPinnedTab(_ js: String) -> String? {
        lock.lock()
        let tab = pinnedBrowser
        lock.unlock()
        guard let tab, let browser = Self.browsers.first(where: { $0.name == tab.browser }) else { return nil }

        let call: String
        switch browser.family {
        case .chromium:
            call = "execute tab \(tab.tab) of window \(tab.window) javascript \"\(Self.escaped(js))\""
        case .safari:
            call = "do JavaScript \"\(Self.escaped(js))\" in tab \(tab.tab) of window \(tab.window)"
        }
        let script = """
        with timeout of 5 seconds
            tell application "\(browser.name)"
                try
                    return \(call)
                on error
                    return ""
                end try
            end tell
        end timeout
        """
        let answer = SystemControl.osascript(script)
        return (answer?.isEmpty ?? true) ? nil : answer
    }

    /// `true` si lo que suena admite adelantar y atrasar por segundos. Es lo
    /// que decide si el panel enseña ±10 s o anterior/siguiente.
    var canSeek: Bool {
        guard let track = current else { return false }
        switch track.kind {
        case .browser:
            lock.lock()
            let hasTab = pinnedBrowser != nil
            lock.unlock()
            return hasTab && track.duration > 0
        case .spotify, .music:
            return track.duration > 0
        }
    }

    enum Transport {
        case playPause, next, previous

        var index: Int {
            switch self {
            case .playPause: return 0
            case .next: return 1
            case .previous: return 2
            }
        }

        var mediaKey: SystemControl.MediaKey {
            switch self {
            case .playPause: return .playPause
            case .next: return .next
            case .previous: return .previous
            }
        }
    }

    /// `true` cuando los controles de lo que suena ahora necesitan el permiso
    /// de Accesibilidad, para poder avisar solo cuando toca.
    var needsAccessibility: Bool {
        switch current?.kind ?? pinned {
        case .spotify, .music: return false
        case .browser, .none: return true
        }
    }
}
