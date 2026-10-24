import AppKit
import SwiftUI

final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let state = ViewerState()
    /// Область фото: одна половина або дві поруч (порівняння).
    private let stage = SplitStageView()
    /// Активна половина в режимі порівняння: 0 — ліва, 1 — права. Поза порівнянням — завжди ліва.
    private var activeSide = 0
    /// Половина, з якою працюють усі дії (гортання, оцінки, зум, A, Delete…).
    private var canvas: ImageCanvasView { activeSide == 0 ? stage.left : stage.right }
    private var passiveCanvas: ImageCanvasView { activeSide == 0 ? stage.right : stage.left }
    private var panel: NSView!
    private var panelTrailing: NSLayoutConstraint!
    private var canvasToEdge: NSLayoutConstraint!
    private var canvasToPanel: NSLayoutConstraint!
    /// Закріплена (клавіша I) — завжди видна і відсуває фото.
    private var isPinned = false
    /// Тимчасово показана, бо миша біля правого краю.
    private var autoShown = false

    /// Смуга мініатюр знизу: виїжджає, коли миша біля нижнього краю.
    private let strip = ThumbnailStripView()
    private var stripBottom: NSLayoutConstraint!
    private var stripShown = false

    /// Усі зображення папки. `files` — те, що гортаємо: без RAW, у яких є JPEG-пара.
    private var allFiles: [URL] = [] {
        didSet { regroup() }
    }
    private var files: [URL] = [] {
        didSet { strip.setFiles(files, current: index) }
    }
    /// JPEG → його RAW-пара (IMG_0001.JPG → IMG_0001.CR3). RAW схований зі списку, A проявляє саме його.
    private var pairedRaw: [URL: URL] = [:]
    private static let groupPairsKey = "groupRawJpegPairs"
    private var index = 0
    private var direction = 1
    private var current: LoadedImage?
    private var fullRequestedFor: URL?
    private var showingFull = false
    /// Фото, для якого зараз на екрані швидке прев'ю (чекаємо чітке).
    private var quickShownFor: URL?
    private var fullPrefetch: DispatchWorkItem?
    /// Фото, для якого зараз показано проявлений RAW (клавіша A), і яке зараз проявляється.
    private var rawShownFor: URL?
    private var rawDeveloping: URL?
    /// Фото, для якого на екрані вбудований JPEG камери замість типової проявки (A на Sony ARW тощо).
    private var embeddedShownFor: URL?
    /// Видалені в Кошик фото (для ⌘Z). Одна група — одне видалення (напр. пара RAW+JPEG).
    private var deleted: [[(original: URL, trashed: URL)]] = []
    /// Поворот кожного фото на екрані (L / R), поки програма відкрита.
    private var rotations: [URL: Int] = [:]
    private var listingToken = UUID()
    /// Оцінки й мітки кадрів (прочитані з XMP), щоб не читати файл щоразу.
    private var marks: [URL: PhotoMark] = [:]
    private let markQueue = DispatchQueue(label: "fstn.marks", qos: .userInitiated)
    /// Зум, з яким показати наступне фото (гортання в збільшеному вигляді).
    private var pendingView: ImageCanvasView.ViewState?
    private let loader = ImageLoader.shared

    private static let panelDefaultsKey = "infoPanelPinned"
    private static let panelSize: CGFloat = 290

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = AppInfo.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 520, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        UserDefaults.standard.register(defaults: [Self.panelDefaultsKey: false, Self.groupPairsKey: true])
        isPinned = UserDefaults.standard.bool(forKey: Self.panelDefaultsKey)

        // Панель: напівпрозорий фон + SwiftUI-вміст
        let host = NSHostingView(rootView: InfoPanelView(state: state))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel = blur

        // Фото на всю ширину, панель — шаром поверх нього біля правого краю
        let container = HoverTrackingView()
        container.clipsToBounds = true
        for v in [stage, strip, blur] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        panelTrailing = blur.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        canvasToEdge = stage.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        canvasToPanel = stage.trailingAnchor.constraint(equalTo: blur.leadingAnchor)
        stripBottom = strip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: ThumbnailStripView.height)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stage.topAnchor.constraint(equalTo: container.topAnchor),
            stage.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.widthAnchor.constraint(equalToConstant: Self.panelSize),
            panelTrailing,
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: ThumbnailStripView.height),
            stripBottom,
        ])
        strip.onSelect = { [weak self] i in self?.goTo(index: i) }
        strip.onCompare = { [weak self] i in self?.compare(with: i) }
        window.contentView = container
        container.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }
        container.onMouseExited = { [weak self] in
            self?.setAutoShown(false)
            self?.setStripShown(false)
        }
        applyPanelState(animated: false)

        window.setFrameAutosaveName("FstnViewMain")
        if !window.setFrameUsingName("FstnViewMain") { window.center() }

        for c in [stage.left, stage.right] {
            c.onNavigate = { [weak self] step in self?.navigate(step) }
            c.onZoomChanged = { [weak self, unowned c] in
                guard let self, c === self.canvas else { return }
                self.zoomChanged()
            }
            c.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
            c.onDropURL = { [weak self] url in self?.open(url) }
            c.onContextMenu = { [weak self, unowned c] in
                guard let self else { return nil }
                _ = self.activate(c)
                return self.contextMenu()
            }
            c.onActivate = { [weak self, unowned c] in self?.activate(c) ?? false }
            c.onViewChanged = { [weak self, unowned c] in
                guard let self, c === self.canvas else { return }
                self.syncPassive()
            }
        }
        showHint { L("Відкрийте зображення (⌘O) або перетягніть його сюди") }
        window.makeFirstResponder(canvas)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: AppLanguage.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Відкриття

    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        let isFolder = isDir.boolValue
        let folder = isFolder ? url : url.deletingLastPathComponent()
        let token = UUID()
        listingToken = token

        // Файл показуємо одразу, не чекаючи, поки прочитається вміст папки.
        if !isFolder {
            allFiles = [url]
            index = 0
            showCurrent()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = ImageLoader.listImages(in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listingToken == token else { return }
                if isFolder {
                    self.allFiles = list
                    self.index = 0
                    if list.isEmpty {
                        self.clearInfo()
                        self.showHint { L("У папці «%@» немає зображень", folder.lastPathComponent) }
                        self.window?.title = folder.lastPathComponent
                    } else {
                        self.showCurrent()
                    }
                } else {
                    let path = url.standardizedFileURL.path
                    let same: (URL) -> Bool = { $0.standardizedFileURL.path == path }
                    if list.contains(where: same) {
                        self.allFiles = list
                        if let i = self.files.firstIndex(where: same) {
                            self.index = i
                        } else if let jpg = self.pairedRaw.first(where: { same($0.value) })?.key,
                                  let i = self.files.firstIndex(of: jpg) {
                            // Відкрили RAW, у якого є JPEG-пара: показуємо пару як один кадр
                            self.index = i
                            self.showCurrent()
                            return
                        }
                    }
                    self.updatePosition()
                    self.preloadNeighbors()
                }
            }
        }
    }

    // MARK: - Порівняння двох фото поруч (⌘+клік по мініатюрі)

    private(set) var comparing = false
    /// Фото в неактивній половині.
    private var otherURL: URL?
    /// Те, що показано в неактивній половині (прев'ю), і чи там зараз оригінал.
    private var otherImage: LoadedImage?
    private var otherShowsFull = false

    /// ⌘+клік: показати фото праворуч від поточного. Повторно по іншому — замінити праве,
    /// по тому, що вже в порівнянні, — закрити порівняння.
    func compare(with target: Int) {
        guard files.indices.contains(target) else { return }
        let url = files[target]
        if comparing {
            if url == otherURL || url == files[index] {
                exitCompare()
                return
            }
            if activeSide == 0 { switchSide() }       // замінюємо саме праве фото
            index = target
            showCurrent(keepingView: canvas.viewState)
            window?.makeFirstResponder(canvas)
            return
        }
        guard target != index else { return }
        let view = canvas.viewState
        comparing = true
        otherURL = files[index]
        otherImage = current ?? otherURL.flatMap { loader.cached($0) }
        otherShowsFull = showingFull && current != nil
        updateCompareLayout()
        stage.isSplit = true
        activeSide = 1                                // нове фото праворуч і активне
        stage.left.isHighlighted = false
        stage.right.isHighlighted = true
        index = target
        showCurrent(keepingView: view)
        window?.makeFirstResponder(canvas)
    }

    /// Клік або колесо над половиною. true — вона щойно стала активною.
    private func activate(_ c: ImageCanvasView) -> Bool {
        guard comparing, c !== canvas else { return false }
        switchSide()
        return true
    }

    /// Зробити активною іншу половину: її фото стає «поточним» для всіх дій.
    private func switchSide() {
        guard comparing, let other = otherURL, let i = files.firstIndex(of: other) else {
            exitCompare()
            return
        }
        otherURL = files.indices.contains(index) ? files[index] : nil
        otherImage = current ?? otherURL.flatMap { loader.cached($0) }
        otherShowsFull = showingFull && current != nil
        activeSide = 1 - activeSide
        stage.left.isHighlighted = activeSide == 0
        stage.right.isHighlighted = activeSide == 1
        index = i
        showCurrent(keepingView: canvas.viewState)
        window?.makeFirstResponder(canvas)
    }

    /// Esc або ⌘+клік по фото з порівняння: назад до одного фото (активного).
    func exitCompare() {
        guard comparing else { return }
        let view = canvas.viewState
        comparing = false
        otherURL = nil
        otherImage = nil
        stage.left.isHighlighted = false
        stage.right.isHighlighted = false
        let wasRight = activeSide == 1
        activeSide = 0
        stage.isSplit = false
        stage.isStacked = false
        strip.setCompare(nil)
        if wasRight {
            showCurrent(keepingView: view)
        } else {
            updatePosition()
        }
        stage.right.showHint("")
        window?.makeFirstResponder(canvas)
    }

    /// Неактивна половина повторює зум і позицію активної; якщо збільшено — показує оригінал.
    private func syncPassive() {
        guard comparing, let other = otherImage, otherImage?.url == otherURL else { return }
        let passive = passiveCanvas
        passive.apply(canvas.viewState)
        let needed = passive.zoom * max(other.displaySize.width, other.displaySize.height)
        let have = CGFloat(max(other.preview.width, other.preview.height))
        if needed > have * 1.02 {
            guard !otherShowsFull else { return }
            otherShowsFull = true
            let url = other.url
            loader.loadFull(url, slot: 1) { [weak self] image in
                guard let self, let image, self.otherURL == url, self.otherShowsFull else { return }
                self.passiveCanvas.replaceImage(image)
            }
        } else if otherShowsFull {
            otherShowsFull = false
            passive.replaceImage(other.preview)
        }
        updatePassiveOverlay()
    }

    /// Розкладка порівняння: авто (де фото більші), поруч або одне над одним.
    enum CompareLayout: Int { case auto = 0, sideBySide, stacked }
    private static let compareLayoutKey = "compareLayout"

    var compareLayout: CompareLayout {
        get { CompareLayout(rawValue: UserDefaults.standard.integer(forKey: Self.compareLayoutKey)) ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.compareLayoutKey)
            updateCompareLayout()
            if comparing { flash(compareLayoutTitle) }
        }
    }

    var compareLayoutTitle: String {
        switch compareLayout {
        case .auto: return L("Порівняння: авто (%@)", stage.isStacked ? L("одне над одним") : L("поруч"))
        case .sideBySide: return L("Порівняння: поруч")
        case .stacked: return L("Порівняння: одне над одним")
        }
    }

    /// \\ — авто → поруч → одне над одним → авто.
    func cycleCompareLayout() {
        compareLayout = CompareLayout(rawValue: (compareLayout.rawValue + 1) % 3) ?? .auto
    }

    /// Ставить розкладку половин. В «авто» — ту, де обидва фото разом займають більше місця:
    /// вертикальні — поруч, горизонтальні — одне над одним.
    private func updateCompareLayout() {
        guard comparing else { return }
        let stacked: Bool
        switch compareLayout {
        case .sideBySide: stacked = false
        case .stacked: stacked = true
        case .auto:
            func size(_ image: LoadedImage?) -> CGSize? {
                guard let image else { return nil }
                let s = image.displaySize
                return (rotations[image.url] ?? 0) % 2 == 1 ? CGSize(width: s.height, height: s.width) : s
            }
            let sizes = [size(current), size(otherImage)].compactMap { $0 }.filter { $0.width > 0 && $0.height > 0 }
            guard !sizes.isEmpty else { return }
            func area(_ stacked: Bool) -> CGFloat {
                let cell = stage.cellSize(stacked: stacked)
                return sizes.reduce(0) { sum, s in
                    let k = min(cell.width / s.width, cell.height / s.height)
                    return sum + s.width * s.height * k * k
                }
            }
            stacked = area(true) > area(false) * 1.05
        }
        stage.isStacked = stacked
    }

    /// Короткий рядок неактивної половини: ім'я, зірки, мітка, масштаб.
    private func updatePassiveOverlay() {
        guard comparing, let url = otherURL else { return }
        var parts = [url.lastPathComponent]
        let mark = marks[url]
        if let mark, mark.rating > 0 { parts.append(mark.stars) }
        if passiveCanvas.hasImage { parts.append("\(Int((passiveCanvas.zoom * 100).rounded()))%") }
        passiveCanvas.setOverlayText(parts.joined(separator: "  "), dot: mark?.label?.color)
        if mark == nil { loadMark(for: url) }
    }

    // MARK: - Пари RAW+JPEG

    var groupsPairs: Bool { UserDefaults.standard.bool(forKey: Self.groupPairsKey) }

    /// Будує `files` з `allFiles`: RAW з JPEG-парою ховається, JPEG стає одним кадром.
    private func regroup() {
        guard groupsPairs else {
            pairedRaw = [:]
            files = allFiles
            return
        }
        var groups: [String: [URL]] = [:]
        for u in allFiles {
            let key = u.deletingLastPathComponent().standardizedFileURL.path + "/"
                + u.deletingPathExtension().lastPathComponent.lowercased()
            groups[key, default: []].append(u)
        }
        var pairs: [URL: URL] = [:]
        var hidden = Set<URL>()
        for group in groups.values where group.count > 1 {
            guard let raw = group.first(where: ImageLoader.isRaw),
                  let jpg = group.first(where: { !ImageLoader.isRaw($0) }) else { continue }
            pairs[jpg] = raw
            hidden.insert(raw)
        }
        pairedRaw = pairs
        files = hidden.isEmpty ? allFiles : allFiles.filter { !hidden.contains($0) }
    }

    /// Меню «Вигляд»: обʼєднувати пари RAW+JPEG чи показувати всі файли окремо.
    func toggleGroupPairs() {
        let here = files.indices.contains(index) ? files[index] : nil
        UserDefaults.standard.set(!groupsPairs, forKey: Self.groupPairsKey)
        regroup()
        guard let here else { return }
        if let i = files.firstIndex(of: here) {
            index = i
            updatePosition()
        } else {
            let jpg = pairedRaw.first(where: { $0.value == here })?.key
            index = jpg.flatMap { files.firstIndex(of: $0) } ?? 0
            showCurrent()
        }
    }

    /// Файл, який зараз на екрані: RAW-пара після A, інакше сам кадр. Для E, ⌘C, ⌘R.
    private var displayedFile: URL? {
        guard files.indices.contains(index) else { return nil }
        let url = files[index]
        if rawShownFor == url, let raw = pairedRaw[url] { return raw }
        return url
    }

    /// Інфо-панель: у пари показуємо другий файл (RAW біля JPEG, або JPEG біля проявленого RAW).
    private func infoWithPair(_ info: ImageInfo, for url: URL) -> ImageInfo {
        guard let raw = pairedRaw[url] else { return info }
        var info = info
        info.pair = info.url == raw ? url : raw
        return info
    }

    // MARK: - Перегляд

    /// `keepingView` — показати фото в тому ж масштабі й точці, що й попереднє.
    private func showCurrent(keepingView: ImageCanvasView.ViewState? = nil) {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        pendingView = keepingView
        updatePosition()
        window?.title = url.lastPathComponent
        window?.representedURL = url
        fullRequestedFor = nil
        // RAW проявляється лише для того фото, де натиснули A
        rawShownFor = nil
        rawDeveloping = nil
        embeddedShownFor = nil
        loader.cancelDeveloped(keeping: [])

        if let hit = loader.cached(url) {
            display(hit, fromCache: true)
            // Порівняння у збільшеному вигляді: якщо RAW цього фото вже проявляли (A), показуємо його
            if keepingView != nil, ImageLoader.isRaw(url) || pairedRaw[url] != nil,
               let dev = loader.cachedDeveloped(pairedRaw[url] ?? url) {
                display(pairedRaw[url] == nil ? dev : dev.shown(as: url), fromCache: true, developed: true)
            }
        } else {
            loader.load(url, priority: .veryHigh, onQuick: { [weak self] quick in
                guard let self, self.files.indices.contains(self.index), self.files[self.index] == url,
                      self.current?.url != url else { return }
                self.showQuick(quick)
            }) { [weak self] image in
                guard let self, self.files.indices.contains(self.index), self.files[self.index] == url else { return }
                if let image {
                    self.display(image, fromCache: false)
                } else {
                    self.current = nil
                    self.clearInfo()
                    self.state.fileName = url.lastPathComponent
                    self.showHint { L("Не вдалося відкрити «%@»", url.lastPathComponent) }
                    self.updateOverlay()
                }
            }
        }
        preloadNeighbors()
    }

    /// Перший етап: показати швидке прев'ю, поки декодується чітке.
    private func showQuick(_ quick: QuickPreview) {
        current = nil                     // щоб зум не взяв оригінал попереднього фото
        quickShownFor = quick.url
        hintMaker = nil
        canvas.setRotation(rotations[quick.url] ?? 0)
        canvas.setImage(quick.image, size: quick.displaySize, resetView: true, keeping: pendingView)
        state.fileName = quick.url.lastPathComponent
        state.info = infoWithPair(quick.info, for: quick.url)
        state.histogram = nil
        updateOverlay()
    }

    private func display(_ image: LoadedImage, fromCache: Bool, developed: Bool = false, embedded: Bool = false) {
        // Проявлений RAW або обраний JPEG уже на екрані — запізніле звичайне прев'ю їх не перекриває
        if !developed && !embedded && (rawShownFor == image.url || embeddedShownFor == image.url) { return }
        // Те саме фото (швидке прев'ю → чітке, або JPEG ↔ проявлений RAW) — не скидаємо зум
        let keepView = quickShownFor == image.url || current?.url == image.url
        current = image
        showingFull = false
        fullRequestedFor = nil
        quickShownFor = nil
        rawShownFor = developed ? image.url : nil
        embeddedShownFor = embedded ? image.url : nil
        if !keepView { canvas.setRotation(rotations[image.url] ?? 0) }
        canvas.setImage(image.preview, size: image.displaySize, resetView: !keepView, keeping: keepView ? nil : pendingView)
        // Оригінал для зуму вантажимо, лише якщо користувач затримався на фото (не під час швидкого гортання).
        // Для проявленого RAW оригінал уже є.
        fullPrefetch?.cancel()
        let url = image.url
        if !developed && !embedded {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.current?.url == url else { return }
                self.loader.loadFull(url, completion: nil)
            }
            fullPrefetch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        state.fileName = image.info.url.lastPathComponent
        state.info = infoWithPair(image.info, for: image.url)
        updateCompareLayout()
        state.histogram = image.histogram
        let ms = Int((image.decodeTime * 1000).rounded())
        hintMaker = nil
        let (pw, ph) = (image.preview.width, image.preview.height)
        let (fw, fh) = (Int(image.displaySize.width), Int(image.displaySize.height))
        let (ew, eh) = (image.preview.width, image.preview.height)
        let developedByDefault = image.isDevelopedRAW
        setDecodeText { embedded
            ? L("Вбудований JPEG камери %d×%d", ew, eh)
            : developed || developedByDefault
            ? L("RAW проявлено за %d мс · %d×%d", ms, fw, fh)
            : fromCache
            ? L("З кешу (декодовано за %d мс)", ms)
            : L("Декодовано за %d мс · прев'ю %d×%d", ms, pw, ph) }
        updateOverlay()
    }

    private func clearInfo() {
        state.info = nil
        state.histogram = nil
        setDecodeText(nil)
    }

    // MARK: - Тексти, що залежать від мови

    private var hintMaker: (() -> String)?
    private var decodeTextMaker: (() -> String)?

    private func showHint(_ make: @escaping () -> String) {
        hintMaker = make
        canvas.showHint(make())
    }

    private func setDecodeText(_ make: (() -> String)?) {
        decodeTextMaker = make
        state.decodeText = make?() ?? ""
    }

    /// Мову змінили в меню — перемальовуємо все, що вже показано.
    @objc private func languageChanged() {
        if let hintMaker, !canvas.hasImage { canvas.showHint(hintMaker()) }
        state.decodeText = decodeTextMaker?() ?? ""
        state.info = state.info          // панель перебудує розділи новою мовою
        zoomChanged()
    }

    private func updatePosition() {
        state.position = files.isEmpty ? "" : "\(index + 1) / \(files.count)"
        strip.setCurrent(index)
        strip.setCompare(comparing ? otherURL.flatMap { files.firstIndex(of: $0) } : nil)
        updateOverlay()
    }

    /// «IMG.CR3  ( 6720 x 4480 = 30.1 MP , 8,9 MB )  [ 19 / 20 ]  27%»
    private func updateOverlay() {
        guard files.indices.contains(index) else {
            canvas.setOverlayText("")
            return
        }
        let here = files[index]
        let pair = pairedRaw[here]
        var parts = [(rawShownFor == here ? pair : nil)?.lastPathComponent ?? here.lastPathComponent]
        if let info = state.info, info.url == here || info.url == pair {
            let w = Int(info.pixelSize.width), h = Int(info.pixelSize.height)
            var details = "\(w) x \(h) = \(String(format: "%.2f", Double(w * h) / 1_000_000)) MP"
            if let bytes = info.fileSize {
                details += " , " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            parts.append("( \(details) )")
        }
        parts.append("[ \(index + 1) / \(files.count) ]")
        let mark = marks[here]
        if let mark, mark.rating > 0 { parts.append(mark.stars) }
        if let flashText { parts.append("· \(flashText)") }
        if embeddedShownFor == here {
            parts.append("[ JPEG ]")
        } else if rawShownFor == here || (current?.url == here && current?.isDevelopedRAW == true) {
            parts.append("[ RAW ]")
        } else if rawDeveloping == here {
            parts.append("[ RAW… ]")
        } else if pair != nil {
            parts.append("[ JPEG+RAW ]")
        }
        if canvas.hasImage {
            parts.append("\(Int((canvas.zoom * 100).rounded()))%")
        }
        canvas.setOverlayText(parts.joined(separator: "  "), dot: mark?.label?.color)
        if mark == nil { loadMark(for: here) }
        updatePassiveOverlay()
    }

    private func preloadNeighbors() {
        guard !files.isEmpty else { return }
        let offsets = [direction, 2 * direction, -direction]
        let urls = offsets.map { index + $0 }.filter { files.indices.contains($0) }.map { files[$0] }
        var keep = Set(urls)
        if files.indices.contains(index) { keep.insert(files[index]) }
        loader.cancelPending(keeping: keep)
        for (i, url) in urls.enumerated() {
            loader.load(url, priority: i == 0 ? .high : .normal, completion: nil)
        }
    }

    func navigate(_ step: Int) {
        guard !files.isEmpty else { return }
        let target = min(max(index + step, 0), files.count - 1)
        guard target != index else { NSSound.beep(); return }
        direction = step >= 0 ? 1 : -1
        index = target
        // Збільшене фото — наступне показуємо в тому ж масштабі й точці (порівняння кадрів)
        showCurrent(keepingView: canvas.viewState)
    }

    func goTo(first: Bool) {
        guard !files.isEmpty else { return }
        let target = first ? 0 : files.count - 1
        guard target != index else { return }
        direction = first ? 1 : -1
        index = target
        showCurrent()
    }

    private func zoomChanged() {
        guard canvas.hasImage, let cur = current else {
            state.zoomText = ""
            return
        }
        let pct = Int((canvas.zoom * 100).rounded())
        state.zoomText = canvas.isFit ? L("Вписано · %d%%", pct) : "\(pct)%"
        updateOverlay()

        // Коли прев'ю вже не вистачає для поточного масштабу — показуємо оригінал.
        let needed = canvas.zoom * max(cur.displaySize.width, cur.displaySize.height)
        let have = CGFloat(max(cur.preview.width, cur.preview.height))
        if needed > have * 1.02 {
            guard !showingFull, embeddedShownFor != cur.url else { return }
            if rawShownFor == cur.url, let full = loader.developedFull(pairedRaw[cur.url] ?? cur.url) {
                canvas.replaceImage(full)
                showingFull = true
                return
            }
            guard fullRequestedFor != cur.url else { return }
            fullRequestedFor = cur.url
            let url = cur.url
            loader.loadFull(url) { [weak self] image in
                guard let self, self.current?.url == url, self.fullRequestedFor == url, self.rawShownFor != url else { return }
                self.fullRequestedFor = nil
                guard let image else {
                    self.setDecodeText { L("Не вдалося завантажити оригінал") }
                    return
                }
                self.canvas.replaceImage(image)
                self.showingFull = true
                let (fw, fh) = (image.width, image.height)
                self.setDecodeText { L("Оригінал %d×%d", fw, fh) }
                self.prefetchNextFull()
            }
        } else {
            // Повернулися до малого масштабу — назад на прев'ю (воно чіткіше при зменшенні)
            fullRequestedFor = nil
            if showingFull {
                canvas.replaceImage(cur.preview)
                showingFull = false
            }
        }
    }

    /// Поки фото збільшене, наперед вантажимо оригінал наступного — гортання в зумі без розмитого прев'ю.
    private func prefetchNextFull() {
        guard !canvas.isFit else { return }
        let next = index + direction
        guard files.indices.contains(next) else { return }
        loader.loadFull(files[next], completion: nil)
    }

    // MARK: - Оцінки і мітки (1–5, 6–9)

    /// Файли кадру, яким ставиться оцінка: фото і його RAW/JPEG-пара.
    private func markTargets(_ url: URL) -> [URL] { [url] + companions(of: url) }

    private func loadMark(for url: URL) {
        let source = pairedRaw[url] ?? companions(of: url).first(where: ImageLoader.isRaw) ?? url
        markQueue.async { [weak self] in
            let mark = Ratings.read(source)
            DispatchQueue.main.async {
                guard let self, self.marks[url] == nil else { return }
                self.marks[url] = mark
                if self.files.indices.contains(self.index), self.files[self.index] == url || self.otherURL == url { self.updateOverlay() }
            }
        }
    }

    /// 1–5: поставити зірки. Повторне натискання тієї ж цифри — прибрати оцінку.
    func setRating(_ rating: Int) {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        var mark = marks[url] ?? Ratings.read(pairedRaw[url] ?? url)
        mark.rating = mark.rating == rating ? 0 : rating
        applyMark(mark, to: url)
    }

    /// 6–9: кольорова мітка. Повторне натискання — прибрати.
    func setLabel(_ label: ColorLabel?) {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        var mark = marks[url] ?? Ratings.read(pairedRaw[url] ?? url)
        mark.label = mark.label == label ? nil : label
        applyMark(mark, to: url)
    }

    private func applyMark(_ mark: PhotoMark, to url: URL) {
        let old = marks[url]
        let targets = markTargets(url)
        for u in targets { marks[u] = mark }
        updateOverlay()
        markQueue.async { [weak self] in
            do {
                try Ratings.write(mark, to: targets)
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    for u in targets { self.marks[u] = old }
                    self.updateOverlay()
                    self.showError(L("Не вдалося зберегти оцінку"), error)
                }
            }
        }
    }

    // MARK: - Проявка RAW (клавіша A)

    /// A: проявити поточне RAW-фото (лише його) або RAW-пару поточного JPEG. Повторне A — назад.
    func toggleRawDevelop() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        let pair = pairedRaw[url]
        guard ImageLoader.isRaw(url) || pair != nil else { NSSound.beep(); return }

        // Файли, де вбудований JPEG замалий (Sony ARW): за замовчуванням проявлений RAW,
        // A перемикає на JPEG камери і назад.
        if pair == nil, embeddedShownFor == url || (current?.url == url && current?.isDevelopedRAW == true) {
            if embeddedShownFor == url {
                embeddedShownFor = nil
                if let developed = loader.cached(url) { display(developed, fromCache: true) } else { showCurrent() }
                updateOverlay()
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let image = ImageLoader.decodeEmbedded(url: url)
                    DispatchQueue.main.async {
                        guard let self, self.files.indices.contains(self.index), self.files[self.index] == url else { return }
                        if let image { self.display(image, fromCache: false, embedded: true) } else { NSSound.beep() }
                    }
                }
            }
            return
        }

        if rawShownFor == url {
            rawShownFor = nil
            if let embedded = loader.cached(url) { display(embedded, fromCache: true) } else { showCurrent() }
            updateOverlay()
            return
        }
        guard rawDeveloping != url else { return }
        rawDeveloping = url
        updateOverlay()
        setDecodeText { L("Проявка RAW…") }
        loader.loadDeveloped(pair ?? url, priority: .veryHigh) { [weak self] image in
            guard let self, self.files.indices.contains(self.index), self.files[self.index] == url,
                  self.rawDeveloping == url else { return }
            self.rawDeveloping = nil
            if let image {
                // Проявлений RAW пари показуємо як той самий кадр (JPEG), щоб зум і поворот лишились
                self.display(pair == nil ? image : image.shown(as: url), fromCache: false, developed: true)
            } else {
                self.setDecodeText { L("Не вдалося проявити RAW") }
                self.updateOverlay()
            }
        }
    }

    // MARK: - Видалення

    private static let skipDeleteConfirmKey = "skipDeleteConfirmation"
    private var isConfirmingDelete = false

    /// Delete / Backspace. Поки користувач не поставив «Більше не показувати», спершу питаємо.
    func deleteCurrent() {
        guard files.indices.contains(index), !isConfirmingDelete else { return }
        let url = files[index]
        if UserDefaults.standard.bool(forKey: Self.skipDeleteConfirmKey) {
            moveToTrash(url)
            return
        }

        let names = ([url] + companions(of: url)).map { $0.lastPathComponent }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = L("Перемістити фото в Кошик?")
        alert.informativeText = L("«%@» буде переміщено в Кошик, а не видалено назавжди. Повернути фото можна з Кошика або клавішами ⌘Z, поки програма відкрита.", names)
        alert.addButton(withTitle: L("Перемістити в Кошик"))
        alert.addButton(withTitle: L("Скасувати")).keyEquivalent = "\u{1b}"   // Esc — скасувати
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Більше не показувати")

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isConfirmingDelete = false
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.skipDeleteConfirmKey)
            }
            if response == .alertFirstButtonReturn { self.moveToTrash(url) }
            self.window?.makeFirstResponder(self.canvas)
        }
        isConfirmingDelete = true
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Пара до фото: файл з тим самим іменем, але іншим розширенням, якщо один із них RAW
    /// (IMG_3447.CR3 + IMG_3447.JPG). Видаляються і відновлюються разом.
    private func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        return allFiles.filter { other in
            other != url
                && other.deletingPathExtension().lastPathComponent.lowercased() == base
                && other.deletingLastPathComponent().standardizedFileURL.path == folder
                && (ImageLoader.isRaw(other) != ImageLoader.isRaw(url))
        }
    }

    /// Переміщує фото (разом із парою RAW+JPEG) в Кошик і показує наступне.
    /// Усі файли кадру: фото, його RAW/JPEG-пара і файл-супутник з оцінкою (IMG_0001.xmp).
    private func frameGroup(_ url: URL) -> [URL] {
        let photos = [url] + companions(of: url)
        let sidecars = Set(photos.map(Ratings.sidecar(for:))).filter { FileManager.default.fileExists(atPath: $0.path) }
        return photos + sidecars.sorted { $0.path < $1.path }
    }

    private func moveToTrash(_ url: URL) {
        let group = frameGroup(url)
        NSWorkspace.shared.recycle(group) { [weak self] trashed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let moved = group.compactMap { original in trashed[original].map { (original: original, trashed: $0) } }
                if !moved.isEmpty { self.deleted.append(moved) }
                if let error, moved.isEmpty {
                    self.showError(L("Не вдалося перемістити «%@» у Кошик", url.lastPathComponent), error)
                    return
                }
                self.removeFromList(Set(moved.map { $0.original }))
            }
        }
    }

    /// Прибирає зі списку файли, яких у папці більше немає (видалені або переміщені), і показує наступне фото.
    private func removeFromList(_ removed: Set<URL>) {
        for u in removed {
            loader.forget(u)
            ThumbnailCache.shared.forget(u)
            marks[u] = nil
        }
        let currentURL = files.indices.contains(index) ? files[index] : nil
        let before = files.prefix(index).filter { removed.contains($0) }.count
        if comparing, let other = otherURL, removed.contains(other) { exitCompare() }
        allFiles.removeAll { removed.contains($0) }
        if files.isEmpty {
            current = nil
            index = 0
            clearInfo()
            state.fileName = ""
            updatePosition()
            showHint { L("У папці більше немає зображень") }
            return
        }
        if let currentURL, !removed.contains(currentURL) {
            // Поточне фото лишилось — лише зсуваємо номер
            index = files.firstIndex(of: currentURL) ?? 0
            updatePosition()
        } else {
            // Прибрали поточне — показуємо наступне (або попереднє, якщо це було останнє)
            index = min(max(index - before, 0), files.count - 1)
            showCurrent()
        }
    }

    var canUndoDelete: Bool { !deleted.isEmpty }

    /// ⌘Z: повертає останнє видалене (разом із парою) з Кошика на старе місце.
    func undoDelete() {
        guard let group = deleted.popLast() else { NSSound.beep(); return }
        var restored: [URL] = []
        for item in group {
            do {
                try FileManager.default.moveItem(at: item.trashed, to: item.original)
                restored.append(item.original)
            } catch {
                showError(L("Не вдалося відновити «%@»", item.original.lastPathComponent), error)
            }
        }
        guard let first = restored.first else { return }
        // Повертаємо у список, якщо переглядаємо ту саму папку
        let folder = first.deletingLastPathComponent().standardizedFileURL.path
        let currentFolder = files.first?.deletingLastPathComponent().standardizedFileURL.path
        if currentFolder == nil || currentFolder == folder {
            var list = allFiles
            for u in restored where u.pathExtension.lowercased() != "xmp" {
                let name = u.lastPathComponent
                let pos = list.firstIndex { $0.lastPathComponent.localizedStandardCompare(name) == .orderedDescending } ?? list.count
                list.insert(u, at: pos)
            }
            allFiles = list
            let shown = restored.first { files.contains($0) } ?? first
            index = files.firstIndex(of: shown) ?? 0
            showCurrent()
        } else {
            open(first)
        }
    }

    // MARK: - Відсортовано (M / C, «Перемістити позначені…»)

    /// Куди переносити: обрана папка або «Відсортовано» в поточній.
    var sortFolderName: String {
        guard let url = files.first else { return Sorter.customFolder?.lastPathComponent ?? L("Відсортовано") }
        return Sorter.destination(for: url).lastPathComponent
    }

    /// M — перемістити поточне фото (з парою і .xmp), C — скопіювати.
    func sendCurrent(_ mode: Sorter.Mode) {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        let folder = Sorter.destination(for: url)
        do {
            let done = try Sorter.transfer(frameGroup(url), to: folder, mode: mode)
            if mode == .move {
                deleted.append(done.map { (original: $0.original, trashed: $0.moved) })
                removeFromList(Set(done.map { $0.original }))
            }
            flash(mode == .move ? L("Переміщено в «%@»", folder.lastPathComponent) : L("Скопійовано в «%@»", folder.lastPathComponent))
        } catch {
            showError(L("Не вдалося перенести «%@»", url.lastPathComponent), error)
        }
    }

    private static let sortRuleKey = "sortMarkedRule"
    private static let sortModeKey = "sortMarkedCopy"

    /// «Перемістити позначені…»: усі фото з потрібною оцінкою або міткою — одним махом.
    func sendMarked() {
        guard !files.isEmpty, !isConfirmingDelete else { return }
        let frames = files
        let missing = frames.filter { marks[$0] == nil }
        let sources = missing.map { pairedRaw[$0] ?? companions(of: $0).first(where: ImageLoader.isRaw) ?? $0 }
        if !missing.isEmpty { flash(L("Читання оцінок…")) }
        markQueue.async { [weak self] in
            let found = sources.map(Ratings.read)
            DispatchQueue.main.async {
                guard let self else { return }
                for (u, m) in zip(missing, found) where self.marks[u] == nil { self.marks[u] = m }
                self.flashText = nil
                self.updateOverlay()
                self.showSortDialog(frames: frames.filter { self.files.contains($0) })
            }
        }
    }

    /// Правила відбору в діалозі: ★1+ … ★5+, потім кольорові мітки.
    private func matches(_ mark: PhotoMark, rule: Int) -> Bool {
        rule < 5 ? mark.rating >= rule + 1 : mark.label == ColorLabel.allCases[rule - 5]
    }

    private func showSortDialog(frames: [URL]) {
        let rule = NSPopUpButton()
        for r in 1...5 { rule.addItem(withTitle: L("%@ і вище", String(repeating: "★", count: r))) }
        for label in ColorLabel.allCases { rule.addItem(withTitle: L("Мітка: %@", label.title)) }
        rule.selectItem(at: min(UserDefaults.standard.integer(forKey: Self.sortRuleKey), rule.numberOfItems - 1))
        let mode = NSPopUpButton()
        mode.addItems(withTitles: [L("Перемістити"), L("Скопіювати")])
        mode.selectItem(at: UserDefaults.standard.bool(forKey: Self.sortModeKey) ? 1 : 0)
        let count = NSTextField(labelWithString: "")
        let folder = frames.first.map(Sorter.destination(for:))
        let whereLabel = NSTextField(labelWithString: L("Куди: %@", (folder?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""))
        whereLabel.lineBreakMode = .byTruncatingMiddle
        whereLabel.textColor = .secondaryLabelColor

        func selected() -> [URL] { frames.filter { matches(marks[$0] ?? PhotoMark(), rule: rule.indexOfSelectedItem) } }
        let alert = NSAlert()
        alert.messageText = L("Перемістити позначені фото")
        alert.addButton(withTitle: L("Перемістити"))
        alert.addButton(withTitle: L("Скасувати")).keyEquivalent = "\u{1b}"
        let refresh = { [weak self] in
            guard let self else { return }
            let chosen = selected()
            let fileCount = chosen.reduce(0) { $0 + self.frameGroup($1).count }
            count.stringValue = L("Підходить: %d фото (%d файлів)", chosen.count, fileCount)
            alert.buttons.first?.title = mode.indexOfSelectedItem == 1 ? L("Скопіювати") : L("Перемістити")
            alert.buttons.first?.isEnabled = !chosen.isEmpty
        }
        let actions = PopUpActions(refresh)
        rule.target = actions; rule.action = #selector(PopUpActions.changed)
        mode.target = actions; mode.action = #selector(PopUpActions.changed)

        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            return NSStackView(views: [label, control])
        }
        let stack = NSStackView(views: [row(L("Які фото:"), rule), row(L("Дія:"), mode), whereLabel, count])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 120)
        whereLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        alert.accessoryView = stack
        refresh()

        isConfirmingDelete = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            _ = actions
            guard let self else { return }
            self.isConfirmingDelete = false
            self.window?.makeFirstResponder(self.canvas)
            UserDefaults.standard.set(rule.indexOfSelectedItem, forKey: Self.sortRuleKey)
            UserDefaults.standard.set(mode.indexOfSelectedItem == 1, forKey: Self.sortModeKey)
            guard response == .alertFirstButtonReturn, let folder else { return }
            self.transferMarked(selected(), to: folder, mode: mode.indexOfSelectedItem == 1 ? .copy : .move)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private func transferMarked(_ frames: [URL], to folder: URL, mode: Sorter.Mode) {
        let groups = frames.map(frameGroup)
        flash(mode == .move ? L("Переміщення…") : L("Копіювання…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [(original: URL, moved: URL)] = []
            var failure: (URL, Error)?
            for group in groups {
                do { done += try Sorter.transfer(group, to: folder, mode: mode) } catch { failure = (group[0], error); break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let frameCount = groups.prefix { group in done.contains { $0.original == group[0] } }.count
                if mode == .move, !done.isEmpty {
                    self.deleted.append(done.map { (original: $0.original, trashed: $0.moved) })
                    self.removeFromList(Set(done.map { $0.original }))
                }
                self.flash(mode == .move ? L("Переміщено %d фото в «%@»", frameCount, folder.lastPathComponent)
                                         : L("Скопійовано %d фото в «%@»", frameCount, folder.lastPathComponent))
                if let (url, error) = failure {
                    self.showError(L("Не вдалося перенести «%@»", url.lastPathComponent), error)
                }
            }
        }
    }

    /// Меню «Файл → Папка для відсортованих…».
    func chooseSortFolder() {
        let alert = NSAlert()
        alert.messageText = L("Папка для відсортованих фото")
        let now = Sorter.customFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            ?? L("підпапка «%@» у папці з фото", L("Відсортовано"))
        alert.informativeText = L("Зараз: %@", now)
        alert.addButton(withTitle: L("Обрати папку…"))
        alert.addButton(withTitle: L("Підпапка «%@»", L("Відсортовано")))
        alert.addButton(withTitle: L("Скасувати")).keyEquivalent = "\u{1b}"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = L("Обрати")
                panel.message = L("Куди переносити фото клавішами M і C")
                let done: (NSApplication.ModalResponse) -> Void = { r in
                    if r == .OK, let url = panel.url { Sorter.customFolder = url }
                }
                // Аркуш із аркуша не відкривається — чекаємо, поки закриється попередній
                DispatchQueue.main.async {
                    if let window = self.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
                }
            case .alertSecondButtonReturn:
                Sorter.customFolder = nil
            default:
                break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: - Меню на правий клік

    private func contextMenu() -> NSMenu? {
        guard files.indices.contains(index) else { return nil }
        let url = files[index]
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [],
                  enabled: Bool = true, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            i.keyEquivalentModifierMask = mods
            i.isEnabled = enabled
            menu.addItem(i)
        }
        let editorTitle = externalEditorName.map { L("Відкрити в %@ (E)", $0) } ?? L("Відкрити в іншій програмі (E)")
        item(editorTitle) { [weak self] in self?.openInExternalEditor() }
        item(L("Показати у Finder"), "r", .command) { [weak self] in self?.showInFinder() }
        menu.addItem(.separator())
        item(L("Перемістити в «%@» (M)", sortFolderName)) { [weak self] in self?.sendCurrent(.move) }
        item(L("Скопіювати в «%@» (C)", sortFolderName)) { [weak self] in self?.sendCurrent(.copy) }
        item(L("Перемістити позначені…")) { [weak self] in self?.sendMarked() }
        menu.addItem(.separator())
        if comparing {
            item(L("Розкладка порівняння (\\): %@", compareLayoutTitle)) { [weak self] in self?.cycleCompareLayout() }
            item(L("Закрити порівняння (Esc)")) { [weak self] in self?.exitCompare() }
            menu.addItem(.separator())
        }
        item(L("Копіювати файл"), "c", .command) { [weak self] in self?.copyFileToPasteboard() }
        item(L("Копіювати як картинку"), "c", [.command, .option]) { [weak self] in self?.copyToPasteboard() }
        menu.addItem(.separator())
        let rateItem = NSMenuItem(title: L("Оцінка і мітка"), action: nil, keyEquivalent: "")
        let rateMenu = NSMenu()
        rateMenu.autoenablesItems = false
        let mark = marks[url] ?? PhotoMark()
        for r in 1...5 {
            let i = ClosureMenuItem(title: String(repeating: "★", count: r) + "  (\(r))", keyEquivalent: "") { [weak self] in self?.setRating(r) }
            i.state = mark.rating == r ? .on : .off
            rateMenu.addItem(i)
        }
        rateMenu.addItem(.separator())
        for (n, label) in ColorLabel.allCases.enumerated() {
            let i = ClosureMenuItem(title: "\(label.title)  (\(n + 6))", keyEquivalent: "") { [weak self] in self?.setLabel(label) }
            i.state = mark.label == label ? .on : .off
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                label.color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            i.image = dot
            rateMenu.addItem(i)
        }
        rateItem.submenu = rateMenu
        menu.addItem(rateItem)
        menu.addItem(.separator())
        item(L("Повернути ліворуч (L)")) { [weak self] in self?.rotate(by: -1) }
        item(L("Повернути праворуч (R)")) { [weak self] in self?.rotate(by: 1) }
        item(L("Проявити RAW / вбудований JPEG (A)"), enabled: ImageLoader.isRaw(url) || pairedRaw[url] != nil) { [weak self] in self?.toggleRawDevelop() }
        item(canvas.isFit ? L("Реальний розмір 100% (Z)") : L("Вписати у вікно (0)")) { [weak self] in self?.toggleActualSize() }
        menu.addItem(.separator())
        item(L("Перемістити в Кошик (Delete)")) { [weak self] in self?.deleteCurrent() }
        item(L("Скасувати видалення або переміщення"), "z", .command, enabled: canUndoDelete) { [weak self] in self?.undoDelete() }
        menu.addItem(.separator())
        item(L("Закріпити інформаційну панель (I)")) { [weak self] in self?.togglePanel() }
        menu.items.last?.state = isPinned ? .on : .off
        item(L("Повний екран (F / Enter)")) { [weak self] in self?.toggleFullScreen() }
        return menu
    }

    // MARK: - Буфер обміну

    /// Коротке повідомлення в зеленому рядку («Скопійовано»).
    private var flashText: String?

    private func flash(_ text: String) {
        flashText = text
        updateOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.flashText == text else { return }
            self.flashText = nil
            self.updateOverlay()
        }
    }

    /// ⌘C: скопіювати сам файл (як у Finder).
    func copyFileToPasteboard() {
        guard let file = displayedFile else { return }
        Clipboard.write(file: file)
        flash(L("Файл скопійовано"))
    }

    /// ⌥⌘C: скопіювати як картинку (як зараз на екрані — з поворотом і проявкою RAW).
    func copyToPasteboard() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        let rotation = rotations[url] ?? 0
        let developed = rawShownFor == url ? loader.developedFull(pairedRaw[url] ?? url) : nil
        flash(L("Копіювання…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let jpeg = Clipboard.jpegData(for: url, developed: developed, rotation: rotation)
            DispatchQueue.main.async {
                guard let self else { return }
                if let jpeg {
                    Clipboard.write(jpeg: jpeg)
                    self.flash(L("Скопійовано"))
                } else {
                    NSSound.beep()
                    self.flash(L("Не вдалося скопіювати"))
                }
            }
        }
    }

    // MARK: - Поворот, Finder, інша програма

    /// L / R: повернути фото на екрані на 90°.
    func rotate(by step: Int) {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        let value = (((rotations[url] ?? 0) + step) % 4 + 4) % 4
        rotations[url] = value
        canvas.setRotation(value)
        updateCompareLayout()
    }

    /// ⌘R: показати поточний файл у Finder.
    func showInFinder() {
        guard let file = displayedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private static let editorKey = "externalEditorPath"

    var externalEditorName: String? {
        guard let path = UserDefaults.standard.string(forKey: Self.editorKey) else { return nil }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    /// E: відкрити поточне фото в обраній програмі (Lightroom, Photoshop, DxO…). Перший раз — спитати яку.
    func openInExternalEditor() {
        guard let url = displayedFile else { return }
        if let path = UserDefaults.standard.string(forKey: Self.editorKey), FileManager.default.fileExists(atPath: path) {
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self.showError(L("Не вдалося відкрити «%@»", url.lastPathComponent), error) } }
            }
        } else {
            chooseExternalEditor(thenOpen: true)
        }
    }

    func chooseExternalEditor(thenOpen: Bool = false) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.message = L("Оберіть програму, в якій відкривати фото клавішею E")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let app = panel.url else { return }
            UserDefaults.standard.set(app.path, forKey: Self.editorKey)
            if thenOpen { self.openInExternalEditor() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Панель і повний екран

    var isPanelPinned: Bool { isPinned }

    /// Клавіша I / Tab: закріпити або відкріпити панель.
    func togglePanel() {
        isPinned.toggle()
        autoShown = false
        UserDefaults.standard.set(isPinned, forKey: Self.panelDefaultsKey)
        applyPanelState(animated: true)
    }

    private func mouseMoved(to point: NSPoint) {
        // Нижній край — смуга мініатюр (y у вікні рахується знизу)
        if !stripShown, point.y <= 6, !files.isEmpty {
            setStripShown(true)
        } else if stripShown, point.y > ThumbnailStripView.height + 30 {
            setStripShown(false)
        }

        // Правий край — інформаційна панель
        guard !isPinned, let width = window?.contentView?.bounds.width else { return }
        if !autoShown, point.x >= width - 8 {
            setAutoShown(true)
        } else if autoShown, point.x < width - Self.panelSize - 30 {
            setAutoShown(false)
        }
    }

    private func setStripShown(_ shown: Bool) {
        guard stripShown != shown, let container = window?.contentView else { return }
        stripShown = shown
        strip.isOnScreen = shown
        if shown { strip.scrollToCurrent(animated: false) }
        // Лише виїжджає знизу, без зміни прозорості: на повністю прозорій смузі
        // macOS іноді не малює мініатюри, які встигли завантажитися.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            stripBottom.animator().constant = shown ? 0 : ThumbnailStripView.height
            container.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            if shown { self?.strip.redrawVisible() }
        })
    }

    /// Перехід до фото за номером (клік по мініатюрі).
    func goTo(index target: Int) {
        guard files.indices.contains(target), target != index else { return }
        direction = target > index ? 1 : -1
        index = target
        showCurrent()
        window?.makeFirstResponder(canvas)
    }

    private func setAutoShown(_ shown: Bool) {
        guard !isPinned, autoShown != shown else { return }
        autoShown = shown
        applyPanelState(animated: true)
    }

    private func applyPanelState(animated: Bool) {
        let visible = isPinned || autoShown
        canvasToEdge.isActive = !isPinned
        canvasToPanel.isActive = isPinned
        let offset: CGFloat = visible ? 0 : Self.panelSize
        let alpha: CGFloat = visible ? 1 : 0
        guard animated, let container = window?.contentView else {
            panelTrailing.constant = offset
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panelTrailing.animator().constant = offset
            panel.animator().alphaValue = alpha
            container.layoutSubtreeIfNeeded()
        }
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func enterFullScreen() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func toggleActualSize() { canvas.toggleActualSize() }
    func fit() { canvas.fit() }
    func zoomIn() { canvas.zoomStep(1.25) }
    func zoomOut() { canvas.zoomStep(1 / 1.25) }

    // MARK: - Клавіатура (за кодами клавіш, тож працює і в українській розкладці)

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 124, 125, 121: navigate(1)                 // → ↓ PageDown
        case 123, 126, 116: navigate(-1)                // ← ↑ PageUp
        case 51, 117: deleteCurrent()                   // Backspace / Delete — у Кошик
        case 49: navigate(shift ? -1 : 1)               // Пробіл / Shift+Пробіл
        case 115: goTo(first: true)                     // Home
        case 119: goTo(first: false)                    // End
        case 36, 76, 3: toggleFullScreen()              // Enter, F
        case 53 where comparing:                        // Esc у порівнянні — закрити порівняння
            exitCompare()
        case 53:                                        // Esc — повністю закрити програму
            NSApp.terminate(nil)
        case 34, 48: togglePanel()                      // I, Tab
        case 17:                                        // T — рядок зверху
            let on = !canvas.isOverlayEnabled
            stage.left.isOverlayEnabled = on
            stage.right.isOverlayEnabled = on
        case 0: toggleRawDevelop()                      // A — проявити RAW
        case 37: rotate(by: -1)                         // L — повернути проти годинникової
        case 15: rotate(by: 1)                          // R — повернути за годинниковою
        case 14: openInExternalEditor()                 // E — відкрити в іншій програмі
        case 42 where comparing: cycleCompareLayout()   // \\ — розкладка порівняння
        case 46: sendCurrent(.move)                     // M — перемістити у «Відсортовано»
        case 8: sendCurrent(.copy)                      // C — скопіювати у «Відсортовано»
        case 6: toggleActualSize()                      // Z
        case 18, 83: setRating(1)                       // 1–5 — зірки (і на цифровому блоці)
        case 19, 84: setRating(2)
        case 20, 85: setRating(3)
        case 21, 86: setRating(4)
        case 23, 87: setRating(5)
        case 22, 88: setLabel(.red)                     // 6–9 — кольорові мітки, як у Lightroom
        case 26, 89: setLabel(.yellow)
        case 28, 91: setLabel(.green)
        case 25, 92: setLabel(.blue)
        case 29: fit()                                  // 0
        case 24, 69: zoomIn()                           // = / +
        case 27, 78: zoomOut()                          // - (і на цифровому блоці)
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        listingToken = UUID()
    }
}
