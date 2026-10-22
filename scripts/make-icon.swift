import AppKit

// Vector geometry shared with assets/domscan-icon.svg. No external image libraries.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("domscan-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

func color(_ hex: UInt32) -> CGColor {
  CGColor(red: CGFloat((hex >> 16) & 255) / 255,
          green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(_ side: Int, transparent: Bool = false) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  c.translateBy(x: 0, y: CGFloat(side))
  c.scaleBy(x: CGFloat(side) / 1024, y: -CGFloat(side) / 1024)
  let space = CGColorSpaceCreateDeviceRGB()
  if !transparent {
    let background = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960),
      cornerWidth: 220, cornerHeight: 220, transform: nil)
    c.saveGState(); c.addPath(background); c.clip()
    let gradient = CGGradient(colorsSpace: space,
      colors: [color(0x202640), color(0x0C1020)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 120, y: 70),
      end: CGPoint(x: 900, y: 960), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.addPath(CGPath(roundedRect: CGRect(x: 33, y: 33, width: 958, height: 958),
      cornerWidth: 219, cornerHeight: 219, transform: nil))
    c.setStrokeColor(color(0x343B59)); c.setLineWidth(2); c.strokePath()
  }
  let mint = color(0x70E6CE)
  c.setStrokeColor(mint); c.setLineWidth(24); c.setLineCap(.round); c.setLineJoin(.round)
  for corner: [CGPoint] in [
    [.init(x: 300,y: 216), .init(x: 196,y: 216), .init(x: 196,y: 320)],
    [.init(x: 724,y: 216), .init(x: 828,y: 216), .init(x: 828,y: 320)],
    [.init(x: 196,y: 704), .init(x: 196,y: 808), .init(x: 300,y: 808)],
    [.init(x: 724,y: 808), .init(x: 828,y: 808), .init(x: 828,y: 704)]
  ] { c.addLines(between: corner); c.strokePath() }
  let letter = CGMutablePath()
  letter.move(to: .init(x: 310,y: 300)); letter.addLine(to: .init(x: 470,y: 300))
  letter.addCurve(to: .init(x: 714,y: 512), control1: .init(x: 630,y: 300), control2: .init(x: 714,y: 380))
  letter.addCurve(to: .init(x: 470,y: 724), control1: .init(x: 714,y: 644), control2: .init(x: 630,y: 724))
  letter.addLine(to: .init(x: 310,y: 724)); letter.closeSubpath()
  letter.move(to: .init(x: 398,y: 388)); letter.addLine(to: .init(x: 470,y: 388))
  letter.addCurve(to: .init(x: 626,y: 512), control1: .init(x: 570,y: 388), control2: .init(x: 626,y: 440))
  letter.addCurve(to: .init(x: 470,y: 636), control1: .init(x: 626,y: 584), control2: .init(x: 570,y: 636))
  letter.addLine(to: .init(x: 398,y: 636)); letter.closeSubpath()
  c.saveGState(); c.addPath(letter); c.clip(using: .evenOdd)
  let violet = CGGradient(colorsSpace: space,
    colors: [color(0xDFD4FF), color(0xAE8CFF), color(0x8660ED)] as CFArray,
    locations: [0, 0.52, 1])!
  c.drawLinearGradient(violet, start: .init(x: 310,y: 300), end: .init(x: 714,y: 724),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  c.restoreGState()
  c.setStrokeColor(mint); c.setLineWidth(12)
  c.addLines(between: [.init(x: 470,y: 472), .init(x: 470,y: 510)])
  c.strokePath()
  c.addLines(between: [.init(x: 446,y: 548), .init(x: 446,y: 510),
    .init(x: 544,y: 510), .init(x: 544,y: 548)])
  c.strokePath()
  c.setFillColor(mint)
  for r in [CGRect(x: 450,y: 432,width: 40,height: 40),
            CGRect(x: 426,y: 548,width: 40,height: 40), CGRect(x: 524,y: 548,width: 40,height: 40)] {
    c.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); c.fillPath()
  }
  return rep.representation(using: .png, properties: [:])!
}

for logical in [16, 32, 128, 256, 512] {
  try render(logical).write(to: iconset.appendingPathComponent("icon_\(logical)x\(logical).png"))
  try render(logical * 2).write(to: iconset.appendingPathComponent("icon_\(logical)x\(logical)@2x.png"))
}
try render(1024).write(to: root.appendingPathComponent("assets/domscan-icon.png"))
try render(1024, transparent: true).write(to: root.appendingPathComponent("assets/domscan-mark.png"))
try render(128).write(to: root.appendingPathComponent("Resources/BrandMark.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated SVG-matched PNG, ICNS and in-app brand assets")
