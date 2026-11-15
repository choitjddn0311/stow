// SVG 한 장을 정사각형 PNG로 그린다(macOS AppKit의 SVG 지원 사용, 외부 도구 불필요).
// 사용법: swift render-svg.swift <입력.svg> <픽셀 크기> <출력.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let pixels = Int(args[2]), pixels > 0 else {
    FileHandle.standardError.write(Data("usage: render-svg.swift <input.svg> <pixels> <output.png>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[3])

guard let image = NSImage(contentsOf: input) else {
    FileHandle.standardError.write(Data("error: cannot read SVG: \(input.path)\n".utf8))
    exit(1)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
// 포인트 크기를 픽셀 크기와 같게 두어 1x로 그린다(PNG에 72dpi로 기록).
rep.size = NSSize(width: pixels, height: pixels)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context
context.imageInterpolation = .high
let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
NSColor.clear.set()
rect.fill()
image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// sRGB로 태그해 기록한다.
guard let srgb = rep.converting(to: .sRGB, renderingIntent: .default),
      let png = srgb.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: output)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
