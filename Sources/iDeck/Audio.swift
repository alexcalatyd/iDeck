import AudioToolbox
import CoreAudio
import Foundation

/// El volumen de salida por CoreAudio, no por AppleScript.
///
/// `set volume output volume N` cuantiza al paso del hardware (los altavoces
/// internos tienen 16), así que el valor que se leía de vuelta no era el que
/// había mandado el móvil y el slider pegaba un salto hacia atrás. La
/// propiedad `VirtualMainVolume` es un float que devuelve exactamente lo que
/// se escribe, no cuesta un proceso nuevo en cada lectura, y además avisa de
/// los cambios hechos desde el propio Mac.
final class AudioOutput {
    static let shared = AudioOutput()

    /// Se dispara cuando el volumen o el silencio cambian fuera de iDeck.
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ideck.audio")
    private var device = AudioObjectID(kAudioObjectUnknown)
    /// Los bloques se guardan para poder quitarlos al cambiar de dispositivo.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {
        rebind()
        observeDefaultDeviceChanges()
    }

    // MARK: - Lectura

    /// 0–100. El móvil trabaja en porcentaje; dentro todo es 0–1.
    func volume() -> Int {
        guard let scalar = scalarVolume() else { return 0 }
        return Int((scalar * 100).rounded())
    }

    func isMuted() -> Bool {
        let device = currentDevice
        guard device != kAudioObjectUnknown else { return false }
        var address = Self.address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else {
            // Sin propiedad de silencio, volumen cero es lo más parecido.
            return (scalarVolume() ?? 0) <= 0.0001
        }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    // MARK: - Escritura

    func setVolume(_ percent: Int) {
        let scalar = Float32(max(0, min(100, percent))) / 100
        let device = currentDevice
        guard device != kAudioObjectUnknown else { return }

        var main = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if write(scalar, to: device, at: &main) {
            // Subir el volumen con el altavoz silenciado no se oiría: en el
            // Mac el propio control de volumen también levanta el silencio.
            if scalar > 0, isMuted() { setMuted(false) }
            return
        }

        // Agregados y algunos USB no exponen el volumen virtual; ahí hay que
        // ir canal por canal.
        for channel in UInt32(1)...2 {
            var perChannel = Self.address(kAudioDevicePropertyVolumeScalar, element: channel)
            _ = write(scalar, to: device, at: &perChannel)
        }
        if scalar > 0, isMuted() { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        let device = currentDevice
        guard device != kAudioObjectUnknown else { return }
        var address = Self.address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func toggleMuted() { setMuted(!isMuted()) }

    // MARK: - Interno

    private var currentDevice: AudioObjectID {
        lock.lock()
        defer { lock.unlock() }
        return device
    }

    private func scalarVolume() -> Float32? {
        let device = currentDevice
        guard device != kAudioObjectUnknown else { return nil }

        var main = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if let value = read(from: device, at: &main) { return value }

        var total: Float32 = 0
        var channels: Float32 = 0
        for channel in UInt32(1)...2 {
            var perChannel = Self.address(kAudioDevicePropertyVolumeScalar, element: channel)
            if let value = read(from: device, at: &perChannel) {
                total += value
                channels += 1
            }
        }
        return channels > 0 ? total / channels : nil
    }

    private func read(from device: AudioObjectID, at address: inout AudioObjectPropertyAddress) -> Float32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func write(_ value: Float32, to device: AudioObjectID, at address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    // MARK: - Dispositivo y avisos

    private static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Cambiar de altavoces a auriculares cambia el objeto de audio: hay que
    /// volver a enganchar los avisos al nuevo.
    private func observeDefaultDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
            self?.onChange?()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func rebind() {
        let next = Self.defaultOutputDevice()

        lock.lock()
        let previous = device
        let staleListeners = listeners
        device = next
        listeners = []
        lock.unlock()

        for (object, address, block) in staleListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        guard next != kAudioObjectUnknown, next != previous || staleListeners.isEmpty else { return }

        var fresh: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute,
        ]
        for selector in selectors {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            guard AudioObjectAddPropertyListenerBlock(next, &address, queue, block) == noErr else { continue }
            fresh.append((next, address, block))
        }

        lock.lock()
        listeners = fresh
        lock.unlock()
    }
}
