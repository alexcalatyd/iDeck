import AppKit

/// La presencia en la barra de menús. Sin Dock, sin ventanas.
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store: ConfigStore
    private var server: HTTPServer?
    private var pairing: PairingViewController!
    private lazy var settings = SettingsWindow(store: store)

    /// Lo que suena, el canal de eventos y quien decide cuándo empujar el
    /// estado. Viven aquí porque sobreviven a los reinicios del servidor:
    /// cambiar el puerto no debería perder el seguimiento de la reproducción.
    private let nowPlaying = NowPlayingMonitor()
    private let hub = EventHub()
    private var broadcaster: Broadcaster?
    /// Lo que no avisa por su cuenta (brillo, modo oscuro, batería) se mira
    /// de vez en cuando. Un segundo y medio es suficiente y no se nota.
    private var pulse: DispatchSourceTimer?

    init(store: ConfigStore, showPairingOnLaunch: Bool, showSettingsOnLaunch: Bool = false) {
        self.store = store
        super.init()

        L10n.current = store.config.language.flatMap(L10n.Language.init(rawValue:)) ?? .auto

        pairing = PairingViewController(
            store: store,
            serverIsRunning: { [weak self] in self?.server?.isRunning ?? false },
            onLanguageChange: { [weak self] language in self?.save(language: language) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        // Cambiar el puerto obliga a reabrir el socket; lo demás se lee en
        // vivo, pero el móvil tiene que enterarse igual.
        store.onChange = { [weak self] _, portChanged in
            guard let self else { return }
            if portChanged { self.restartServer() }
            self.broadcaster?.sendNow()
        }

        startMonitoring()

        popover.contentViewController = pairing
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        item.button?.image = Self.icon(active: false)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        startServer()

        if showPairingOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openPopover()
            }
        }

        if showSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.settings.show()
            }
        }
    }

    // MARK: - Servidor

    /// Las tres fuentes que avisan por su cuenta, más un pulso para las que
    /// no: con esto el panel del móvil no necesita sondear nada.
    private func startMonitoring() {
        broadcaster = Broadcaster(hub: hub) { [weak self] in self?.router.snapshot() ?? [:] }
        nowPlaying.onChange = { [weak self] _ in self?.broadcaster?.sendNow() }
        AudioOutput.shared.onChange = { [weak self] in self?.broadcaster?.poke() }
        nowPlaying.start()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ideck.pulse"))
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.broadcaster?.poke() }
        timer.resume()
        pulse = timer
    }

    private func startServer() {
        let port = store.config.port
        let router = self.router
        let server = HTTPServer(port: port) { request in
            router.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("iDeck: no se pudo escuchar en el puerto \(port): \(error)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.item.button?.image = Self.icon(active: self.server?.isRunning ?? false)
        }
    }

    private func restartServer() {
        hub.closeAll()
        server?.stop()
        server = nil
        startServer()
    }

    /// Un solo router para las peticiones y para el canal de eventos: lo que
    /// se empuja es exactamente lo que contesta `/api/state`, así que no hay
    /// dos sitios donde se construya el estado y puedan separarse.
    private lazy var router = Router(
        store: store,
        nowPlaying: nowPlaying,
        hub: hub,
        broadcaster: { [weak self] in self?.broadcaster }
    )

    private func openSettings() {
        popover.performClose(nil)
        settings.show()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    /// Entrada desde fuera: relanzar la app desde Spotlight o el Finder.
    func presentPairing() {
        guard !popover.isShown else { return }
        openPopover()
    }

    private func openPopover() {
        guard let button = item.button else { return }
        pairing.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Ajustes

    private func save(language: L10n.Language) {
        store.update { $0.language = language.rawValue }
    }

    // MARK: - Icono

    /// Dibujado en código: el bundle no necesita catálogo de recursos.
    private static func icon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let cell: CGFloat = 4
            let gap: CGFloat = 1.6
            let origin: CGFloat = 2.4
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = NSRect(
                        x: origin + CGFloat(column) * (cell + gap),
                        y: origin + CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    let path = NSBezierPath(roundedRect: rect, xRadius: 1.1, yRadius: 1.1)
                    // El del centro, como en el icono de la app.
                    let lit = active && row == 1 && column == 1
                    NSColor.black.withAlphaComponent(lit ? 1.0 : 0.55).setFill()
                    path.fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Cómo llega el móvil hasta el Mac.
enum Hostname {
    /// El nombre `.local`, que no cambia aunque cambie la IP.
    static var local: String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : "\(name).local"
    }

    /// IPv4 de la interfaz activa, como plan B cuando el `.local` no resuelve.
    static var wifiAddress: String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)

            if name == "en0" { return text }
            if fallback == nil { fallback = text }
        }
        return fallback
    }
}
