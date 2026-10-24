import AppKit

/// Область фото: одна половина на весь розмір, а в режимі порівняння — дві поруч.
final class SplitStageView: NSView {
    let left = ImageCanvasView()
    let right = ImageCanvasView()
    private static let gap: CGFloat = 2

    var isSplit = false {
        didSet {
            guard isSplit != oldValue else { return }
            right.isHidden = !isSplit
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor   // лінія між половинами
        addSubview(left)
        addSubview(right)
        right.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard isSplit else {
            left.frame = bounds
            return
        }
        let w = ((bounds.width - Self.gap) / 2).rounded(.down)
        left.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        right.frame = NSRect(x: w + Self.gap, y: 0, width: bounds.width - w - Self.gap, height: bounds.height)
    }
}
