import AppKit
import ImageIO

/// Мініатюри: беремо вбудоване в файл маленьке прев'ю (EXIF/RAW) — це миттєво.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.countLimit = 3000
        return c
    }()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FstnView.thumbnails"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

    func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }

    /// Повертає операцію, яку можна скасувати, якщо мініатюра вже не на екрані.
    @discardableResult
    func load(_ url: URL, completion: @escaping (CGImage?) -> Void) -> Operation? {
        if let hit = cached(url) {
            completion(hit)
            return nil
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard op?.isCancelled == false else { return }
            let image = Self.decode(url)
            DispatchQueue.main.async {
                if let image { self?.cache.setObject(image, forKey: url as NSURL) }
                if op?.isCancelled == false { completion(image) }
            }
        }
        queue.addOperation(op)
        return op
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Смуга мініатюр знизу (як у FastStone на весь екран).
final class ThumbnailStripView: NSVisualEffectView, NSCollectionViewDataSource {
    static let height: CGFloat = 104

    var onSelect: ((Int) -> Void)?
    /// Чи смуга зараз виїхала на екран (керує вікно).
    var isOnScreen = false

    private let scrollView = HorizontalScrollView()
    private let collectionView = PassiveCollectionView()
    private var files: [URL] = []
    private var currentIndex = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 112, height: 84)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setFiles(_ files: [URL], current: Int) {
        self.files = files
        currentIndex = current
        collectionView.reloadData()
        scrollToCurrent(animated: false)
    }

    func setCurrent(_ index: Int) {
        let old = currentIndex
        currentIndex = index
        for i in [old, index] where files.indices.contains(i) {
            (collectionView.item(at: IndexPath(item: i, section: 0)) as? ThumbnailItem)?.isCurrent = (i == index)
        }
        if isOnScreen { scrollToCurrent(animated: true) }
    }

    /// Прокрутити так, щоб поточна мініатюра була по центру.
    func scrollToCurrent(animated: Bool) {
        guard files.indices.contains(currentIndex) else { return }
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: currentIndex, section: 0))?.frame else { return }
        let clip = scrollView.contentView
        let maxX = max(0, collectionView.frame.width - clip.bounds.width)
        let x = min(max(0, frame.midX - clip.bounds.width / 2), maxX)
        let target = NSPoint(x: x, y: clip.bounds.origin.y)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Примусово перемалювати видимі мініатюри. Картинки, які прийшли, поки смуга була за краєм екрана,
    /// macOS могла не намалювати — після появи смуги малюємо їх ще раз.
    func redrawVisible() {
        for case let item as ThumbnailItem in collectionView.visibleItems() {
            item.redraw()
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        files.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
        let index = indexPath.item
        item.configure(url: files[index], isCurrent: index == currentIndex)
        item.onClick = { [weak self] in self?.onSelect?(index) }
        return item
    }
}

/// Одна мініатюра. Клік обробляється тут, а не виділенням колекції — так фокус клавіатури лишається на фото.
private final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    var onClick: (() -> Void)?
    private var url: URL?
    private var loadOp: Operation?

    var isCurrent = false {
        didSet { thumbView?.isCurrent = isCurrent }
    }

    private var thumbView: ThumbView? { view as? ThumbView }

    override func loadView() {
        let v = ThumbView()
        v.onClick = { [weak self] in self?.onClick?() }
        view = v
    }

    func configure(url: URL, isCurrent: Bool) {
        self.url = url
        self.isCurrent = isCurrent
        loadOp?.cancel()
        thumbView?.image = nil
        view.toolTip = url.lastPathComponent
        loadOp = ThumbnailCache.shared.load(url) { [weak self] image in
            guard let self, self.url == url, let image else { return }
            self.thumbView?.image = image
        }
    }

    func redraw() {
        thumbView?.refresh()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadOp?.cancel()
        loadOp = nil
        thumbView?.image = nil
    }
}

/// Мініатюра малюється напряму в шар Core Animation (як головне фото), а не через NSImageView:
/// так картинка з'являється одразу, навіть якщо прийшла, поки смуга була схована.
private final class ThumbView: NSView {
    var onClick: (() -> Void)?
    private let imageLayer = CALayer()

    var image: CGImage? {
        didSet { refresh() }
    }

    var isCurrent = false {
        didSet { updateBorder() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 4
        layer?.borderWidth = 2
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = bounds.insetBy(dx: 3, dy: 3)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func updateBorder() {
        layer?.borderColor = isCurrent ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        layer?.backgroundColor = isCurrent ? NSColor.white.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Колекція, яка не забирає фокус клавіатури у фото.
private final class PassiveCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// Звичайне колесо миші (вгору/вниз) прокручує смугу вліво/вправо.
private final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 30
        let clip = contentView
        let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        let x = min(max(0, clip.bounds.origin.x - event.scrollingDeltaY * k), maxX)
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        reflectScrolledClipView(clip)
    }
}
