import AppKit

/// Плашка у курсора мыши: видно, что программа слушает, даже когда строка меню далеко.
/// Держится всегда в одном месте относительно курсора — так понятнее, чем прыгать за кареткой.
/// Окно сквозное для мыши и фокус не забирает.
final class Indicator {
    enum Look { case listening, thinking }

    static let shared = Indicator()

    /// Откуда брать, что рисовать. Ставит AppDelegate.
    var state: (() -> (look: Look, text: String, level: Float))?

    private var window: NSWindow?
    private var view: IndicatorView?
    private var draw: Timer?
    private var monitor: Any?

    private var size = NSSize(width: 58, height: 22)

    func show() {
        guard Settings.showIndicator else { return }
        if window == nil { build() }
        refresh()
        place()
        window?.orderFrontRegardless()

        draw?.invalidate()
        draw = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.place()
        }
        // Движение ловим событием, а не опросом: плашка едет без задержки.
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in self?.place() }
        }
    }

    func hide() {
        draw?.invalidate(); draw = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true          // курсор проходит насквозь
        w.level = .screenSaver               // поверх полноэкранных окон
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = IndicatorView(frame: NSRect(origin: .zero, size: size))
        w.contentView = v
        window = w
        view = v
    }

    private func refresh() {
        guard let view, let s = state?() else { return }
        view.look = s.look
        view.text = s.text
        view.level = s.level
        view.needsDisplay = true
        // Ширина по надписи: иначе справа остается пустое поле.
        let want = view.preferredWidth
        if abs(want - size.width) > 0.5, let window {
            size.width = want
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            place()
        }
    }

    /// Плашка идет справа снизу от курсора и не вылезает за край экрана.
    private func place() {
        guard let window else { return }
        let p = NSEvent.mouseLocation
        var o = NSPoint(x: p.x + 16, y: p.y - size.height - 8)
        if let visible = NSScreen.screens.first(where: { $0.frame.contains(p) })?.visibleFrame {
            if o.y < visible.minY + 4 { o.y = p.y + 14 }       // у нижнего края уходим над курсором
            o.x = min(max(visible.minX + 4, o.x), visible.maxX - size.width - 4)
            o.y = min(max(visible.minY + 4, o.y), visible.maxY - size.height - 4)
        }
        window.setFrameOrigin(o)
    }
}

/// Рисует капсулу в стиле иконки: заливка, черная обводка, точка и подпись.
private final class IndicatorView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    private static let padLeft: CGFloat = 8, dotSlot: CGFloat = 8, gap: CGFloat = 6, padRight: CGFloat = 10

    var look: Indicator.Look = .listening
    var text = "0:00"
    var level: Float = 0

    var preferredWidth: CGFloat {
        let w = NSAttributedString(string: text, attributes: [.font: IndicatorView.font]).size().width
        return (IndicatorView.padLeft + IndicatorView.dotSlot + IndicatorView.gap + w
                + IndicatorView.padRight).rounded()
    }

    private let green = NSColor(srgbRed: 0.42, green: 0.91, blue: 0.20, alpha: 1)
    private let pink = NSColor(srgbRed: 1.00, green: 0.18, blue: 0.56, alpha: 1)

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (look == .listening ? green : pink).setFill()
        pill.fill()
        NSColor.black.setStroke()
        pill.lineWidth = 2.5
        pill.stroke()

        // Точка слева дышит в такт голосу: сразу видно, что микрофон слышит.
        let grow = CGFloat(min(1, max(0, level))) * 2.5
        let dot = 2.8 + (look == .listening ? grow : 0)
        let c = NSPoint(x: IndicatorView.padLeft + IndicatorView.dotSlot / 2, y: r.midY)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)).fill()

        let s = NSAttributedString(string: text,
                                   attributes: [.font: IndicatorView.font, .foregroundColor: NSColor.black])
        s.draw(at: NSPoint(x: IndicatorView.padLeft + IndicatorView.dotSlot + IndicatorView.gap,
                           y: r.midY - s.size().height / 2))
    }
}
