import AppKit

/// La ventana grande de ajustes. Sustituye a abrir el JSON en el Finder.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigStore
    private var window: NSWindow?

    private let table = NSTableView()
    private let portField = NSTextField()
    private let tokenField = NSTextField(labelWithString: "")
    private var removeButton: NSButton?
    private var upButton: NSButton?
    private var downButton: NSButton?
    private var cleanButton: PillButton?
    private let advancedToggle = NSButton()
    private let advancedBox = NSStackView()

    /// Se construye una sola vez. Varias vistas son propiedades compartidas,
    /// así que rearmar el contenido al reabrir duplicaba secciones.
    private lazy var contentView: NSView = buildContent()

    /// El contenido se construye una vez, así que cada texto deja aquí cómo
    /// volver a escribirse. Sin esto la ventana se queda en el idioma que
    /// hubiera al crearla.
    private var localizers: [() -> Void] = []

    init(store: ConfigStore) {
        self.store = store
        super.init()
    }

    // MARK: - Presentación

    func show() {
        if let window {
            applyLanguage()
            reloadFromConfig()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsTitle
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.ground
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.center()
        self.window = window

        applyLanguage()
        reloadFromConfig()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Construcción

    private func buildContent() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.ground.cgColor

        let left = NSStackView(views: [panelsSection(), advancedSection(), NSView()])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 26
        left.translatesAutoresizingMaskIntoConstraints = false

        let right = appsSection()
        right.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(left)
        container.addSubview(right)

        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            left.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
            left.widthAnchor.constraint(equalToConstant: 300),

            right.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 32),
            right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            right.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])

        return container
    }

    private func heading(_ text: @escaping @autoclosure () -> String) -> NSTextField {
        let field = NSTextField(labelWithString: text())
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = Palette.inkDim
        localizers.append { field.stringValue = text() }
        return field
    }

    private func connectionSection() -> NSView {
        portField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        portField.alignment = .left
        portField.target = self
        portField.action = #selector(portCommitted)
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let portRow = NSStackView(views: [label(L10n.portLabel), portField])
        portRow.orientation = .horizontal
        portRow.spacing = 10
        portRow.alignment = .centerY

        tokenField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tokenField.textColor = Palette.ink
        tokenField.isSelectable = true

        let regenerate = pill(L10n.regenerate, kind: .secondary, action: #selector(regenerateToken))

        let tokenRow = NSStackView(views: [tokenField, NSView(), regenerate])
        tokenRow.orientation = .horizontal
        tokenRow.spacing = 10
        tokenRow.alignment = .centerY
        tokenRow.translatesAutoresizingMaskIntoConstraints = false
        tokenRow.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let warning = NSTextField(wrappingLabelWithString: L10n.regenerateWarning)
        localizers.append { warning.stringValue = L10n.regenerateWarning }
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = Palette.inkDim
        warning.translatesAutoresizingMaskIntoConstraints = false
        warning.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let reveal = pill(L10n.revealJSON, kind: .quiet, action: #selector(revealJSON))

        let stack = NSStackView(views: [
            portRow,
            label(L10n.tokenLabel), tokenRow, warning,
            reveal,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: portRow)
        stack.setCustomSpacing(18, after: warning)
        return stack
    }

    /// Lo que no se toca a diario va plegado: puerto, token y el JSON crudo.
    private func advancedSection() -> NSView {
        advancedToggle.setButtonType(.pushOnPushOff)
        advancedToggle.bezelStyle = .disclosure
        advancedToggle.title = ""
        advancedToggle.state = .off
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)

        let title = NSTextField(labelWithString: L10n.advanced)
        localizers.append { title.stringValue = L10n.advanced }
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Palette.inkDim

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleAdvancedFromLabel))
        title.addGestureRecognizer(click)

        let header = NSStackView(views: [advancedToggle, title])
        header.orientation = .horizontal
        header.spacing = 4
        header.alignment = .centerY

        advancedBox.orientation = .vertical
        advancedBox.alignment = .leading
        advancedBox.spacing = 0
        advancedBox.addArrangedSubview(connectionSection())
        advancedBox.isHidden = true

        let stack = NSStackView(views: [header, advancedBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    /// Lo mismo que el móvil puede apagar desde su propia pantalla de
    /// ajustes, pero desde el Mac. Un control apagado aquí no aparece allí
    /// y además se rechaza en el servidor.
    private func panelsSection() -> NSView {
        let music = checkbox(L10n.musicPanel, \.music)
        let apps = checkbox(L10n.appsPanel, \.apps)
        let volume = checkbox(L10n.volumeTile, \.volume)
        let brightness = checkbox(L10n.brightnessTile, \.brightness)

        let appearance = checkbox(L10n.appearanceTile, \.appearance)
        let displaySleep = checkbox(L10n.displaySleepTile, \.displaySleep)
        let lock = checkbox(L10n.lockTile, \.lock)
        let sleep = checkbox(L10n.sleepTile, \.sleep)
        let shortcuts = checkbox(L10n.shortcutsTile, \.shortcuts)
        let restart = checkbox(L10n.restartTile, \.restart)
        let shutdown = checkbox(L10n.shutdownTile, \.shutdown)

        let note = NSTextField(wrappingLabelWithString: L10n.dangerNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = Palette.inkDim
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 300).isActive = true
        localizers.append { note.stringValue = L10n.dangerNote }

        let stack = NSStackView(views: [
            heading(L10n.panels), music, apps, volume, brightness,
            heading(L10n.systemTiles), appearance, displaySleep, lock, sleep,
            shortcuts, restart, shutdown, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: brightness)
        stack.setCustomSpacing(12, after: shutdown)
        return stack
    }

    private func appsSection() -> NSView {
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 44
        table.backgroundColor = Palette.module
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.target = self
        table.action = #selector(selectionClicked)

        let column = NSTableColumn(identifier: .init("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.module
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.cornerCurve = .continuous
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = pill(L10n.addApp, kind: .primary, action: #selector(addApp))
        let remove = pill(L10n.removeApp, kind: .secondary, action: #selector(removeApp))
        let up = PillButton(symbol: "arrow.up", describing: L10n.moveUp, target: self, action: #selector(moveUp))
        let down = PillButton(symbol: "arrow.down", describing: L10n.moveDown, target: self, action: #selector(moveDown))
        localizers.append {
            up.toolTip = L10n.moveUp
            up.setAccessibilityLabel(L10n.moveUp)
            down.toolTip = L10n.moveDown
            down.setAccessibilityLabel(L10n.moveDown)
        }
        removeButton = remove
        upButton = up
        downButton = down

        let arrows = NSStackView(views: [up, down])
        arrows.orientation = .horizontal
        arrows.spacing = 6

        let clean = pill(L10n.cleanMissing, kind: .secondary, action: #selector(removeMissing))
        cleanButton = clean

        let buttons = NSStackView(views: [add, remove, clean, NSView(), arrows])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let title = heading(L10n.appsHeading)
        title.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(title)
        container.addSubview(scroll)
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func label(_ text: @escaping @autoclosure () -> String) -> NSTextField {
        let field = NSTextField(labelWithString: text())
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.ink
        localizers.append { field.stringValue = text() }
        return field
    }

    /// Botón de texto que se vuelve a etiquetar al cambiar de idioma.
    private func pill(_ text: @escaping @autoclosure () -> String, kind: PillButton.Kind, action: Selector) -> PillButton {
        let button = PillButton(label: text(), kind: kind, target: self, action: action)
        localizers.append { button.setLabel(text()) }
        return button
    }

    private func checkbox(_ title: @escaping @autoclosure () -> String, _ key: WritableKeyPath<Config.Controls, Bool>) -> NSButton {
        let button = NSButton(checkboxWithTitle: title(), target: self, action: #selector(toggleChanged(_:)))
        keyPaths[button] = key

        let restyle = {
            button.attributedTitle = NSAttributedString(string: title(), attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: Palette.ink,
            ])
        }
        restyle()
        localizers.append(restyle)
        return button
    }

    /// Qué ajuste toca cada casilla.
    private var keyPaths: [NSButton: WritableKeyPath<Config.Controls, Bool>] = [:]

    /// Reescribe todo el texto con el idioma actual, incluidas las filas de
    /// la tabla, que también llevan texto traducido.
    private func applyLanguage() {
        window?.title = L10n.settingsTitle
        localizers.forEach { $0() }
        table.reloadData()
    }

    // MARK: - Estado

    private func reloadFromConfig() {
        let config = store.config
        portField.stringValue = String(config.port)
        tokenField.stringValue = config.token
        for (button, key) in keyPaths {
            button.state = config.controls[keyPath: key] ? .on : .off
        }
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let row = table.selectedRow
        cleanButton?.isHidden = store.config.apps.allSatisfy(\.exists)
        removeButton?.isEnabled = row >= 0
        upButton?.isEnabled = row > 0
        downButton?.isEnabled = row >= 0 && row < store.config.apps.count - 1
    }

    // MARK: - Acciones

    @objc private func portCommitted() {
        guard let value = UInt16(portField.stringValue), value >= 1024 else {
            portField.stringValue = String(store.config.port)
            NSSound.beep()
            return
        }
        guard value != store.config.port else { return }
        store.update { $0.port = value }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let key = keyPaths[sender] else { return }
        let isOn = sender.state == .on
        store.update { $0.controls[keyPath: key] = isOn }
    }

    @objc private func regenerateToken() {
        let alert = NSAlert()
        alert.messageText = L10n.regenerateConfirm
        alert.informativeText = L10n.regenerateWarning
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.regenerate)
        alert.addButton(withTitle: L10n.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.update { $0.token = Config.randomToken() }
        tokenField.stringValue = store.config.token
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }

        store.update { config in
            for url in panel.urls {
                let entry = Config.AppEntry(
                    name: url.deletingPathExtension().lastPathComponent,
                    path: url.path
                )
                if !config.apps.contains(entry) { config.apps.append(entry) }
            }
        }
        table.reloadData()
        updateButtons()
    }

    @objc private func removeApp() {
        let row = table.selectedRow
        guard row >= 0, row < store.config.apps.count else { return }
        store.update { $0.apps.remove(at: row) }
        table.reloadData()
        updateButtons()
    }

    @objc private func removeMissing() {
        store.update { $0.apps.removeAll { !$0.exists } }
        table.reloadData()
        updateButtons()
    }

    @objc private func moveUp() { move(by: -1) }

    @objc private func moveDown() { move(by: 1) }

    private func move(by offset: Int) {
        let row = table.selectedRow
        let target = row + offset
        guard row >= 0, target >= 0, target < store.config.apps.count else { return }
        store.update { $0.apps.swapAt(row, target) }
        table.reloadData()
        table.selectRowIndexes([target], byExtendingSelection: false)
        updateButtons()
    }

    @objc private func toggleAdvanced() {
        advancedBox.isHidden = advancedToggle.state == .off
    }

    @objc private func toggleAdvancedFromLabel() {
        advancedToggle.state = advancedToggle.state == .on ? .off : .on
        toggleAdvanced()
    }

    @objc private func revealJSON() {
        NSWorkspace.shared.selectFile(Config.fileURL.path, inFileViewerRootedAtPath: Config.directory.path)
    }

    @objc private func selectionClicked() { updateButtons() }

    // MARK: - Tabla

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.config.apps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = store.config.apps[row]
        let installed = app.exists

        let icon = NSImageView(image: installed
            ? NSWorkspace.shared.icon(forFile: app.path)
            : NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: L10n.missingApp)
                ?? NSImage())
        icon.contentTintColor = Palette.inkDim
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let name = NSTextField(labelWithString: app.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = installed ? Palette.ink : Palette.inkDim

        let path = NSTextField(labelWithString: installed ? app.path : L10n.missingApp)
        path.font = .systemFont(ofSize: 10)
        path.textColor = installed ? Palette.inkDim : Palette.led
        path.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [name, path])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let cell = NSStackView(views: [icon, text])
        cell.orientation = .horizontal
        cell.spacing = 10
        cell.alignment = .centerY
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
