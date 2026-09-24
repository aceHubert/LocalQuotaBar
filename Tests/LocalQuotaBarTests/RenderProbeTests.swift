import AppKit
import XCTest
@testable import LocalQuotaBar

// 临时探针：渲染面板并取样关键区域颜色，与设计稿色板对比（不提交）。
final class RenderProbeTests: XCTestCase {
    @MainActor
    func testSampleColors() throws {
        _ = NSApplication.shared
        let controller = QuotaViewController.makeForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: PanelTheme.panelWidth, height: 600)
        controller.view.layoutSubtreeIfNeeded()

        let bounds = NSRect(x: 0, y: 0, width: PanelTheme.panelWidth, height: 600)
        let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: bounds))
        controller.view.cacheDisplay(in: bounds, to: rep)

        func colorAt(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            // 注意 y 轴：位图 y=0 在顶部
            guard let c = rep.colorAt(x: x, y: y) else { return (-1, -1, -1) }
            return (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        }

        // 单独取 solidBackground 的层：找到它
        let solid = controller.view.subviews.first { $0.layer?.backgroundColor != nil }
        print("[solid] found:", type(of: solid), (solid?.frame ?? .zero))
        if let solid {
            let rect = NSRect(origin: .zero, size: solid.bounds.size)
            let solidRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            solidRep.colorAt(x: 0, y: 0)
            // 直接读 layer backgroundColor（不经渲染）
            if let bg = solid.layer?.backgroundColor,
               let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB) {
                print("[solid] layer bg =", Int(round(c.redComponent*255)), Int(round(c.greenComponent*255)), Int(round(c.blueComponent*255)), "alpha", c.alphaComponent)
            }
            // 整面板缓存渲染里，view 完全在 solid 之上的区域：取 panelWidth-6, height-6（右下角，347 内）
            print("[color] 右下角 (316, 341):", colorAt(316, 341))
            print("[color] 右下角 (160, 340):", colorAt(160, 340))
        }

        // 层级诊断：solidBackground 自己渲染成什么色？
        func dump(_ view: NSView, _ depth: Int) {
            let cls = String(describing: type(of: view))
            let frame = view.frame
            var info = "[layer] \(String(repeating: "  ", count: depth))\(cls) f=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)))"
            if let bg = view.layer?.backgroundColor {
                let c = NSColor(cgColor: bg)?.usingColorSpace(.sRGB)
                info += " bg=rgb(\(Int(round((c?.redComponent ?? 0)*255))),\(Int(round((c?.greenComponent ?? 0)*255))),\(Int(round((c?.blueComponent ?? 0)*255)))) a=\(String(format: "%.2f", c?.alphaComponent ?? 0))"
            }
            if let material = (view as? NSVisualEffectView)?.material {
                info += " material=\(material.rawValue)"
            }
            print(info)
            for sub in view.subviews { dump(sub, depth + 1) }
        }
        dump(controller.view, 0)
    }
}
