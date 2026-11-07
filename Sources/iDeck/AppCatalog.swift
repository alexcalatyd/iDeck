import Foundation

/// Las apps instaladas en el Mac, para el "+" de Apps del panel. Solo se
/// puede añadir lo que sale de aquí: el panel manda una ruta y el servidor
/// no se fía de ninguna que no haya encontrado él mismo.
enum AppCatalog {
    private static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// El Finder no vive en ninguna carpeta de apps, pero es la que más se abre.
    private static let extras = ["/System/Library/CoreServices/Finder.app"]

    private static let lock = NSLock()
    private static var cached: [Config.AppEntry] = []
    private static var cachedAt = Date.distantPast

    /// Recorrer las carpetas cuesta poco, pero el panel pide iconos de cada
    /// una: se recuerda un minuto.
    static func all() -> [Config.AppEntry] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) < 60 { return cached }

        var seen = Set<String>()
        var found: [Config.AppEntry] = []
        let manager = FileManager.default
        var paths = extras
        for root in roots {
            let names = (try? manager.contentsOfDirectory(atPath: root)) ?? []
            paths += names.filter { $0.hasSuffix(".app") }.map { root + "/" + $0 }
        }
        for path in paths where manager.fileExists(atPath: path) {
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            // Lo que no tiene sentido abrir desde un mando.
            if name == "iDeck" || name.localizedCaseInsensitiveContains("uninstall") { continue }
            if !seen.insert(name.lowercased()).inserted { continue }
            found.append(Config.AppEntry(name: name, path: path))
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = found
        cachedAt = Date()
        return found
    }

    static func contains(_ path: String) -> Bool {
        all().contains { $0.path == path }
    }
}
