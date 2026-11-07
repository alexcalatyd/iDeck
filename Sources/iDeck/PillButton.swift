import AppKit

/// Botón plano con fondo propio: el estilo nativo no encaja con el panel.
final class PillButton: NSButton {
    enum Kind {
        case primary
        case secondary
        case quiet
        /// Opción de un grupo: encendida en ámbar, apagada en gris.
        case toggle
        /// Cuadrado con un símbolo en vez de texto.
        case icon
    }

    private let kind: Kind
    private var label: String
    private var hovering = false

    /// Solo se usa en `.toggle`.
    var isSelected = false {
        didSet { apply() }
    }

    init(label: String, kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        self.label = label
        super.init(frame: .zero)

        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = isLarge ? 9 : 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: isLarge ? 34 : 24).isActive = true
        if kind == .toggle {
            widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        if kind == .icon {
            widthAnchor.constraint(equalToConstant: 38).isActive = true
        }
        apply()
    }

    /// Variante con símbolo. `describing` es lo que leerá VoiceOver y lo que
    /// sale en el tooltip, porque el botón no lleva texto.
    convenience init(symbol: String, describing: String, target: AnyObject?, action: Selector) {
        self.init(label: "", kind: .icon, target: target, action: action)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: describing)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        toolTip = describing
        setAccessibilityLabel(describing)
        refreshTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no disponible") }

    func setLabel(_ newValue: String) {
        label = newValue
        apply()
    }

    /// Los dos tamaños del sistema: acción principal o control de pie.
    private var isLarge: Bool { kind == .primary || kind == .secondary || kind == .icon }

    private var background: NSColor {
        switch kind {
        case .primary:
            return hovering ? Palette.ledBright : Palette.led
        case .secondary:
            return hovering ? Palette.raised : Palette.module
        case .quiet:
            return hovering ? Palette.module : .clear
        case .toggle:
            if isSelected { return hovering ? Palette.ledBright : Palette.led }
            return hovering ? Palette.module : .clear
        case .icon:
            return hovering ? Palette.raised : Palette.module
        }
    }

    private var foreground: NSColor {
        switch kind {
        case .primary: return Palette.ground
        case .secondary: return Palette.ink
        case .quiet: return hovering ? Palette.ink : Palette.inkDim
        case .toggle: return isSelected ? Palette.ground : (hovering ? Palette.ink : Palette.inkDim)
        case .icon: return isEnabled ? Palette.ink : Palette.inkDim
        }
    }

    /// Los botones de símbolo tiñen la imagen, no el texto.
    private func refreshTint() {
        contentTintColor = foreground
    }

    override var isEnabled: Bool {
        didSet { if kind == .icon { refreshTint() } }
    }

    private func apply() {
        layer?.backgroundColor = background.cgColor
        if kind == .icon {
            contentTintColor = foreground
            return
        }
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(
                ofSize: isLarge ? 13 : 12,
                weight: kind == .primary || (kind == .toggle && isSelected) ? .semibold : .medium
            ),
            .foregroundColor: foreground,
        ])
        invalidateIntrinsicContentSize()
    }

    /// `NSButton` se ciñe al texto y las letras quedan pegadas al borde.
    /// Los de ancho fijo (icono y toggle) ya tienen su constraint.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        guard kind != .icon, kind != .toggle else { return size }
        size.width += isLarge ? 32 : 18
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        apply()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        apply()
    }
}

/// Los mismos colores que el panel del móvil.
enum Palette {
    static let ground = NSColor(srgbRed: 0.102, green: 0.125, blue: 0.141, alpha: 1)
    static let module = NSColor(srgbRed: 0.173, green: 0.212, blue: 0.231, alpha: 1)
    static let raised = NSColor(srgbRed: 0.216, green: 0.263, blue: 0.286, alpha: 1)
    static let ink = NSColor(srgbRed: 0.902, green: 0.922, blue: 0.933, alpha: 1)
    static let inkDim = NSColor(srgbRed: 0.541, green: 0.592, blue: 0.620, alpha: 1)
    static let led = NSColor(srgbRed: 0.910, green: 0.639, blue: 0.239, alpha: 1)
    static let ledBright = NSColor(srgbRed: 0.957, green: 0.714, blue: 0.345, alpha: 1)
}
