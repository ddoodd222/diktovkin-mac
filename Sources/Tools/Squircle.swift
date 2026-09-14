import AppKit

// Обрезает картинку по скруглённому квадрату macOS и оставляет поля по сетке Apple.
// Запуск: squircle вход.png выход.png [доля_плитки]
let args = CommandLine.arguments
guard args.count > 2, let src = NSImage(contentsOfFile: args[1]) else {
    print("squircle вход.png выход.png [0.80]")
    exit(1)
}

let side: CGFloat = 1024
let fill = CGFloat(args.count > 3 ? Double(args[3]) ?? 0.805 : 0.805)   // 824 из 1024 — сетка Apple
let tile = side * fill
let r = tile / 2, c = side / 2
let n: CGFloat = 5                                                       // 4 — почти круг, 8 — почти квадрат

let out = NSImage(size: NSSize(width: side, height: side))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let path = NSBezierPath()
for i in 0...720 {
    let t = CGFloat(i) / 720 * 2 * .pi
    let cs = cos(t), sn = sin(t)
    let x = c + r * pow(abs(cs), 2 / n) * (cs < 0 ? -1 : 1)
    let y = c + r * pow(abs(sn), 2 / n) * (sn < 0 ? -1 : 1)
    if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
}
path.close()
path.addClip()
src.draw(in: NSRect(x: c - r, y: c - r, width: tile, height: tile))
out.unlockFocus()

let tiff = out.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: args[2]))
print("✓ \(args[2])")
