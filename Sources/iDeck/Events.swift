import Foundation

/// El canal por el que el Mac avisa al móvil, en Server-Sent Events.
///
/// Se eligió SSE y no WebSocket por lo mismo que el servidor HTTP es de
/// cosecha propia: un SSE es texto plano sobre la conexión que ya está
/// abierta, sin apretón de manos ni tramas que implementar, y el navegador
/// trae `EventSource` de serie con reconexión incluida. Para un panel que
/// solo recibe no hace falta nada más.
final class EventHub {
    private let lock = NSLock()
    private var streams: [HTTPStream] = []
    private let queue = DispatchQueue(label: "ideck.events")

    /// Lo último que se mandó, para que un móvil que acaba de conectarse
    /// reciba el estado completo sin esperar al siguiente cambio.
    private var lastPayload: String?

    /// Un móvil con la pantalla apagada deja la conexión medio muerta sin
    /// avisar. El latido la tira a tiempo y `EventSource` reconecta solo.
    private var heartbeat: DispatchSourceTimer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.send(raw: ": ping\n\n") }
        timer.resume()
        heartbeat = timer
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }

    func add(_ stream: HTTPStream) {
        // `retry` le dice al navegador cuánto esperar antes de reintentar.
        stream.write("retry: 2000\n\n")

        lock.lock()
        streams.append(stream)
        let backlog = lastPayload
        lock.unlock()

        stream.onClose = { [weak self] in self?.remove(stream) }
        if let backlog { stream.write(backlog) }
    }

    private func remove(_ stream: HTTPStream) {
        lock.lock()
        streams.removeAll { $0 === stream }
        lock.unlock()
    }

    func broadcast(event: String, payload: Any) {
        // Con las claves ordenadas, como en `/api/state`: el panel se fía del
        // texto que recibe para decidir si algo ha cambiado de verdad. Ver
        // `HTTPResponse.json`.
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // Un `data:` no puede llevar saltos de línea; JSON serializado no los
        // tiene, pero más vale no fiarse de lo que venga de fuera.
        let body = "event: \(event)\ndata: \(json.replacingOccurrences(of: "\n", with: " "))\n\n"
        if event == "state" {
            lock.lock()
            lastPayload = body
            lock.unlock()
        }
        send(raw: body)
    }

    private func send(raw text: String) {
        lock.lock()
        let targets = streams
        lock.unlock()
        for stream in targets where stream.isOpen {
            stream.write(text)
        }
    }

    func closeAll() {
        lock.lock()
        let targets = streams
        streams = []
        lock.unlock()
        targets.forEach { $0.close() }
    }
}

/// Decide cuándo vale la pena mandar el estado.
///
/// Las fuentes avisan a su ritmo y algunas en ráfagas: arrastrar el slider de
/// volumen en el Mac dispara una docena de avisos de CoreAudio en medio
/// segundo. Esto los junta, y además no manda nada si el estado es idéntico al
/// anterior, que es lo que evitaba que el móvil se repintara sin motivo.
final class Broadcaster {
    private let hub: EventHub
    private let build: () -> [String: Any]
    private let queue = DispatchQueue(label: "ideck.broadcast")
    private var scheduled = false
    private var lastSignature: String?

    init(hub: EventHub, build: @escaping () -> [String: Any]) {
        self.hub = hub
        self.build = build
    }

    /// Agrupa los avisos en ventanas de 60 ms.
    func poke() {
        queue.async { [weak self] in
            guard let self, !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.flush(force: false)
            }
        }
    }

    /// Para el latido de fondo y para cuando se conecta alguien nuevo.
    func sendNow() {
        queue.async { [weak self] in self?.flush(force: true) }
    }

    private func flush(force: Bool) {
        guard hub.subscriberCount > 0 else { return }
        let payload = build()
        let signature = Self.signature(of: payload)
        guard force || signature != lastSignature else { return }
        lastSignature = signature
        hub.broadcast(event: "state", payload: payload)
    }

    /// La posición de la pista avanza sola y cambiaría la firma en cada
    /// comparación; se deja fuera para que un reloj corriendo no cuente como
    /// un cambio de estado.
    private static func signature(of payload: [String: Any]) -> String {
        var copy = payload
        if var track = copy["track"] as? [String: Any] {
            track["position"] = nil
            copy["track"] = track
        }
        copy["uptime"] = nil
        if var system = copy["system"] as? [String: Any] {
            system["uptime"] = nil
            copy["system"] = system
        }
        let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
