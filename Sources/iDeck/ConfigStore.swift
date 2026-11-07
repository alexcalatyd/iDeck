import Foundation

/// Un único sitio donde vive la configuración. El servidor, el popover y la
/// ventana de ajustes leen de aquí, así que un cambio se ve en todos a la vez.
final class ConfigStore {
    private(set) var config: Config

    /// Se dispara tras cada cambio ya guardado en disco.
    var onChange: ((Config, _ portChanged: Bool) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func update(_ change: (inout Config) -> Void) {
        let previousPort = config.port
        let previousApps = config.apps
        change(&config)
        config.save()
        // Los iconos se cachean por ruta: si la lista cambia, lo que había
        // puede ser de una app que ya no está o que se ha actualizado.
        if config.apps != previousApps { AppIcons.forget() }
        onChange?(config, config.port != previousPort)
    }
}
