#!/usr/bin/env swift
// Renders the app icon into BlackmagicCamImporter/AppIcon.icon, an Icon Composer bundle: a camera
// whose lens shows an arrow pointing down, the import, with a red recording light on its body.
// Layers are flat 1024pt PNGs: macOS adds the Liquid Glass, and Xcode derives the icons for
// older macOS releases from the same bundle.
// Usage: swift scripts/render-icon.swift

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let target = "BlackmagicCamImporter"

let canvas: CGFloat = 1024

// The camera body, with the viewfinder hump on its top left.
let cameraBody = CGRect(x: 192, y: 336, width: 640, height: 420)
let cameraRadius: CGFloat = 96
let hump = CGRect(x: 262, y: 268, width: 196, height: 110)
let humpRadius: CGFloat = 40
// The lens: a barrel ring around dark glass.
let lensCenter = CGPoint(x: 512, y: 546)
let barrelRadius: CGFloat = 186
let glassRadius: CGFloat = 146
// The arrow in the glass.
let arrowShaft = CGRect(x: 480, y: 446, width: 64, height: 120)
let arrowShaftRadius: CGFloat = 18
let arrowHeadTop: CGFloat = 548
let arrowHeadWidth: CGFloat = 184
let arrowTip: CGFloat = 644
let arrowHeadRadii: [CGFloat] = [14, 14, 18]
// The recording light.
let lightCenter = CGPoint(x: 746, y: 410)
let lightRadius: CGFloat = 30

let backgroundTop: UInt32 = 0x2EC4C6
let backgroundBottom: UInt32 = 0x0B4F63
let darkBackgroundTop: UInt32 = 0x14777D
let darkBackgroundBottom: UInt32 = 0x04242E
let shapeColor: UInt32 = 0xFFF5EC
let barrelColor: UInt32 = 0xCED4D1
let glassColor: UInt32 = 0x093F4F
let lightColor: UInt32 = 0xFF5B45

func rgb(_ hex: UInt32) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
  (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
}

func cgColor(_ hex: UInt32) -> CGColor {
  let color = rgb(hex)
  return CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
}

func iconColor(_ hex: UInt32) -> String {
  let color = rgb(hex)
  return "\"extended-srgb:" + [color.red, color.green, color.blue, 1].map { String(format: "%.5f", $0) }.joined(separator: ",") + "\""
}

// A transparent 1024pt layer with a top-left origin, like the Icon Composer canvas.
func layer(_ draw: (CGContext) -> Void) -> CGImage {
  let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.translateBy(x: 0, y: canvas)
  context.scaleBy(x: 1, y: -1)
  draw(context)
  return context.makeImage()!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
  CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
}

func roundedPolygon(_ points: [CGPoint], radii: [CGFloat]) -> CGPath {
  let path = CGMutablePath()
  let last = points[points.count - 1]
  path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
  for index in points.indices {
    path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: radii[index])
  }
  path.closeSubpath()
  return path
}

let camera = layer { context in
  context.setFillColor(cgColor(shapeColor))
  context.addPath(roundedRect(hump, humpRadius))
  context.addPath(roundedRect(cameraBody, cameraRadius))
  context.fillPath()
}

let barrel = layer { context in
  context.setFillColor(cgColor(barrelColor))
  context.fillEllipse(in: circle(lensCenter, barrelRadius))
}

let glass = layer { context in
  context.setFillColor(cgColor(glassColor))
  context.fillEllipse(in: circle(lensCenter, glassRadius))
}

let arrow = layer { context in
  let head = [
    CGPoint(x: lensCenter.x - arrowHeadWidth / 2, y: arrowHeadTop),
    CGPoint(x: lensCenter.x + arrowHeadWidth / 2, y: arrowHeadTop),
    CGPoint(x: lensCenter.x, y: arrowTip),
  ]
  context.setFillColor(cgColor(shapeColor))
  context.addPath(roundedRect(arrowShaft, arrowShaftRadius))
  context.addPath(roundedPolygon(head, radii: arrowHeadRadii))
  context.fillPath()
}

let light = layer { context in
  context.setFillColor(cgColor(lightColor))
  context.fillEllipse(in: circle(lightCenter, lightRadius))
}

// The first group draws on top, and so does the first layer inside a group. Each group gets
// its own glass, shadow and highlight, so the lens reads as a separate part of the camera.
let manifest = """
{
  "fill-specializations" : [
    { "value" : { "linear-gradient" : [\(iconColor(backgroundTop)), \(iconColor(backgroundBottom))] } },
    { "appearance" : "dark", "value" : { "linear-gradient" : [\(iconColor(darkBackgroundTop)), \(iconColor(darkBackgroundBottom))] } }
  ],
  "groups" : [
    {
      "name" : "Light",
      "layers" : [
        { "name" : "Light", "image-name" : "light.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.2 }
    },
    {
      "name" : "Lens",
      "layers" : [
        { "name" : "Arrow", "image-name" : "arrow.png", "glass" : true },
        { "name" : "Glass", "image-name" : "glass.png", "glass" : true },
        { "name" : "Barrel", "image-name" : "barrel.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.2 }
    },
    {
      "name" : "Camera",
      "layers" : [
        { "name" : "Camera", "image-name" : "camera.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : {
    "squares" : ["macOS"]
  }
}

"""

func write(_ image: CGImage, to url: URL) {
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("\(target)/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
write(camera, to: assets.appendingPathComponent("camera.png"))
write(barrel, to: assets.appendingPathComponent("barrel.png"))
write(glass, to: assets.appendingPathComponent("glass.png"))
write(arrow, to: assets.appendingPathComponent("arrow.png"))
write(light, to: assets.appendingPathComponent("light.png"))
try! manifest.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(bundle.path)")
