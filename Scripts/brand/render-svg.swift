// Rendert eine SVG-Datei mit AppKit in ein quadratisches PNG.
// Aufruf: swift Scripts/brand/render-svg.swift <eingabe.svg> <ausgabe.png> <pixel> [--opaque]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 4, let pixels = Int(arguments[3]) else {
    FileHandle.standardError.write(Data("Aufruf: render-svg.swift <eingabe.svg> <ausgabe.png> <pixel> [--opaque]\n".utf8))
    exit(2)
}
let opaque = arguments.contains("--opaque")
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("SVG konnte nicht geladen werden: \(arguments[1])\n".utf8))
    exit(1)
}

// App-Store-Icons für iOS dürfen keinen Alphakanal haben. NSGraphicsContext kann nicht in eine
// RGB-Bitmap ohne Alpha zeichnen (liefert nil → schwarzes Bild), daher direkt über CGContext.
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
guard let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: alphaInfo.rawValue
) else {
    FileHandle.standardError.write(Data("Grafikkontext konnte nicht erzeugt werden.\n".utf8))
    exit(1)
}
context.interpolationQuality = .high
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let cgImage = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
