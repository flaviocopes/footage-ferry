// Captures the real app window for the README, in light and dark, into
// <folder>/screenshot-light.png and <folder>/screenshot-dark.png: made-up clips with drawn
// thumbnails, halfway through an import. scripts/screenshot.sh compiles it with the app's
// sources, in place of the @main file, with -D SCREENSHOT for AppModel.stage.

import AppKit
import SwiftUI

let output = URL(filePath: CommandLine.arguments[1])
let width: CGFloat = 1000
let height: CGFloat = 640

@MainActor
enum Demo {
  static let model = AppModel()

  static func content() -> some View {
    ContentView(model: model)
  }

  static func prepare() async {
    model.setDestination(URL.temporaryDirectory.appending(path: "blackmagic-importer-screenshot/Blackmagic Cam"))
    await model.connect(name: "iPhone 16 Pro", files: DemoFiles.sample(megabytes: 60...900, bytesPerSecond: nil))
    let videos = model.videos
    var states: [Video.ID: VideoState] = [:]
    for (index, video) in videos.enumerated() {
      states[video.id] = switch index {
      case 0..<3: .imported
      case 3: .copying(0.62)
      case 4, 5: .waiting
      default: .onPhone
      }
    }
    let batched = videos.prefix(6)
    let finished = videos.prefix(3).reduce(Int64(0)) { $0 + $1.size }
    let current = Int64(Double(videos[3].size) * 0.62)
    let batch = Batch(
      count: batched.count,
      totalBytes: batched.reduce(0) { $0 + $1.size },
      started: Date() - Double(finished + current) / 41_500_000,
      index: 3,
      current: videos[3].name,
      finishedBytes: finished,
      currentBytes: current,
      downloadedBytes: finished + current
    )
    let thumbnails = Dictionary(uniqueKeysWithValues: videos.enumerated().map { ($1.id, landscape($0)) })
    model.stage(states: states, batch: batch, thumbnails: thumbnails)
    try? await Task.sleep(for: .seconds(1))
  }
}

/// A made-up frame: sky, sun and two rows of hills, in one of a few times of day.
func landscape(_ index: Int) -> NSImage {
  let palettes: [(sky: [UInt32], far: UInt32, near: UInt32, sun: UInt32)] = [
    ([0x2B5876, 0xF7B267], 0x4E4376, 0x2A2245, 0xFFE29A),
    ([0x4FA3E0, 0xCFEFFF], 0x5E9C76, 0x2F6B4F, 0xFFFFFF),
    ([0x1D2B64, 0xF8CDDA], 0x5B4B8A, 0x2E2550, 0xFFD3B6),
    ([0x0F7C8C, 0xA8E6CF], 0x3D7A6E, 0x1E4D45, 0xFFF5D1),
    ([0xFF7E5F, 0xFEB47B], 0xA0522D, 0x5C2E1E, 0xFFF1C1),
    ([0x6A85B6, 0xBAC8E0], 0x4B5D80, 0x2C3A57, 0xF4F7FF),
  ]
  let palette = palettes[index % palettes.count]
  var generator = SeededGenerator(seed: UInt64(index + 11))
  let size = CGSize(width: 240, height: 135)
  let image = NSImage(size: size, flipped: false) { rect in
    let context = NSGraphicsContext.current!.cgContext
    let colors = palette.sky.map { color($0) } as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.height), end: .zero, options: [])
    let sunX = CGFloat.random(in: 50...190, using: &generator)
    context.setFillColor(color(palette.sun, alpha: 0.9))
    context.fillEllipse(in: CGRect(x: sunX, y: 70, width: 26, height: 26))
    for (layer, base) in [(palette.far, 62.0), (palette.near, 34.0)] {
      context.setFillColor(color(layer))
      context.move(to: .zero)
      var x: CGFloat = 0
      context.addLine(to: CGPoint(x: 0, y: base))
      while x < rect.width {
        let step = CGFloat.random(in: 30...60, using: &generator)
        context.addQuadCurve(
          to: CGPoint(x: x + step, y: base + CGFloat.random(in: -10...12, using: &generator)),
          control: CGPoint(x: x + step / 2, y: base + CGFloat.random(in: 4...26, using: &generator)))
        x += step
      }
      context.addLine(to: CGPoint(x: rect.width, y: 0))
      context.closePath()
      context.fillPath()
    }
    return true
  }
  return image
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

@main
enum Screenshot {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let host = NSHostingView(rootView: Demo.content().frame(width: width, height: height))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = ActiveWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = host
    window.center()
    _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await capture(window) }
      }
    }
    app.run()
  }
}

/// Draws as the active window even when another app is frontmost, which is the case
/// when this runs from a terminal: macOS doesn't let it take focus.
final class ActiveWindow: NSWindow {
  override var isKeyWindow: Bool { true }
  override var isMainWindow: Bool { true }
  @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { true }
  @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
  @objc(_hasKeyAppearance) func hasKeyAppearance() -> Bool { true }
  @objc(_hasMainAppearance) func hasMainAppearance() -> Bool { true }
}

@MainActor
func capture(_ window: NSWindow) async {
  await Demo.prepare()
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    NSApp.appearance = NSAppearance(named: appearance)
    try? await Task.sleep(for: .seconds(1.5))
    write(framed(snapshot(window)), to: output.appending(path: "screenshot-\(name).png"))
  }
  NSApp.terminate(nil)
}

/// The whole window, title bar included, at 2x even on a 1x screen like the test VM's.
@MainActor
func snapshot(_ window: NSWindow) -> CGImage {
  let view = window.contentView!.superview!
  let scale: CGFloat = 2
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = view.bounds.size
  view.cacheDisplay(in: view.bounds, to: rep)
  return rep.cgImage!
}

/// Rounds the corners like a window and adds a soft shadow on a transparent 48pt margin.
func framed(_ image: CGImage) -> CGImage {
  let scale: CGFloat = 2
  let margin = 48 * scale
  let radius = 10 * scale
  let size = CGSize(width: CGFloat(image.width) + 2 * margin, height: CGFloat(image.height) + 2 * margin)
  let context = CGContext(
    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  let rect = CGRect(x: margin, y: margin, width: CGFloat(image.width), height: CGFloat(image.height))
  let window = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.32))
  context.addPath(window)
  context.setFillColor(CGColor(gray: 0.5, alpha: 1))
  context.fillPath()
  context.restoreGState()

  context.addPath(window)
  context.clip()
  context.draw(image, in: rect)
  context.resetClip()
  context.addPath(window)
  context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
  context.setLineWidth(1)
  context.strokePath()
  return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let rep = NSBitmapImageRep(cgImage: image)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
  print(url.path)
}
