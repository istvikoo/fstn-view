import AppKit

/// Підпапка, прочитана з диска: адреса і назва для показу.
struct FolderEntry {
    let url: URL
    let title: String
}

/// Вузол дерева папок. Підпапки читаються у фоні, коли вузол розгортають:
/// на мережевому диску це може тривати десятки секунд, і вікно не повинне чекати.
final class FolderNode {
    let url: URL
    let title: String
    let isVolume: Bool
    private(set) var children: [FolderNode]?
    /// Вміст папки змінився — перечитати (старий список лишається на екрані, поки читається новий).
    private(set) var isStale = false
    var isLoading = false

    init(url: URL, title: String? = nil, isVolume: Bool = false) {
        self.url = url.standardizedFileURL
        self.title = title ?? FileManager.default.displayName(atPath: url.path)
        self.isVolume = isVolume
    }

    /// Підпапки (без прихованих і без «пакетів» на кшталт .photoslibrary). Читає диск — лише у фоні.
    static func subfolders(of url: URL) -> [FolderEntry] {
        if ImageLoader.isNetworkVolume(url) {
            // Мережевий диск: імена одним проходом, «пакет» перевіряємо лише в папок з розширенням (.app тощо)
            return ImageLoader.directoryEntries(url)
                .filter(\.isFolder)
                .map { url.appendingPathComponent($0.name, isDirectory: true) }
                .filter { $0.pathExtension.isEmpty || (try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { FolderEntry(url: $0.standardizedFileURL, title: $0.lastPathComponent) }
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            // «Пакет» перевіряємо лише для папок: для кожного файлу це зайвий запит до диска
            .filter { (try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderEntry(url: $0.standardizedFileURL, title: FileManager.default.displayName(atPath: $0.path)) }
    }

    /// Ставить прочитані підпапки. Вузли, що вже були, лишаються ті самі — з ними і їхнє розгортання.
    func setChildren(_ entries: [FolderEntry]) {
        let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        children = entries.map { old[$0.url] ?? FolderNode(url: $0.url, title: $0.title) }
        isStale = false
    }

    /// Підпапки вже прочитані.
    var isLoaded: Bool { children != nil }

    /// Папку перейменували, створили підпапку («Відсортовано») тощо — перечитати.
    func invalidate() { isStale = true }
}

extension URL {
    /// Папка лежить у `parent` (або це вона сама). Порівнюємо цілі складові шляху,
    /// щоб /Users/ann2 не вважалася всередині /Users/ann.
    func isInside(_ parent: URL) -> Bool {
        let a = standardizedFileURL.pathComponents, b = parent.standardizedFileURL.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }
}

/// Заголовок розділу в панелі («Вибране», «Папки»).
private final class SectionNode {
    let title: String
    var items: [FolderNode]
    init(title: String, items: [FolderNode]) {
        self.title = title
        self.items = items
    }
}

/// Панель папок ліворуч: «Вибране» (стандартні папки, диски, власні) і дерево поточної папки.
final class FolderPanelView: NSVisualEffectView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let width: CGFloat = 230

    /// Клік по папці — відкрити її.
    var onOpen: ((URL) -> Void)?

    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var favorites = SectionNode(title: "", items: [])
    private var tree = SectionNode(title: "", items: [])
    private var current: URL?

    /// Кількість фото в папках (рахується у фоні, лише для видимих).
    private var counts: [URL: Int] = [:]
    private var counting = Set<URL>()
    private let countQueue = DispatchQueue(label: "fstn.folderCounts", qos: .utility)

    private static let favoritesKey = "favoriteFolders"

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active

        let column = NSTableColumn(identifier: .init("folder"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: AppLanguage.changed, object: nil)
        rebuildFavorites()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Дані

    private var customFavorites: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: Self.favoritesKey) }
    }

    private func rebuildFavorites() {
        let fm = FileManager.default
        var items: [FolderNode] = []
        for dir in [FileManager.SearchPathDirectory.picturesDirectory, .desktopDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first { items.append(FolderNode(url: u)) }
        }
        for u in customFavorites where fm.fileExists(atPath: u.path) {
            items.append(FolderNode(url: u))
        }
        // Підключені диски й карти пам'яті (без системного)
        let keys: Set<URLResourceKey> = [.volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        for v in volumes {
            // Лише локальні диски й карти пам'яті: без системного і без мережевих/віртуальних
            let values = try? v.resourceValues(forKeys: keys)
            if values?.volumeIsRootFileSystem == true || values?.volumeIsBrowsable == false || values?.volumeIsLocal == false { continue }
            items.append(FolderNode(url: v, isVolume: true))
        }
        favorites = SectionNode(title: L("Вибране"), items: items)
        reload()
    }

    @objc private func volumesChanged() { rebuildFavorites() }

    @objc private func languageChanged() {
        favorites = SectionNode(title: L("Вибране"), items: favorites.items)
        tree = SectionNode(title: L("Папки"), items: tree.items)
        reload()
    }

    /// Показати в дереві папку, яку зараз переглядають: розгорнути шлях до неї і виділити.
    /// Останній запит показати папку (поки шлях до неї читається у фоні, могли відкрити іншу).
    private var pathToken = UUID()
    private let listQueue = DispatchQueue(label: "fstn.folderList", qos: .userInitiated)

    func setCurrentFolder(_ folder: URL) {
        let folder = folder.standardizedFileURL
        current = folder
        // Корінь дерева — домашня папка або диск, на якому лежить папка
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let root: URL
        if folder.isInside(home) {
            root = home
        } else if let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume {
            root = volume.standardizedFileURL
        } else {
            root = URL(fileURLWithPath: "/")
        }
        // Уже прочитані підпапки на шляху — щоб не читати їх із диска вдруге
        var known: [URL: [FolderEntry]] = [:]
        func collect(_ nodes: [FolderNode]) {
            for n in nodes where folder.isInside(n.url) {
                guard let kids = n.children, !n.isStale else { continue }
                known[n.url] = kids.map { FolderEntry(url: $0.url, title: $0.title) }
                collect(kids)
            }
        }
        collect(tree.items)
        let token = UUID()
        pathToken = token
        // Шлях від кореня до папки читаємо у фоні; якщо на ньому є прихована папка (напр. /private/tmp),
        // дерево починаємо з батьківської папки
        listQueue.async { [weak self] in
            func path(from root: URL) -> [URL: [FolderEntry]]? {
                var lists: [URL: [FolderEntry]] = [:]
                var level = root
                for part in folder.pathComponents.dropFirst(root.pathComponents.count) {
                    let subs = known[level] ?? FolderNode.subfolders(of: level)
                    lists[level] = subs
                    guard let next = subs.first(where: { $0.url.lastPathComponent == part }) else { return nil }
                    level = next.url
                }
                return lists
            }
            var top = root
            var lists = path(from: root)
            if lists == nil {
                top = folder.deletingLastPathComponent().standardizedFileURL
                lists = path(from: top)
            }
            if lists == nil { top = folder }
            let found = lists ?? [:]
            // Назву теж читаємо тут: на мережевому диску це запит до сервера
            let topTitle = FileManager.default.displayName(atPath: top.path)
            DispatchQueue.main.async {
                guard let self, self.pathToken == token else { return }
                self.showPath(to: folder, top: top, title: topTitle, lists: found)
            }
        }
    }

    /// Розгорнути в дереві шлях до папки (підпапки вже прочитані у фоні) і виділити її.
    private func showPath(to folder: URL, top topURL: URL, title: String, lists: [URL: [FolderEntry]]) {
        let top = tree.items.first?.url == topURL ? tree.items[0] : FolderNode(url: topURL, title: title)
        var chain = [top]
        var node = top
        for part in folder.pathComponents.dropFirst(topURL.pathComponents.count) {
            if let subs = lists[node.url], !node.isLoaded || node.isStale { node.setChildren(subs) }
            guard let next = node.children?.first(where: { $0.url.lastPathComponent == part }) else { break }
            chain.append(next)
            node = next
        }
        if tree.items.first !== top {
            tree = SectionNode(title: L("Папки"), items: [top])
            reload()
        } else {
            for n in chain.dropLast() { outline.reloadItem(n, reloadChildren: true) }
        }
        for n in chain { outline.expandItem(n) }
        let row = outline.row(forItem: chain[chain.count - 1])
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        // Відкрили фото в захищеній папці — тепер можна порахувати і її сусідів, які вже на екрані
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? FolderNode, counts[n.url] == nil, mayRead(n.url) { count(n.url) }
        }
    }

    /// Папку змінили (з'явилась «Відсортовано», перенесли фото) — оновити її підпапки й кількість.
    /// Кілька папок одразу — поточну папку в дереві шукаємо лише раз наприкінці.
    func refresh(_ folders: Set<URL>) {
        for folder in folders { refreshNode(folder) }
        if let current { setCurrentFolder(current) }
    }

    private func refreshNode(_ folder: URL) {
        let folder = folder.standardizedFileURL
        counts[folder] = nil
        func find(_ nodes: [FolderNode]) -> FolderNode? {
            for n in nodes {
                if n.url == folder { return n }
                if folder.isInside(n.url), outline.isItemExpanded(n), let kids = n.children,
                   let hit = find(kids) { return hit }
            }
            return nil
        }
        if let node = find(tree.items) {
            node.invalidate()
            loadChildren(of: node)
        } else {
            outline.reloadData()
        }
    }

    private func reload() {
        outline.reloadData()
        outline.expandItem(favorites)
        outline.expandItem(tree)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return tree.items.isEmpty ? 1 : 2
        case let s as SectionNode: return s.items.count
        case let n as FolderNode:
            if !n.isLoaded || n.isStale { loadChildren(of: n) }
            return n.children?.count ?? 0
        default: return 0
        }
    }

    /// Читає підпапки у фоні й показує їх, коли прочитано.
    private func loadChildren(of node: FolderNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        listQueue.async { [weak self] in
            let subs = FolderNode.subfolders(of: url)
            DispatchQueue.main.async {
                node.isLoading = false
                node.setChildren(subs)
                guard let self else { return }
                let expanded = self.outline.isItemExpanded(node)
                self.outline.reloadItem(node, reloadChildren: true)
                if expanded { self.outline.expandItem(node) }
                if let current = self.current, current.isInside(node.url), current != node.url {
                    self.setCurrentFolder(current)        // виділити поточну папку, коли її рядок з'явився
                }
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return index == 0 ? favorites : tree
        case let s as SectionNode: return s.items[index]
        case let n as FolderNode: return n.children?[index] ?? n
        default: return favorites
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is SectionNode { return true }
        // Вибране — лише ярлики, без розгортання; в дереві — розгортаються всі (порожні після читання — ні)
        guard let n = item as? FolderNode, (outlineView.parent(forItem: n) as? SectionNode) !== favorites else { return false }
        // Поки підпапки не прочитані — показуємо трикутник; потім — лише якщо вони є
        return n.children.map { !$0.isEmpty } ?? true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SectionNode }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is FolderNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let s = item as? SectionNode {
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: s.title.uppercased())
            text.font = .systemFont(ofSize: 10, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        guard let n = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FolderCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FolderCell ?? FolderCell(identifier: id)
        let symbol = n.isVolume ? "externaldrive" : "folder"
        cell.configure(title: n.title, symbol: symbol, count: counts[n.url])
        if counts[n.url] == nil, mayRead(n.url) { count(n.url) }
        return cell
    }

    /// Папки, доступ до яких macOS дає лише з дозволу користувача (Робочий стіл, Документи,
    /// Завантаження, iCloud Drive, зовнішні диски). Сама панель їх не читає, щоб не викликати
    /// запит «хоче отримати доступ» — лише коли там уже відкривали фото (дозвіл тоді вже є).
    private static let protectedRoots: [URL] = {
        let fm = FileManager.default
        var roots = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents"))
        roots.append(URL(fileURLWithPath: "/Volumes"))
        return roots.map(\.standardizedFileURL)
    }()

    private func mayRead(_ url: URL) -> Bool {
        guard let root = Self.protectedRoots.first(where: { url.isInside($0) }) else { return true }
        // Відкривали фото в цій захищеній області — дозвіл уже дано
        let area = root.path == "/Volumes"
            ? URL(fileURLWithPath: "/Volumes").appendingPathComponent(url.pathComponents.dropFirst(2).first ?? "")
            : root
        return current?.isInside(area) == true
    }

    /// Рахує фото в папці у фоні й оновлює рядок.
    private func count(_ url: URL) {
        guard counting.insert(url).inserted else { return }
        countQueue.async { [weak self] in
            let n = ImageLoader.countImages(in: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.counting.remove(url)
                self.counts[url] = n
                for row in 0..<self.outline.numberOfRows {
                    if let node = self.outline.item(atRow: row) as? FolderNode, node.url == url,
                       let cell = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FolderCell {
                        cell.setCount(n)
                    }
                }
            }
        }
    }

    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FolderNode else { return }
        onOpen?(node.url)
    }

    // MARK: - Вибране

    fileprivate func menuNode() -> FolderNode? {
        let row = outline.clickedRow
        return row >= 0 ? outline.item(atRow: row) as? FolderNode : nil
    }

    fileprivate func addFavorite(_ url: URL) {
        var list = customFavorites
        guard !list.contains(url) else { return }
        list.append(url)
        customFavorites = list
        rebuildFavorites()
        if let current { setCurrentFolder(current) }
    }

    fileprivate func removeFavorite(_ url: URL) {
        customFavorites = customFavorites.filter { $0.standardizedFileURL != url }
        rebuildFavorites()
        if let current { setCurrentFolder(current) }
    }

    fileprivate func isCustomFavorite(_ url: URL) -> Bool {
        customFavorites.contains { $0.standardizedFileURL == url }
    }
}

extension FolderPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = menuNode() else { return }
        let url = node.url
        menu.addItem(ClosureMenuItem(title: L("Відкрити"), keyEquivalent: "") { [weak self] in self?.onOpen?(url) })
        menu.addItem(ClosureMenuItem(title: L("Показати у Finder"), keyEquivalent: "") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(.separator())
        if isCustomFavorite(url) {
            menu.addItem(ClosureMenuItem(title: L("Прибрати з вибраного"), keyEquivalent: "") { [weak self] in self?.removeFavorite(url) })
        } else if !node.isVolume {
            menu.addItem(ClosureMenuItem(title: L("Додати у вибране"), keyEquivalent: "") { [weak self] in self?.addFavorite(url) })
        }
    }
}

/// Рядок папки: значок, назва, кількість фото праворуч.
private final class FolderCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.contentTintColor = .secondaryLabelColor
        for v in [icon, name, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbol: String, count: Int?) {
        name.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setCount(count)
    }

    func setCount(_ count: Int?) {
        countLabel.stringValue = count.map { $0 > 0 ? "\($0)" : "" } ?? ""
    }
}

/// Список папок не забирає клавіатуру: стрілки й надалі гортають фото.
private final class SidebarOutlineView: NSOutlineView {
    override var acceptsFirstResponder: Bool { false }
}
