import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Готове до показу зображення: зменшена до розміру екрана копія + метадані.
final class LoadedImage {
    let url: URL
    let preview: CGImage
    /// Розмір оригіналу в пікселях (з урахуванням орієнтації).
    let displaySize: CGSize
    let info: ImageInfo
    let histogram: Histogram?
    let decodeTime: Double

    init(url: URL, preview: CGImage, displaySize: CGSize, info: ImageInfo, histogram: Histogram?, decodeTime: Double) {
        self.url = url
        self.preview = preview
        self.displaySize = displaySize
        self.info = info
        self.histogram = histogram
        self.decodeTime = decodeTime
    }

    var cost: Int { preview.bytesPerRow * preview.height }
}

/// Швидке завантаження: декодування одразу під розмір екрана, кеш і попереднє завантаження сусідніх файлів.
final class ImageLoader {
    static let shared = ImageLoader()

    /// Розширення, які вміє читати ImageIO на цій системі (JPEG, PNG, HEIC, WebP, AVIF, RAW тощо).
    static let supportedExtensions: Set<String> = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        var exts = Set<String>()
        for id in ids {
            guard let type = UTType(id) else { continue }
            for ext in type.tags[.filenameExtension] ?? [] { exts.insert(ext.lowercased()) }
        }
        exts.remove("pdf")
        return exts
    }()

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func listImages(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return items
            .filter { isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Найбільша сторона прев'ю: розмір найбільшого екрана в фізичних пікселях.
    let previewMaxPixel: Int = {
        let side = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 3000
        return Int(side)
    }()

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FstnView.decode"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private let fullQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FstnView.full"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let cache: NSCache<NSURL, LoadedImage> = {
        let c = NSCache<NSURL, LoadedImage>()
        c.totalCostLimit = 700 * 1024 * 1024
        return c
    }()

    private let fullCache: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.totalCostLimit = 900 * 1024 * 1024
        return c
    }()

    private final class Pending {
        let op: Operation
        var callbacks: [(LoadedImage?) -> Void] = []
        init(op: Operation) { self.op = op }
    }

    private var pending: [URL: Pending] = [:]
    private struct FullPending {
        let url: URL
        let token: UUID
        let op: Operation
        var callbacks: [(CGImage?) -> Void]
    }

    private var fullPending: FullPending?

    // MARK: - Прев'ю (викликати з головного потоку)

    /// Прибрати файл з кешу (після видалення).
    func forget(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        fullCache.removeObject(forKey: url as NSURL)
        if let p = pending[url], !p.op.isExecuting {
            p.op.cancel()
            pending[url] = nil
        }
    }

    func cached(_ url: URL) -> LoadedImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL, priority: Operation.QueuePriority, completion: ((LoadedImage?) -> Void)?) {
        if let hit = cache.object(forKey: url as NSURL) {
            completion?(hit)
            return
        }
        if let p = pending[url] {
            if let completion { p.callbacks.append(completion) }
            if priority.rawValue > p.op.queuePriority.rawValue { p.op.queuePriority = priority }
            return
        }

        let maxPixel = previewMaxPixel
        let op = BlockOperation()
        let entry = Pending(op: op)
        if let completion { entry.callbacks.append(completion) }

        op.addExecutionBlock { [weak self] in
            let result = ImageLoader.decodePreview(url: url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.cache.setObject(result, forKey: url as NSURL, cost: result.cost) }
                if self.pending[url] === entry { self.pending[url] = nil }
                entry.callbacks.forEach { $0(result) }
            }
        }
        op.queuePriority = priority
        pending[url] = entry
        queue.addOperation(op)
    }

    /// Скасовує ще не розпочаті завантаження, які вже не потрібні (користувач швидко гортає).
    func cancelPending(keeping keep: Set<URL>) {
        for (url, entry) in pending where !keep.contains(url) && !entry.op.isExecuting {
            entry.op.cancel()
            pending[url] = nil
        }
    }

    // MARK: - Повна роздільність (для масштабу 100% і більше)

    /// Оригінал для зуму. completion = nil — просто завантажити наперед.
    /// Повторний запит того ж файлу, поки він ще вантажиться, не запускає декодування вдруге.
    func loadFull(_ url: URL, completion: ((CGImage?) -> Void)?) {
        if let hit = fullCache.object(forKey: url as NSURL) {
            completion?(hit)
            return
        }
        if let p = fullPending, p.url == url {
            if let completion { fullPending?.callbacks.append(completion) }
            return
        }
        fullPending?.op.cancel()

        let token = UUID()
        let op = BlockOperation()
        op.addExecutionBlock { [weak self] in
            let image = ImageLoader.decodeFull(url: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let image {
                    self.fullCache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                }
                guard let p = self.fullPending, p.token == token else { return }
                self.fullPending = nil
                p.callbacks.forEach { $0(image) }
            }
        }
        fullPending = FullPending(url: url, token: token, op: op, callbacks: completion.map { [$0] } ?? [])
        fullQueue.addOperation(op)
    }

    // MARK: - Декодування

    static func decodePreview(url: URL, maxPixel: Int) -> LoadedImage? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let info = ImageInfo.make(url: url, source: source, props: props)
        let fullSide = Int(max(info.pixelSize.width, info.pixelSize.height))
        let target = fullSide > 0 ? min(maxPixel, fullSide) : maxPixel

        var preview: CGImage?
        let isRaw = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
        if isRaw {
            // У RAW майже завжди є вбудоване JPEG-прев'ю: воно відкривається в рази швидше, ніж повне декодування.
            if let embedded = makeThumbnail(source, maxPixel: target, fromImageAlways: false),
               max(embedded.width, embedded.height) * 2 >= target {
                preview = embedded
            }
        }
        if preview == nil {
            preview = makeThumbnail(source, maxPixel: target, fromImageAlways: true)
        }
        guard let preview else { return nil }

        var size = info.pixelSize
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: preview.width, height: preview.height)
        } else {
            let previewAspect = CGFloat(preview.width) / CGFloat(preview.height)
            let fullAspect = size.width / size.height
            if abs(previewAspect - fullAspect) / fullAspect > 0.01 {
                size = CGSize(width: size.width, height: (size.width / previewAspect).rounded())
            }
        }

        let histogram = Histogram.compute(from: preview)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return LoadedImage(url: url, preview: preview, displaySize: size, info: info, histogram: histogram, decodeTime: elapsed)
    }

    static func decodeFull(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let side = max(w, h)
        guard side > 0 else { return nil }
        // RAW: якщо вбудоване JPEG повнорозмірне — беремо його (у рази швидше за декодування RAW)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true,
           let embedded = makeThumbnail(source, maxPixel: side, fromImageAlways: false),
           Double(max(embedded.width, embedded.height)) >= Double(side) * 0.9 {
            return embedded
        }
        return makeThumbnail(source, maxPixel: side, fromImageAlways: true)
    }

    private static func makeThumbnail(_ source: CGImageSource, maxPixel: Int, fromImageAlways: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if fromImageAlways {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
