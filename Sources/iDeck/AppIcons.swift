import AppKit
import Foundation

/// Los iconos de las apps, servidos tal cual están en el Mac.
///
/// La alternativa era dibujar un glifo por app, y ahí no hay forma de acertar:
/// son marcas, no símbolos, y un set propio acabaría siendo una mezcla de
/// estilos justo donde el usuario reconoce la app de un vistazo. `NSWorkspace`
/// ya tiene el icono real, así que se convierte a PNG una vez y se cachea.
enum AppIcons {
    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]

    /// 128 px: en la rejilla se pinta a unos 110 pt, y con @3x el móvil
    /// agradece el margen sin que la imagen pese.
    private static let side: CGFloat = 128

    static func png(forAppAt path: String) -> Data? {
        lock.lock()
        if let hit = cache[path] { lock.unlock(); return hit }
        lock.unlock()

        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: side, height: side)

        // `NSImage` guarda varias representaciones; hay que redibujar en un
        // bitmap del tamaño que queremos o sale la que le apetezca.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        lock.lock()
        cache[path] = data
        lock.unlock()
        return data
    }

    /// Desinstalar o actualizar una app cambia su icono; la caché se vacía
    /// cuando la lista de apps cambia.
    static func forget() {
        lock.lock()
        cache = [:]
        lock.unlock()
    }
}
