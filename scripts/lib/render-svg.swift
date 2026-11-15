// SVG 한 장을 정사각형 PNG로 그린다(macOS AppKit의 SVG 지원 사용, 외부 도구 불필요).
// 사용법: swift render-svg.swift <입력.svg> <픽셀 크기> <출력.png>
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4, let pixels = Int(args[2]), pixels > 0 else {
    FileHandle.standardError.write(Data("usage: render-svg.swift <input.svg> <pixels> <output.png>\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[3])

guard let image = NSImage(contentsOf: input) else { fail("cannot read SVG: \(input.path)") }

// 처음부터 sRGB 비트맵에 그린다(기기 색 공간을 거치지 않아 어느 Mac에서 만들어도 같은 색).
guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let cg = CGContext(
          data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { fail("cannot create bitmap context") }
cg.interpolationQuality = .high

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let cgImage = cg.makeImage(),
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { fail("cannot encode PNG") }
do {
    try png.write(to: output)
} catch {
    fail(error.localizedDescription)
}
