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
        if !isHidden && alphaValue > 0 { scrollToCurrent(animated: true) }
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
    private let thumb = NSImageView()

    var isCurrent = false {
        didSet { updateBorder() }
    }

    override func loadView() {
        let v = ClickView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.borderWidth = 2
        v.onClick = { [weak self] in self?.onClick?() }
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 3),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -3),
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
            thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
        ])
        view = v
    }

    func configure(url: URL, isCurrent: Bool) {
        self.url = url
        self.isCurrent = isCurrent
        loadOp?.cancel()
        thumb.image = nil
        view.toolTip = url.lastPathComponent
        loadOp = ThumbnailCache.shared.load(url) { [weak self] image in
            guard let self, self.url == url, let image else { return }
            self.thumb.image = NSImage(cgImage: image, size: .zero)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadOp?.cancel()
        loadOp = nil
        thumb.image = nil
    }

    private func updateBorder() {
        view.layer?.borderColor = isCurrent ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        view.layer?.backgroundColor = isCurrent ? NSColor.white.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
}

private final class ClickView: NSView {
    var onClick: (() -> Void)?
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
