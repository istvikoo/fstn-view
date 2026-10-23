import AppKit
import SwiftUI

final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let state = ViewerState()
    private let canvas = ImageCanvasView()
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

    private var files: [URL] = [] {
        didSet { strip.setFiles(files, current: index) }
    }
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
    /// Видалені в Кошик фото (для ⌘Z).
    private var deleted: [(original: URL, trashed: URL)] = []
    private var listingToken = UUID()
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

        UserDefaults.standard.register(defaults: [Self.panelDefaultsKey: false])
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
        for v in [canvas, strip, blur] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        panelTrailing = blur.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        canvasToEdge = canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        canvasToPanel = canvas.trailingAnchor.constraint(equalTo: blur.leadingAnchor)
        stripBottom = strip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: ThumbnailStripView.height)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.widthAnchor.constraint(equalToConstant: Self.panelSize),
            panelTrailing,
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: ThumbnailStripView.height),
            stripBottom,
        ])
        strip.onSelect = { [weak self] i in self?.goTo(index: i) }
        window.contentView = container
        container.onMouseMoved = { [weak self] point in self?.mouseMoved(to: point) }
        container.onMouseExited = { [weak self] in
            self?.setAutoShown(false)
            self?.setStripShown(false)
        }
        applyPanelState(animated: false)

        window.setFrameAutosaveName("FstnViewMain")
        if !window.setFrameUsingName("FstnViewMain") { window.center() }

        canvas.onNavigate = { [weak self] step in self?.navigate(step) }
        canvas.onZoomChanged = { [weak self] in self?.zoomChanged() }
        canvas.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        canvas.onDropURL = { [weak self] url in self?.open(url) }
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
            files = [url]
            index = 0
            showCurrent()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = ImageLoader.listImages(in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listingToken == token else { return }
                if isFolder {
                    self.files = list
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
                    if let i = list.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                        self.files = list
                        self.index = i
                    }
                    self.updatePosition()
                    self.preloadNeighbors()
                }
            }
        }
    }

    // MARK: - Перегляд

    private func showCurrent() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
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
        canvas.setImage(quick.image, size: quick.displaySize, resetView: true)
        state.fileName = quick.url.lastPathComponent
        state.info = quick.info
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
        canvas.setImage(image.preview, size: image.displaySize, resetView: !keepView)
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
        state.fileName = image.url.lastPathComponent
        state.info = image.info
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
        updateOverlay()
    }

    /// «IMG.CR3  ( 6720 x 4480 = 30.1 MP , 8,9 MB )  [ 19 / 20 ]  27%»
    private func updateOverlay() {
        guard files.indices.contains(index) else {
            canvas.setOverlayText("")
            return
        }
        var parts = [files[index].lastPathComponent]
        if let info = state.info, info.url == files[index] {
            let w = Int(info.pixelSize.width), h = Int(info.pixelSize.height)
            var details = "\(w) x \(h) = \(String(format: "%.2f", Double(w * h) / 1_000_000)) MP"
            if let bytes = info.fileSize {
                details += " , " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            parts.append("( \(details) )")
        }
        parts.append("[ \(index + 1) / \(files.count) ]")
        let here = files[index]
        if embeddedShownFor == here {
            parts.append("[ JPEG ]")
        } else if rawShownFor == here || (current?.url == here && current?.isDevelopedRAW == true) {
            parts.append("[ RAW ]")
        } else if rawDeveloping == here {
            parts.append("[ RAW… ]")
        }
        if canvas.hasImage {
            parts.append("\(Int((canvas.zoom * 100).rounded()))%")
        }
        canvas.setOverlayText(parts.joined(separator: "  "))
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
        showCurrent()
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
            if rawShownFor == cur.url, let full = loader.developedFull(cur.url) {
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

    // MARK: - Проявка RAW (клавіша A)

    /// A: проявити поточне RAW-фото (лише його). Повторне A — назад до вбудованого JPEG.
    func toggleRawDevelop() {
        guard files.indices.contains(index) else { return }
        let url = files[index]
        guard ImageLoader.isRaw(url) else { NSSound.beep(); return }

        // Файли, де вбудований JPEG замалий (Sony ARW): за замовчуванням проявлений RAW,
        // A перемикає на JPEG камери і назад.
        if embeddedShownFor == url || (current?.url == url && current?.isDevelopedRAW == true) {
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
        loader.loadDeveloped(url, priority: .veryHigh) { [weak self] image in
            guard let self, self.files.indices.contains(self.index), self.files[self.index] == url,
                  self.rawDeveloping == url else { return }
            self.rawDeveloping = nil
            if let image {
                self.display(image, fromCache: false, developed: true)
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

        let alert = NSAlert()
        alert.messageText = L("Перемістити фото в Кошик?")
        alert.informativeText = L("«%@» буде переміщено в Кошик, а не видалено назавжди. Повернути фото можна з Кошика або клавішами ⌘Z, поки програма відкрита.", url.lastPathComponent)
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

    /// Переміщує фото в Кошик і показує наступне.
    private func moveToTrash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] trashed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showError(L("Не вдалося перемістити «%@» у Кошик", url.lastPathComponent), error)
                    return
                }
                if let trashedURL = trashed[url] {
                    self.deleted.append((original: url, trashed: trashedURL))
                }
                self.loader.forget(url)
                ThumbnailCache.shared.forget(url)
                guard let i = self.files.firstIndex(of: url) else { return }
                self.files.remove(at: i)
                if self.files.isEmpty {
                    self.current = nil
                    self.index = 0
                    self.clearInfo()
                    self.state.fileName = ""
                    self.updatePosition()
                    self.showHint { L("У папці більше немає зображень") }
                    return
                }
                if i < self.index {
                    // Видалили файл перед поточним — поточне фото те саме, зсуваємо номер
                    self.index -= 1
                    self.updatePosition()
                } else if i == self.index {
                    // Видалили поточне — показуємо наступне (або попереднє, якщо це було останнє)
                    self.index = min(self.index, self.files.count - 1)
                    self.showCurrent()
                } else {
                    self.updatePosition()
                }
            }
        }
    }

    var canUndoDelete: Bool { !deleted.isEmpty }

    /// ⌘Z: повертає останнє видалене фото з Кошика на старе місце.
    func undoDelete() {
        guard let last = deleted.popLast() else { NSSound.beep(); return }
        do {
            try FileManager.default.moveItem(at: last.trashed, to: last.original)
        } catch {
            showError(L("Не вдалося відновити «%@»", last.original.lastPathComponent), error)
            return
        }
        // Повертаємо у список, якщо переглядаємо ту саму папку
        let folder = last.original.deletingLastPathComponent().standardizedFileURL.path
        let currentFolder = files.first?.deletingLastPathComponent().standardizedFileURL.path
        if currentFolder == nil || currentFolder == folder {
            let name = last.original.lastPathComponent
            let pos = files.firstIndex { $0.lastPathComponent.localizedStandardCompare(name) == .orderedDescending } ?? files.count
            files.insert(last.original, at: pos)
            index = pos
            showCurrent()
        } else {
            open(last.original)
        }
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
        case 53:                                        // Esc — повністю закрити програму
            NSApp.terminate(nil)
        case 34, 48: togglePanel()                      // I, Tab
        case 17: canvas.isOverlayEnabled.toggle()       // T — рядок зверху
        case 0: toggleRawDevelop()                      // A — проявити RAW
        case 6, 18: toggleActualSize()                  // Z, 1
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
