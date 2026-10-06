#!/usr/bin/env swift
// Renders the README banner, docs/banner.png, at 2x: the icon, the name, a tagline and
// feature chips on the left, the real window on the right.
// The .icon is rendered through Icon Composer's ictool, so it has the real Liquid Glass.
// The window is docs/screenshot-dark.png, made by scripts/screenshot.sh.
// Usage: swift scripts/render-banner.swift

import AppKit
import SwiftUI

let title = "Importer for\nBlackmagic Cam"
let tagline = "Copy the videos you shot with\nBlackmagic Cam from your iPhone\nto your Mac, over USB."
let chips = ["Checked byte for byte", "Preview first", "Free"]
let size = CGSize(width: 1280, height: 560)
// Where the window's top-left corner sits, and how much it's scaled down.
let windowOrigin = CGPoint(x: 560, y: 76)
let windowScale: CGFloat = 0.68

// The app icon's background, a bit deeper.
let backgroundTop = Color(hex: 0x0A5563)
let backgroundBottom = Color(hex: 0x021A21)
let glow = Color(hex: 0x12909E)
let muted = Color.white.opacity(0.74)

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSource = root.appending(path: "BlackmagicCamImporter/AppIcon.icon")
let screenshot = root.appending(path: "docs/screenshot-dark.png")
let output = root.appending(path: "docs/banner.png")
// scripts/screenshot.sh leaves a 48pt margin around the window for its shadow.
let shadowMargin: CGFloat = 48

extension Color {
  init(hex: UInt32) {
    self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}

func run(_ tool: String, _ arguments: [String]) -> String {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(filePath: tool)
  process.arguments = arguments
  process.standardOutput = pipe
  try! process.run()
  process.waitUntilExit()
  return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderIcon() -> NSImage {
  let developer = run("/usr/bin/xcode-select", ["-p"])
  let ictool = URL(filePath: developer).deletingLastPathComponent()
    .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool").path
  let file = FileManager.default.temporaryDirectory.appending(path: "blackmagic-importer-banner-icon.png")
  _ = run(ictool, [
    iconSource.path, "--export-image", "--output-file", file.path, "--platform", "macOS",
    "--rendition", "Default", "--width", "512", "--height", "512", "--scale", "2",
  ])
  return NSImage(contentsOf: file)!
}

struct Banner: View {
  let icon: NSImage
  let window: NSImage

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
      RadialGradient(colors: [glow.opacity(0.45), glow.opacity(0)], center: UnitPoint(x: 0.14, y: 0.3), startRadius: 0, endRadius: 420)

      // The screenshot is 2x, so its size in points is half its pixels.
      Image(nsImage: window)
        .resizable()
        .interpolation(.high)
        .frame(width: CGFloat(window.representations[0].pixelsWide) / 2 * windowScale, height: CGFloat(window.representations[0].pixelsHigh) / 2 * windowScale)
        .offset(x: windowOrigin.x - shadowMargin * windowScale, y: windowOrigin.y - shadowMargin * windowScale)

      VStack(alignment: .leading, spacing: 0) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: 112, height: 112)
          .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        Text(title)
          .font(.system(size: 52, weight: .bold))
          .tracking(-1.2)
          .lineSpacing(-4)
          .foregroundStyle(.white)
          .padding(.top, 22)
        Text(tagline)
          .font(.system(size: 22, weight: .regular))
          .lineSpacing(4)
          .foregroundStyle(muted)
          .padding(.top, 12)
        HStack(spacing: 10) {
          ForEach(chips, id: \.self) { chip in
            Text(chip)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, 13)
              .padding(.vertical, 7)
              .background(.white.opacity(0.1), in: .capsule)
              .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
          }
        }
        .padding(.top, 24)
      }
      .offset(x: 70, y: 62)
    }
    .frame(width: size.width, height: size.height)
    .clipShape(.rect(cornerRadius: 28))
  }
}

MainActor.assumeIsolated {
  let renderer = ImageRenderer(content: Banner(icon: renderIcon(), window: NSImage(contentsOf: screenshot)!))
  renderer.scale = 2
  // ImageRenderer produces 16 bits per channel. Redraw at 8 bits for a small PNG.
  let image = renderer.cgImage!
  let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: output)
  print("Wrote \(output.path)")
}
