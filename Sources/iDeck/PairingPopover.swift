import AppKit
import CoreImage

/// Lo que cuelga del icono de la barra: un QR y poco más.
final class PairingViewController: NSViewController {
    private let store: ConfigStore
    private let serverIsRunning: () -> Bool
    private let onLanguageChange: (L10n.Language) -> Void
    private let onOpenSettings: () -> Void

    private var port: UInt16 { store.config.port }
    private var token: String { store.config.token }

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let qrView = NSImageView()
    private let blurView = NSImageView()
    private var revealButton: PillButton?

    private var copyButton: PillButton?
    private var openButton: PillButton?
    private var settingsButton: PillButton?
    private var quitButton: PillButton?
    private var spanishButton: PillButton?
    private var englishButton: PillButton?
    private var warningLabel: NSTextField?
    private var grantButton: PillButton?
    private var permissionRow: NSStackView?
    private var permissionTimer: Timer?
    private var isRevealed = false

    private let contentStack = NSStackView()
    private let separator = NSBox()

    init(
        store: ConfigStore,
        serverIsRunning: @escaping () -> Bool,
        onLanguageChange: @escaping (L10n.Language) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.store = store
        self.serverIsRunning = serverIsRunning
        self.onLanguageChange = onLanguageChange
        self.onOpenSettings = onOpenSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no disponible") }

    /// Una sola dirección: el nombre `.local`, y la IP solo si no existe.
    var panelURL: String {
        let host = Hostname.local ?? Hostname.wifiAddress ?? "localhost"
        return "http://\(host):\(port)/?t=\(token)"
    }

    private var displayHost: String {
        (Hostname.local ?? Hostname.wifiAddress).map { "\($0):\(port)" } ?? L10n.noNetwork
    }

    // MARK: - Vista

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 264, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.ground.cgColor

        // Cabecera
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = Palette.ink

        addressLabel.font = .systemFont(ofSize: 11)
        addressLabel.textColor = Palette.inkDim
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [statusDot, statusLabel, NSView(), addressLabel])
        header.orientation = .horizontal
        header.spacing = 7
        header.alignment = .centerY

        // Tarjeta del QR
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 232).isActive = true
        card.heightAnchor.constraint(equalToConstant: 232).isActive = true

        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(qrView)
        NSLayoutConstraint.activate([
            qrView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            qrView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            qrView.widthAnchor.constraint(equalToConstant: 200),
            qrView.heightAnchor.constraint(equalToConstant: 200),
        ])

        // El QR es la llave del panel: tapado hasta que lo pidas.
        blurView.imageScaling = .scaleProportionallyUpOrDown
        blurView.wantsLayer = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: card.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let reveal = PillButton(label: "", kind: .primary, target: self, action: #selector(revealQR))
        reveal.wantsLayer = true
        card.addSubview(reveal)
        NSLayoutConstraint.activate([
            reveal.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            reveal.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            reveal.widthAnchor.constraint(equalToConstant: 132),
        ])
        revealButton = reveal

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = Palette.inkDim
        hintLabel.alignment = .center

        // Acciones
        let copy = PillButton(label: "", kind: .primary, target: self, action: #selector(copyLink))
        let openHere = PillButton(label: "", kind: .secondary, target: self, action: #selector(openHere))
        copyButton = copy
        openButton = openHere

        let actions = NSStackView(views: [copy, openHere])
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8

        // Pie: idioma a la izquierda, ajustes y salir a la derecha
        let spanish = PillButton(label: "ES", kind: .toggle, target: self, action: #selector(chooseSpanish))
        let english = PillButton(label: "EN", kind: .toggle, target: self, action: #selector(chooseEnglish))
        spanishButton = spanish
        englishButton = english

        let languagePicker = NSStackView(views: [spanish, english])
        languagePicker.orientation = .horizontal
        languagePicker.spacing = 4

        let settings = PillButton(label: "", kind: .quiet, target: self, action: #selector(openSettings))
        let quit = PillButton(label: "", kind: .quiet, target: self, action: #selector(quit))
        settingsButton = settings
        quitButton = quit

        let footer = NSStackView(views: [languagePicker, NSView(), settings, quit])
        footer.orientation = .horizontal
        footer.spacing = 4
        footer.alignment = .centerY

        separator.boxType = .separator

        let stack = contentStack
        [header, card, hintLabel, actions, separator, footer].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        // Mismo aire por los cuatro lados: el pie dejaba de parecer un sobrante.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.widthAnchor.constraint(equalTo: card.widthAnchor),
            actions.widthAnchor.constraint(equalTo: card.widthAnchor),
            footer.widthAnchor.constraint(equalTo: card.widthAnchor),
            separator.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])

        view = content
    }

    /// El permiso se concede en otra app, así que lo vigilamos mientras el
    /// popover está abierto en vez de esperar a que lo vuelvan a abrir.
    override func viewWillAppear() {
        super.viewWillAppear()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updatePermissionRow()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        permissionTimer?.invalidate()
        permissionTimer = nil
        lock()
    }

    /// Se llama cada vez que se abre: red, permisos e idioma cambian solos.
    func refresh() {
        let live = serverIsRunning()
        statusDot.layer?.backgroundColor = (live ? Palette.led : Palette.inkDim).cgColor
        addressLabel.stringValue = displayHost
        let code = Self.qrCode(for: panelURL, pixels: 400)
        qrView.image = code
        blurView.image = code.flatMap { Self.blurred($0, radius: 16) }
        lock()
        updatePermissionRow()
        syncSize()
    }

    /// Vuelve a tapar el QR. Se llama al abrir y al cerrar, así que nunca
    /// queda destapado de una vez para la siguiente.
    private func lock() {
        isRevealed = false
        blurView.alphaValue = 1
        blurView.isHidden = false
        revealButton?.alphaValue = 1
        revealButton?.isHidden = false
        applyLanguage()
    }

    @objc private func revealQR() {
        isRevealed = true
        applyLanguage()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurView.animator().alphaValue = 0
            revealButton?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isRevealed else { return }
            self.blurView.isHidden = true
            self.revealButton?.isHidden = true
        }
    }

    private func applyLanguage() {
        spanishButton?.isSelected = L10n.isSpanish
        englishButton?.isSelected = !L10n.isSpanish
        statusLabel.stringValue = "iDeck · \(serverIsRunning() ? L10n.running : L10n.stopped)"
        hintLabel.stringValue = isRevealed ? L10n.scan : L10n.hidden
        revealButton?.setLabel(L10n.reveal)
        copyButton?.setLabel(L10n.copyLink)
        openButton?.setLabel(L10n.openHere)
        settingsButton?.setLabel(L10n.settings)
        quitButton?.setLabel(L10n.quit)
        warningLabel?.stringValue = L10n.permissionNeeded
        grantButton?.setLabel(L10n.grant)
    }

    private func updatePermissionRow() {
        let stack = contentStack

        if SystemControl.hasAccessibility {
            guard let row = permissionRow else { return }
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            permissionRow = nil
            warningLabel = nil
            grantButton = nil
            syncSize()
            return
        }

        guard permissionRow == nil else { return }

        let warning = NSTextField(labelWithString: L10n.permissionNeeded)
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = Palette.led
        warning.lineBreakMode = .byTruncatingTail
        warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grant = PillButton(label: L10n.grant, kind: .quiet, target: self, action: #selector(grantAccessibility))

        let row = NSStackView(views: [warning, NSView(), grant])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        // Justo encima del separador del pie.
        let index = max(0, stack.arrangedSubviews.count - 2)
        stack.insertArrangedSubview(row, at: index)
        row.widthAnchor.constraint(equalToConstant: 232).isActive = true

        permissionRow = row
        warningLabel = warning
        grantButton = grant
        syncSize()
    }

    /// El separador y el pie van más juntos que el resto: con el espaciado
    /// general de 12 pt la franja de abajo quedaba suelta.
    private func tightenFooter() {
        let views = contentStack.arrangedSubviews
        guard let index = views.firstIndex(of: separator) else { return }
        if index > 0 {
            contentStack.setCustomSpacing(10, after: views[index - 1])
        }
        contentStack.setCustomSpacing(10, after: separator)
    }

    /// El popover conserva el tamaño con el que se abrió: si el contenido
    /// cambia de altura hay que decírselo o queda un hueco.
    private func syncSize() {
        tightenFooter()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    // MARK: - Acciones

    @objc private func chooseSpanish() { choose(.spanish) }

    @objc private func chooseEnglish() { choose(.english) }

    private func choose(_ language: L10n.Language) {
        L10n.current = language
        onLanguageChange(language)
        applyLanguage()
    }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(panelURL, forType: .string)
        copyButton?.setLabel(L10n.copied)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton?.setLabel(L10n.copyLink)
        }
    }

    @objc private func openHere() {
        guard let url = URL(string: panelURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func grantAccessibility() {
        SystemControl.requestAccessibility()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - QR

    /// Core Image trae el generador: sin dependencias externas.
    static func qrCode(for string: String, pixels: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Escala entera: módulos cuadrados y nítidos, sin interpolación.
        let factor = max(1, (pixels / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))

        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    /// La versión tapada. `clampedToExtent` evita que el desenfoque chupe
    /// transparencia de los bordes y deje un halo gris alrededor.
    static func blurred(_ image: NSImage, radius: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let source = CIImage(data: tiff),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }

        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: source.extent) else { return nil }

        let representation = NSCIImageRep(ciImage: output)
        let blurred = NSImage(size: representation.size)
        blurred.addRepresentation(representation)
        return blurred
    }
}
