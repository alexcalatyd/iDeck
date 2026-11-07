import Foundation

/// Las carátulas, cacheadas en memoria y servidas por el propio Mac.
///
/// Cada fuente las entrega de una forma distinta: Spotify y los navegadores
/// dan una URL de internet, Música da los bytes crudos del fichero. Y el
/// móvil no siempre tiene salida a internet, así que mandarle la URL de
/// Spotify tal cual deja el hueco en blanco justo cuando se usa el panel de
/// verdad: en una red local sin datos. Aquí se descarga una vez, se guarda y
/// se sirve desde `/api/artwork`.
final class ArtworkStore {
    static let shared = ArtworkStore()

    private struct Entry {
        var data: Data
        var contentType: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Lo que ya se está descargando, para no pedir lo mismo en cada sondeo.
    private var inFlight: Set<String> = []
    /// Las que fallaron: sin esto se reintentaría la misma URL muerta sin parar.
    private var failed: Set<String> = []
    private var order: [String] = []

    /// Un panel de música no necesita recordar más que las últimas portadas.
    private let limit = 24

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// `nil` mientras no esté lista. Se mira en cada petición de `/api/artwork`.
    func data(for key: String) -> (Data, String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        return (entry.data, entry.contentType)
    }

    func has(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    /// La clave es estable para la misma imagen, así que el móvil puede
    /// cachearla y no vuelve a pedirla al cambiar de canción y volver.
    static func key(for identity: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    /// Descarga en segundo plano: el sondeo no se queda esperando a la red.
    /// `onReady` solo se llama si la imagen es nueva, para avisar al móvil.
    func fetch(url: URL, key: String, onReady: @escaping () -> Void) {
        lock.lock()
        let known = entries[key] != nil || inFlight.contains(key) || failed.contains(key)
        if !known { inFlight.insert(key) }
        lock.unlock()
        guard !known else { return }

        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            self.finish(key: key, data: data, contentType: type, onReady: onReady)
        }.resume()
    }

    /// Para Música, que entrega los bytes por AppleScript en vez de una URL.
    func store(data: Data, key: String, contentType: String, onReady: @escaping () -> Void) {
        lock.lock()
        let known = entries[key] != nil
        lock.unlock()
        guard !known else { return }
        finish(key: key, data: data, contentType: contentType, onReady: onReady)
    }

    private func finish(key: String, data: Data?, contentType: String?, onReady: @escaping () -> Void) {
        lock.lock()
        inFlight.remove(key)
        guard let data, !data.isEmpty, data.count < 8 * 1024 * 1024 else {
            failed.insert(key)
            lock.unlock()
            return
        }
        entries[key] = Entry(data: data, contentType: Self.sniff(data) ?? contentType ?? "image/jpeg")
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        onReady()
    }

    /// El tipo que diga la cabecera puede no ser el real (y Música no dice
    /// ninguno). Los bytes iniciales no engañan.
    private static func sniff(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return nil }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "image/png" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "image/gif" }
        if Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if Array(bytes[4..<8]) == Array("ftyp".utf8) { return "image/heic" }
        return nil
    }
}
