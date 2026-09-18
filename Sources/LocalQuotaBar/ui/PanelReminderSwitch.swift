import AppKit

/// 使用原生按钮处理状态、点击、键盘与辅助功能，绘制固定绿色的紧凑开关。
final class PanelReminderSwitch: NSButton {
    private static let switchSize = NSSize(width: 26, height: 15)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.pushOnPushOff)
        title = ""
        isBordered = false
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("低量提醒")
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.switchSize }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { trackRect }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    private var trackRect: NSRect {
        NSRect(x: (bounds.width - Self.switchSize.width) / 2,
               y: (bounds.height - Self.switchSize.height) / 2,
               width: Self.switchSize.width, height: Self.switchSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let color = state == .on ? PanelTheme.green : PanelTheme.tertiaryText
        color.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

        let diameter = track.height - 4
        let thumbX = state == .on ? track.maxX - diameter - 2 : track.minX + 2
        let thumb = NSRect(x: thumbX, y: track.minY + 2, width: diameter, height: diameter)
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.6).setFill()
        NSBezierPath(ovalIn: thumb).fill()
    }

    override func drawFocusRingMask() {
        let track = trackRect
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}
