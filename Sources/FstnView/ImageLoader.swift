import AppKit
import CoreImage
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
    /// RAW, у якого вбудований JPEG замалий (напр. Sony ARW — 1616 px), тому показано проявлений RAW.
    let isDevelopedRAW: Bool

    init(url: URL, preview: CGImage, displaySize: CGSize, info: ImageInfo, histogram: Histogram?, decodeTime: Double,
         isDevelopedRAW: Bool = false) {
        self.isDevelopedRAW = isDevelopedRAW
        self.url = url
        self.preview = preview
        self.displaySize = displaySize
        self.info = info
        self.histogram = histogram
        self.decodeTime = decodeTime
    }

    var cost: Int { preview.bytesPerRow * preview.height }

    /// Те саме зображення під іншим кадром (проявлений RAW пари показується як її JPEG).
    func shown(as url: URL) -> LoadedImage {
        LoadedImage(url: url, preview: preview, displaySize: displaySize, info: info,
                    histogram: histogram, decodeTime: decodeTime)
    }
}

/// Перший, швидкий етап показу: менша роздільність, поки декодується чітке прев'ю.
struct QuickPreview {
    let url: URL
    let image: CGImage
    let displaySize: CGSize
    let info: ImageInfo
    let decodeTime: Double
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
        c.totalCostLimit = 500 * 1024 * 1024
        return c
    }()

    private let fullCache: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.totalCostLimit = 600 * 1024 * 1024
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
        rawCache.removeObject(forKey: url as NSURL)
        rawFullCache.removeObject(forKey: url as NSURL)
        if let p = pending[url], !p.op.isExecuting {
            p.op.cancel()
            pending[url] = nil
        }
    }

    func cached(_ url: URL) -> LoadedImage? {
        cache.object(forKey: url as NSURL)
    }

    /// onQuick — якщо задано, спершу швидко (~30 мс) віддається прев'ю в меншій роздільності,
    /// а потім, як завжди, чітке через completion.
    func load(_ url: URL, priority: Operation.QueuePriority,
              onQuick: ((QuickPreview) -> Void)? = nil,
              completion: ((LoadedImage?) -> Void)?) {
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

        // Швидке прев'ю декодується паралельно з чітким, щоб не затримувати його
        if let onQuick {
            DispatchQueue.global(qos: .userInteractive).async {
                if let quick = ImageLoader.decodeQuick(url: url, maxPixel: maxPixel) {
                    DispatchQueue.main.async { onQuick(quick) }
                }
            }
        }
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

    // MARK: - Проявка RAW (клавіша A)

    static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
    }

    private let rawCache: NSCache<NSURL, LoadedImage> = {
        let c = NSCache<NSURL, LoadedImage>()
        c.totalCostLimit = 300 * 1024 * 1024
        return c
    }()

    private let rawFullCache: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.totalCostLimit = 400 * 1024 * 1024
        return c
    }()

    /// Проявка важка для пам'яті й процесора — по одному файлу за раз.
    private let rawQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FstnView.raw"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private var rawPending: [URL: Pending] = [:]

    func cachedDeveloped(_ url: URL) -> LoadedImage? {
        rawCache.object(forKey: url as NSURL)
    }

    /// Проявлений RAW у повній роздільності (для зуму), якщо він ще в кеші.
    func developedFull(_ url: URL) -> CGImage? {
        rawFullCache.object(forKey: url as NSURL)
    }

    func loadDeveloped(_ url: URL, priority: Operation.QueuePriority, completion: ((LoadedImage?) -> Void)?) {
        if let hit = rawCache.object(forKey: url as NSURL) {
            completion?(hit)
            return
        }
        if let p = rawPending[url] {
            if let completion { p.callbacks.append(completion) }
            if priority.rawValue > p.op.queuePriority.rawValue { p.op.queuePriority = priority }
            return
        }
        let maxPixel = previewMaxPixel
        let op = BlockOperation()
        let entry = Pending(op: op)
        if let completion { entry.callbacks.append(completion) }
        op.addExecutionBlock { [weak self] in
            let result = ImageLoader.developRAW(url: url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                guard let self else { return }
                if let (image, full) = result {
                    self.rawCache.setObject(image, forKey: url as NSURL, cost: image.cost)
                    self.rawFullCache.setObject(full, forKey: url as NSURL, cost: full.bytesPerRow * full.height)
                }
                if self.rawPending[url] === entry { self.rawPending[url] = nil }
                entry.callbacks.forEach { $0(result?.0) }
            }
        }
        op.queuePriority = priority
        rawPending[url] = entry
        rawQueue.addOperation(op)
    }

    func cancelDeveloped(keeping keep: Set<URL>) {
        for (url, entry) in rawPending where !keep.contains(url) && !entry.op.isExecuting {
            entry.op.cancel()
            rawPending[url] = nil
        }
    }

    private static let rawContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .cacheIntermediates: false,
    ])

    /// Справжня проявка RAW вбудованим у macOS рушієм (як у Переглядачі та Фото).
    /// Проявляємо один раз у повній роздільності: з неї ж робиться прев'ю під екран, а зум 100% — миттєвий.
    static func developRAW(url: URL, maxPixel: Int) -> (LoadedImage, CGImage)? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let full = rawContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let info = ImageInfo.make(url: url, source: source, props: props)
        let preview = scaled(full, maxSide: maxPixel) ?? full
        let histogram = Histogram.compute(from: preview)
        let image = LoadedImage(url: url, preview: preview, displaySize: CGSize(width: full.width, height: full.height),
                                info: info, histogram: histogram, decodeTime: CFAbsoluteTimeGetCurrent() - start)
        return (image, full)
    }

    private static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let k = Double(maxSide) / Double(side)
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
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
        let isRawFile = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
        // Для RAW розмір «рівно вдвічі» не прискорює (вбудоване прев'ю), тож лишаємо розмір екрана
        let target = isRawFile ? (fullSide > 0 ? min(maxPixel, fullSide) : maxPixel)
                               : previewTarget(fullSide: fullSide, maxPixel: maxPixel)

        var preview: CGImage?
        let isRaw = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
        if isRaw {
            // RAW за замовчуванням показуємо з вбудованого JPEG камери, навіть якщо він невеликий (Sony ARW — 1616 px).
            // Справжня проявка — лише за клавішею A.
            preview = makeThumbnail(source, maxPixel: target, fromImageAlways: false)
        }
        // Вбудованого JPEG немає або він замалий для екрана — проявляємо сам RAW
        let developedFromRaw = isRaw && preview == nil
        if preview == nil {
            preview = makeThumbnail(source, maxPixel: target, fromImageAlways: true)
        }
        guard let preview else { return nil }

        let size = displaySize(info: info, image: preview)
        let histogram = Histogram.compute(from: preview)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return LoadedImage(url: url, preview: preview, displaySize: size, info: info, histogram: histogram, decodeTime: elapsed,
                           isDevelopedRAW: developedFromRaw)
    }

    /// Розмір прев'ю. Якщо оригінал можна зменшити рівно вдвічі (вчетверо…) приблизно до розміру екрана —
    /// беремо саме такий розмір: JPEG тоді декодується значно швидше (масштабування прямо під час декодування).
    static func previewTarget(fullSide: Int, maxPixel: Int) -> Int {
        guard fullSide > 0 else { return maxPixel }
        guard fullSide > maxPixel else { return fullSide }
        var side = fullSide
        while (side + 1) / 2 >= Int(Double(maxPixel) * 0.97) { side = (side + 1) / 2 }
        if side < fullSide, Double(side) <= Double(maxPixel) * 1.25 { return side }
        return maxPixel
    }

    /// Розмір оригіналу для показу; якщо пропорції прев'ю трохи інші (вбудоване прев'ю RAW) — підганяємо.
    private static func displaySize(info: ImageInfo, image: CGImage) -> CGSize {
        let size = info.pixelSize
        guard size.width > 0, size.height > 0 else { return CGSize(width: image.width, height: image.height) }
        let previewAspect = CGFloat(image.width) / CGFloat(image.height)
        let fullAspect = size.width / size.height
        if abs(previewAspect - fullAspect) / fullAspect > 0.01 {
            return CGSize(width: size.width, height: (size.width / previewAspect).rounded())
        }
        return size
    }

    /// Швидке прев'ю: ¼ оригіналу (для великих фото це ~30 мс навіть для CR3).
    /// nil — якщо фото й так невелике і швидкий етап не потрібен.
    static func decodeQuick(url: URL, maxPixel: Int) -> QuickPreview? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let info = ImageInfo.make(url: url, source: source, props: props)
        let fullSide = Int(max(info.pixelSize.width, info.pixelSize.height))
        var quickSide = (fullSide + 3) / 4
        if quickSide < 800 { quickSide = (fullSide + 1) / 2 }
        // Якщо швидке прев'ю майже таке ж велике, як звичайне, — сенсу немає
        guard fullSide > 0, Double(quickSide) < Double(previewTarget(fullSide: fullSide, maxPixel: maxPixel)) * 0.6 else { return nil }

        let isRaw = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
        guard let image = makeThumbnail(source, maxPixel: quickSide, fromImageAlways: !isRaw) else { return nil }
        return QuickPreview(url: url, image: image, displaySize: displaySize(info: info, image: image), info: info,
                            decodeTime: CFAbsoluteTimeGetCurrent() - start)
    }

    /// Вбудований JPEG камери як є (навіть якщо він маленький) — для клавіші A на файлах на кшталт Sony ARW.
    static func decodeEmbedded(url: URL) -> LoadedImage? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let info = ImageInfo.make(url: url, source: source, props: props)
        let fullSide = Int(max(info.pixelSize.width, info.pixelSize.height))
        guard fullSide > 0, let embedded = makeThumbnail(source, maxPixel: fullSide, fromImageAlways: false) else { return nil }
        return LoadedImage(url: url, preview: embedded, displaySize: displaySize(info: info, image: embedded), info: info,
                           histogram: Histogram.compute(from: embedded), decodeTime: CFAbsoluteTimeGetCurrent() - start)
    }

    static func decodeFull(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let side = max(w, h)
        guard side > 0 else { return nil }
        // RAW: «оригінал» — це вбудований JPEG камери в найбільшому розмірі, який є у файлі
        // (у Canon повнорозмірний, у Sony ARW лише 1616 px). Сам RAW проявляється тільки за клавішею A.
        if ImageLoader.isRaw(url), let embedded = makeThumbnail(source, maxPixel: side, fromImageAlways: false) {
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
