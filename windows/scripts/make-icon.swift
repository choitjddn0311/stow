// Windows 앱 아이콘(Stow.ico)을 원본 SVG(windows/design/AppIcon.svg)로 만든다. macOS에서 실행한다(AppKit으로 SVG 렌더링).
//
//   swift windows/scripts/make-icon.swift
//
// 16~256px PNG를 그려 PNG 항목 ICO(Windows Vista 이후 지원)로 묶는다. 결과는 windows/src/Stow.App/Assets/Stow.ico.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("design/AppIcon.svg")
let output = root.appendingPathComponent("src/Stow.App/Assets/Stow.ico")
guard let image = NSImage(contentsOf: source) else { fatalError("SVG를 읽지 못함: \(source.path)") }

let sizes = [16, 20, 24, 32, 40, 48, 64, 256]
var pngs: [Data] = []
for size in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("비트맵을 만들지 못함") }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG로 바꾸지 못함") }
    pngs.append(png)
}

// ICO: 머리글(6바이트) + 항목(16바이트 × n) + PNG 데이터
var data = Data()
func put16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
func put32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
put16(0); put16(1); put16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, png) in zip(sizes, pngs) {
    data.append(UInt8(size % 256)); data.append(UInt8(size % 256)); data.append(0); data.append(0)
    put16(1); put16(32); put32(png.count); put32(offset)
    offset += png.count
}
pngs.forEach { data.append($0) }
try! data.write(to: output)
print("\(output.path) (\(data.count)바이트, \(sizes.map(String.init).joined(separator: "·"))px)")
