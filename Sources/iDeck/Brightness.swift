import CoreGraphics
import Foundation

/// El brillo de la pantalla, con valor absoluto.
///
/// Antes solo se podía empujar arriba y abajo mandando las teclas de brillo,
/// que necesitan Accesibilidad y no dicen en qué nivel está la pantalla: con
/// eso no se puede dibujar un slider. `DisplayServices` sí lee y escribe el
/// nivel real (0–1) del panel integrado, y no pide ningún permiso.
///
/// Es un framework privado: si una versión de macOS se lo lleva por delante,
/// `isAvailable` pasa a ser `false` y el panel vuelve a los botones de subir
/// y bajar, que siguen funcionando con las teclas.
enum Brightness {

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private struct Bridge {
        let get: GetBrightness
        let set: SetBrightness
    }

    private static let bridge: Bridge? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework"
        guard let bundle = CFBundleCreate(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        CFBundleLoadExecutable(bundle)
        guard let get = CFBundleGetFunctionPointerForName(bundle, "DisplayServicesGetBrightness" as CFString),
              let set = CFBundleGetFunctionPointerForName(bundle, "DisplayServicesSetBrightness" as CFString)
        else { return nil }
        return Bridge(
            get: unsafeBitCast(get, to: GetBrightness.self),
            set: unsafeBitCast(set, to: SetBrightness.self)
        )
    }()

    /// La pantalla sobre la que mandamos: la integrada, o la principal si el
    /// Mac no tiene panel propio (un Mac mini, por ejemplo).
    private static func target() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return nil }
        let active = Array(ids.prefix(Int(count)))
        return active.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? active.first
    }

    /// `true` cuando se puede leer un nivel de verdad. Un monitor externo por
    /// HDMI normalmente no contesta, y entonces esto es `false`.
    static var isAvailable: Bool { level() != nil }

    /// 0–100, o `nil` si la pantalla no sabe decirlo.
    static func level() -> Int? {
        guard let bridge, let display = target() else { return nil }
        var value: Float = 0
        guard bridge.get(display, &value) == 0, value >= 0, value <= 1 else { return nil }
        return Int((value * 100).rounded())
    }

    /// Devuelve `false` si no se pudo escribir, para que quien llame tire de
    /// las teclas de brillo.
    @discardableResult
    static func setLevel(_ percent: Int) -> Bool {
        guard let bridge, let display = target() else { return false }
        let value = Float(max(0, min(100, percent))) / 100
        return bridge.set(display, value) == 0
    }

    /// El paso de las teclas del Mac es 1/16; aquí se usa el mismo para que
    /// subir desde el móvil y desde el teclado se sientan igual.
    private static let step = 100.0 / 16.0

    @discardableResult
    static func nudge(up: Bool) -> Bool {
        guard let current = level() else { return false }
        let next = Double(current) + (up ? step : -step)
        return setLevel(Int(next.rounded()))
    }
}
