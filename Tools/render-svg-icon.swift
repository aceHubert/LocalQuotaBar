import AppKit
import Foundation

// 将定稿 SVG 原样渲染为透明 PNG，供 macOS 多尺寸图标打包使用。
guard CommandLine.arguments.count == 3 else {
    fputs("用法：swift Tools/render-svg-icon.swift <输入.svg> <输出.png>\n", stderr)
    exit(1)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let size = 1024

guard let image = NSImage(contentsOf: source), image.isValid,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("无法解码 SVG 或创建图标画布。\n", stderr)
    exit(1)
}

// 固定像素画布，避免屏幕缩放倍率影响导出尺寸；清空底色以保留透明圆角。
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
bounds.fill(using: .copy)
image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法编码 PNG 图标。\n", stderr)
    exit(1)
}

do {
    try png.write(to: destination, options: .atomic)
    print("已渲染透明图标：\(destination.lastPathComponent)（\(size)×\(size)）")
} catch {
    fputs("保存图标失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
