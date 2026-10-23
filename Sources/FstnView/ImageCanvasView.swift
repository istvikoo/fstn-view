import AppKit
import QuartzCore

/// Область перегляду: показ через CALayer (GPU), вписування, 100%, зум і перетягування.
final class ImageCanvasView: NSView {
    var onNavigate: ((Int) -> Void)?
    var onZoomChanged: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onDropURL: ((URL) -> Void)?
    /// Меню на правий клік по фото.
    var onContextMenu: (() -> NSMenu?)?

    private let imageLayer = CALayer()
    private let hint = NSTextField(labelWithString: "")
    /// Рядок зверху зліва, як у FastStone: ім'я, розміри, Мп, вага, номер, масштаб.
    private let overlay = NSTextField(labelWithString: "")

    /// Розмір оригіналу в пікселях.
    private(set) var imageSize: CGSize = .zero
    /// Поворот на екрані: 0…3 — кількість поворотів на 90° за годинниковою стрілкою.
    private(set) var rotation = 0
    /// Розмір фото з урахуванням повороту.
    private var viewSize: CGSize {
        rotation % 2 == 1 ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
    }

    func setRotation(_ value: Int) {
        rotation = ((value % 4) + 4) % 4
        isFit = true
        layoutImage()
        onZoomChanged?()
    }
    private(set) var isFit = true
    /// Масштаб: скільки фізичних пікселів екрана припадає на 1 піксель зображення (1 = 100%).
    private(set) var zoom: CGFloat = 1
    /// Точка зображення (у пікселях, y згори вниз), що знаходиться в центрі області.
    private var center: CGPoint = .zero

    /// Масштаб і точка кадру (частка ширини й висоти), щоб показати наступне фото так само.
    struct ViewState {
        let zoom: CGFloat
        let relativeCenter: CGPoint
    }

    /// Поточний зум, якщо фото збільшене (nil — вписане).
    var viewState: ViewState? {
        let size = viewSize
        guard !isFit, hasImage, size.width > 0, size.height > 0 else { return nil }
        return ViewState(zoom: zoom, relativeCenter: CGPoint(x: center.x / size.width, y: center.y / size.height))
    }

    private var lastDrag: NSPoint?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    private var temporaryZoom = false
    private var mouseDownTime: TimeInterval = 0
    private var cursorPushed = false
    private var scrollAccum: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 15)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])

        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 2
        overlay.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        overlay.textColor = NSColor(srgbRed: 0.35, green: 1.0, blue: 0.35, alpha: 1)
        overlay.shadow = shadow
        overlay.lineBreakMode = .byTruncatingMiddle
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            overlay.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        registerForDraggedTypes([.fileURL])
    }

    func setOverlayText(_ text: String) {
        overlay.stringValue = text
        overlay.isHidden = text.isEmpty || !isOverlayEnabled
    }

    var isOverlayEnabled = true {
        didSet { overlay.isHidden = overlay.stringValue.isEmpty || !isOverlayEnabled }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasImage: Bool { imageLayer.contents != nil }

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var pointsPerPixel: CGFloat { zoom / backing }

    /// Масштаб «вписати»: не збільшуємо маленькі зображення понад 100%.
    var fitZoom: CGFloat {
        let size = viewSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, min(bounds.width / size.width, bounds.height / size.height) * backing)
    }

    // MARK: - Публічне API

    func showHint(_ text: String) {
        imageLayer.contents = nil
        imageSize = .zero
        hint.stringValue = text
        hint.isHidden = false
        onZoomChanged?()
    }

    /// `keeping` — показати нове фото в тому ж масштабі й точці, що й попереднє (порівняння серії).
    func setImage(_ image: CGImage, size: CGSize, resetView: Bool, keeping state: ViewState? = nil) {
        hint.isHidden = true
        imageLayer.contents = image
        if resetView || imageSize != size {
            imageSize = size
            isFit = true
            if let state, state.zoom > fitZoom + 0.0001 {
                isFit = false
                zoom = state.zoom
                center = CGPoint(x: state.relativeCenter.x * viewSize.width,
                                 y: state.relativeCenter.y * viewSize.height)
            }
        }
        layoutImage()
        onZoomChanged?()
    }

    /// Підміна прев'ю на повну роздільність без зміни масштабу і позиції.
    func replaceImage(_ image: CGImage) {
        imageLayer.contents = image
    }

    func fit() {
        isFit = true
        layoutImage()
        onZoomChanged?()
    }

    func setZoom(_ newZoom: CGFloat, anchor: NSPoint? = nil) {
        guard hasImage else { return }
        let a = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let pinned = imagePoint(at: a)
        let clamped = min(max(newZoom, 0.02), 32)
        if clamped <= fitZoom + 0.0001 {
            fit()
            return
        }
        zoom = clamped
        isFit = false
        let ppp = pointsPerPixel
        center = CGPoint(x: pinned.x - (a.x - bounds.midX) / ppp,
                         y: pinned.y + (a.y - bounds.midY) / ppp)
        layoutImage()
        onZoomChanged?()
    }

    func zoomStep(_ factor: CGFloat) {
        setZoom(zoom * factor)
    }

    /// Перемикання «вписати ↔ 100%» (подвійний клік, клавіша Z).
    func toggleActualSize(at point: NSPoint? = nil) {
        if isFit {
            setZoom(1, anchor: point)
        } else {
            fit()
        }
    }

    // MARK: - Розкладка

    private func imagePoint(at p: NSPoint) -> CGPoint {
        let ppp = pointsPerPixel
        return CGPoint(x: center.x + (p.x - bounds.midX) / ppp,
                       y: center.y - (p.y - bounds.midY) / ppp)
    }

    private func clampCenter() {
        let ppp = pointsPerPixel
        let halfW = bounds.width / 2 / ppp
        let halfH = bounds.height / 2 / ppp
        let size = viewSize
        center.x = size.width <= halfW * 2 ? size.width / 2 : min(max(center.x, halfW), size.width - halfW)
        center.y = size.height <= halfH * 2 ? size.height / 2 : min(max(center.y, halfH), size.height - halfH)
    }

    private func layoutImage() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        if isFit {
            zoom = fitZoom
            center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        }
        clampCenter()
        let ppp = pointsPerPixel
        let scale = backing
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let rect = CGRect(
            x: snap(bounds.midX - center.x * ppp),
            y: snap(bounds.midY - (viewSize.height - center.y) * ppp),
            width: snap(viewSize.width * ppp),
            height: snap(viewSize.height * ppp)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Шар має розмір неповернутого фото; поворот — через transform навколо центру
        imageLayer.setAffineTransform(.identity)
        imageLayer.bounds = CGRect(x: 0, y: 0,
                                   width: rotation % 2 == 1 ? rect.height : rect.width,
                                   height: rotation % 2 == 1 ? rect.width : rect.height)
        imageLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 2))
        imageLayer.magnificationFilter = zoom >= 2 ? .nearest : .linear
        imageLayer.minificationFilter = .trilinear
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutImage()
        if isFit { onZoomChanged?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutImage()
        onZoomChanged?()
    }

    // MARK: - Миша і трекпад

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = event.locationInWindow
        mouseDownPoint = event.locationInWindow
        mouseDownTime = event.timestamp
        didDrag = false
        // Як у FastStone: поки кнопка затиснута — 100% у точці натискання
        if isFit, hasImage, fitZoom < 1 {
            temporaryZoom = true
            setZoom(1, anchor: convert(event.locationInWindow, from: nil))
        }
        if !isFit {
            NSCursor.closedHand.push()
            cursorPushed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let p = event.locationInWindow
        // Невеликий зсув миші під час кліку не вважаємо перетягуванням
        if let start = mouseDownPoint, hypot(p.x - start.x, p.y - start.y) > 4 { didDrag = true }
        guard !isFit else { return }
        let ppp = pointsPerPixel
        center.x -= (p.x - last.x) / ppp
        center.y += (p.y - last.y) / ppp
        lastDrag = p
        layoutImage()
    }

    override func mouseUp(with event: NSEvent) {
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        lastDrag = nil
        mouseDownPoint = nil
        let isShortClick = !didDrag && event.timestamp - mouseDownTime < 0.3
        if temporaryZoom {
            temporaryZoom = false
            // Короткий клік — зум лишається; утримання або перетягування — повертаємо «вписати»
            if !isShortClick { fit() }
        } else if !didDrag && !isFit {
            // Клік по фото, збільшеному клавішами чи колесом, — теж «вписати»
            fit()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let anchor = convert(event.locationInWindow, from: nil)

        // ⌘/⌥/⌃ + колесо — зум
        if !mods.isEmpty {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.15
            setZoom(zoom * exp(d), anchor: anchor)
            return
        }

        // Збільшене — прокрутка панорамує. Але з затиснутою кнопкою колесо гортає фото,
        // зберігаючи зум (порівняння кадрів, як у FastStone).
        if !isFit && mouseDownPoint == nil {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
            let ppp = pointsPerPixel
            center.x -= event.scrollingDeltaX * k / ppp
            center.y -= event.scrollingDeltaY * k / ppp
            layoutImage()
            return
        }

        // Вписане — колесо гортає зображення, як у FastStone
        if event.phase == .began { scrollAccum = 0 }
        guard event.momentumPhase.isEmpty else { return }
        let d = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if !event.hasPreciseScrollingDeltas {
            if d != 0 { onNavigate?(d < 0 ? 1 : -1) }
            return
        }
        scrollAccum += d
        if scrollAccum <= -40 {
            scrollAccum = 0
            onNavigate?(1)
        } else if scrollAccum >= 40 {
            scrollAccum = 0
            onNavigate?(-1)
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: - Перетягування файлів

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onDropURL?(url)
        return true
    }
}
