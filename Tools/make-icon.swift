#!/usr/bin/swift
import AppKit

// Genera Resources/AppIcon.icns a partir del icono del panel
// (Sources/iDeck/Web/icon.svg), para que el Mac y el móvil lleven el mismo.
// Lo pinta en la rejilla de iconos de macOS: lienzo de 1024 con la placa de
// 824 centrada y una sombra suave debajo.
//
// Uso, desde la raíz del proyecto:
//   swift Tools/make-icon.swift
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

let svgPath = "Sources/iDeck/Web/icon.svg"
let outDir = "Resources/AppIcon.iconset"
guard let svg = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else {
    fatalError("No se puede leer \(svgPath). ¿Estás en la raíz del proyecto?")
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    let plate = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 24 * k
    shadow.set()
    svg.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
