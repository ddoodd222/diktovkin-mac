import AppKit

/// Плашка у мерцающей каретки: видно, что программа слушает и куда встанет текст.
/// Окно сквозное для мыши и фокус не забирает.
final class Indicator {
    enum Look { case listening, thinking }

    static let shared = Indicator()

    /// Откуда брать, что рисовать. Ставит AppDelegate.
    var state: (() -> (look: Look, text: String, level: Float))?

    private var window: NSWindow?
    private var view: IndicatorView?
    private var draw: Timer?
    private var track: Timer?
    private var anchor: NSRect?          // последняя найденная каретка

    private let size = NSSize(width: 74, height: 24)

    func show() {
        guard Settings.showIndicator else { return }
        if window == nil { build() }
        anchor = Indicator.caretRect()
        refresh()
        place()
        window?.orderFrontRegardless()
        draw?.invalidate()
        draw = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.refresh() }
        // Каретку опрашиваем реже: это запрос в чужое приложение, он не бесплатный.
        track?.invalidate()
        track = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let r = Indicator.caretRect() { self.anchor = r }
            self.place()
        }
    }

    func hide() {
        draw?.invalidate(); draw = nil
        track?.invalidate(); track = nil
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
    }

    /// Встаем под кареткой. Не нашли ее — идем к мыши, чтобы плашка не пропадала совсем.
    private func place() {
        guard let window else { return }
        let caret = anchor ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        var o = NSPoint(x: caret.minX, y: caret.minY - size.height - 6)
        guard let visible = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame else { window.setFrameOrigin(o); return }
        if o.y < visible.minY + 4 { o.y = caret.maxY + 6 }      // у нижнего края уходим над кареткой
        o.x = min(max(visible.minX + 4, o.x), visible.maxX - size.width - 4)
        o.y = min(max(visible.minY + 4, o.y), visible.maxY - size.height - 4)
        window.setFrameOrigin(o)
    }

    // MARK: - Где сейчас каретка

    /// Прямоугольник каретки в координатах экрана. nil — приложение не отдает.
    private static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        let element = f as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let range = rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef) == .success,
               let b = boundsRef {
                var r = CGRect.zero
                if AXValueGetValue(b as! AXValue, .cgRect, &r), r.height > 1 { return flip(r) }
            }
        }
        return elementRect(element)
    }

    /// Запасной вариант: левый нижний угол самого поля ввода.
    private static func elementRect(_ element: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var origin = CGPoint.zero
        var box = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &box), box.height > 1 else { return nil }
        return flip(CGRect(origin: origin, size: box))
    }

    /// Универсальный доступ считает от верха главного экрана, AppKit — от низа.
    private static func flip(_ r: CGRect) -> NSRect {
        let primary = NSScreen.screens.first?.frame ?? .zero
        return NSRect(x: r.origin.x, y: primary.maxY - r.origin.y - r.height,
                      width: r.width, height: r.height)
    }
}

/// Рисует капсулу в стиле иконки: заливка, черная обводка, точка и подпись.
private final class IndicatorView: NSView {
    var look: Indicator.Look = .listening
    var text = "0:00"
    var level: Float = 0

    private let green = NSColor(srgbRed: 0.42, green: 0.91, blue: 0.20, alpha: 1)
    private let pink = NSColor(srgbRed: 1.00, green: 0.18, blue: 0.56, alpha: 1)

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (look == .listening ? green : pink).setFill()
        pill.fill()
        NSColor.black.setStroke()
        pill.lineWidth = 3
        pill.stroke()

        // Точка слева дышит в такт голосу: сразу видно, что микрофон слышит.
        let grow = CGFloat(min(1, max(0, level))) * 3
        let dot = 3 + (look == .listening ? grow : 0)
        let c = NSPoint(x: r.minX + 11, y: r.midY)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        s.draw(at: NSPoint(x: c.x + 10, y: r.midY - s.size().height / 2))
    }
}
