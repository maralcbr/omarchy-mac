import AppKit
import Foundation

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
let hex = CommandLine.arguments[3]
let value = UInt32(hex, radix: 16)!
let source = NSImage(contentsOf: sourceURL)!
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .none
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
NSColor(
  srgbRed: CGFloat((value >> 16) & 255) / 255,
  green: CGFloat((value >> 8) & 255) / 255,
  blue: CGFloat(value & 255) / 255, alpha: 1
).setFill()
NSBezierPath(
  roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
  xRadius: 180, yRadius: 180
).fill()
source.draw(
  in: NSRect(x: 224, y: 224, width: 576, height: 576),
  from: .zero, operation: .sourceOver, fraction: 1
)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: destinationURL)
