import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]
    /// Cuando está puesto, el servidor manda las cabeceras y deja la conexión
    /// abierta en manos de este bloque en vez de cerrarla. Es lo que permite
    /// mantener el canal de eventos.
    var stream: ((HTTPStream) -> Void)?

    static func eventStream(_ open: @escaping (HTTPStream) -> Void) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            contentType: "text/event-stream; charset=utf-8",
            extraHeaders: ["X-Accel-Buffering": "no"],
            stream: open
        )
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        // `.sortedKeys` no es cosmética. El estado se arma con diccionarios
        // de Swift, cuyo orden de iteración no está definido: el MISMO
        // estado se serializaba cada vez con las claves en otro orden. El
        // panel compara el estado que recibe con el que ya tenía para saber
        // si hace falta volver a montar una pantalla, y esas dos cadenas
        // nunca coincidían: el Mando se desmontaba entero con cada aviso,
        // la página volvía a la primera y un gesto en curso se quedaba sin
        // el nodo que estaba tocando. Ordenadas, el mismo estado es la
        // misma cadena.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(string.utf8))
    }
}

/// Una conexión que se queda abierta después de las cabeceras.
///
/// El panel vivía de sondear cada 1,5 s, y eso se notaba: el botón de play
/// tardaba más de un segundo en reflejar una pausa hecha en el Mac, y el
/// volumen movido desde el teclado llegaba tarde. Con esto el Mac empuja el
/// estado en el momento en que cambia.
final class HTTPStream {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false

    /// Se llama una sola vez, cuando el móvil se va o la red se corta.
    var onClose: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func write(_ text: String) {
        lock.lock()
        let alive = !closed
        lock.unlock()
        guard alive else { return }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let notify = onClose
        onClose = nil
        lock.unlock()
        connection.cancel()
        notify?()
    }
}

/// Minimal HTTP/1.1 server on Network.framework. Las peticiones normales se
/// cierran al contestar (Connection: close); el canal de eventos se queda
/// abierto. Sin dependencias.
final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ideck.http", attributes: .concurrent)
    private let handler: (HTTPRequest) -> HTTPResponse

    let port: UInt16
    private(set) var isRunning = false

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.isRunning = true }
            if case .failed = state { self?.isRunning = false }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let request = Self.parse(buffer) {
                let response = self.handler(request)
                self.send(response, on: connection)
                return
            }

            if isComplete { connection.cancel(); return }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let streaming = response.stream != nil

        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        if streaming {
            head += "Connection: keep-alive\r\n"
        } else {
            head += "Content-Length: \(response.body.count)\r\n"
            head += "Connection: close\r\n"
        }
        // Casi todo es estado vivo y no se debe cachear, pero las portadas
        // traen su propia caché: sin esto salían las dos cabeceras y el
        // navegador se quedaba con la restrictiva.
        if !response.extraHeaders.keys.contains(where: { $0.lowercased() == "cache-control" }) {
            head += "Cache-Control: no-store\r\n"
        }
        for (key, value) in response.extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        guard let open = response.stream else {
            var data = Data(head.utf8)
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let stream = HTTPStream(connection: connection)
        // Cerrar la pestaña en el móvil no manda nada: la conexión se entera
        // por el estado del socket, y sin esto el servidor acumularía
        // suscriptores muertos.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: stream.close()
            default: break
            }
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { stream.close(); return }
            open(stream)
        })
    }

    // MARK: - Parsing

    private static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = buffer[buffer.startIndex..<separator.lowerBound]
        guard let headText = String(data: headData, encoding: .utf8) else { return nil }

        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= expected else { return nil }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: expected)])

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            let rest = String(target[target.index(after: mark)...])
            for pair in rest.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first?.removingPercentEncoding else { continue }
                let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
                query[String(key)] = value
            }
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}
