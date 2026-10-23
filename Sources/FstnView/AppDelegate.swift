import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: ViewerWindowController?
    private var openedFromFinder = false

    private func viewer() -> ViewerWindowController {
        if let controller { return controller }
        let c = ViewerWindowController()
        controller = c
        c.showWindow(nil)
        // Одразу на весь екран
        DispatchQueue.main.async { c.enterFullScreen() }
        return c
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let c = viewer()
        if !openedFromFinder,
           let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
            c.open(URL(fileURLWithPath: path))
        }
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.checkOnLaunch()
        // Перший запуск: запропонувати стати типовою програмою для фото
        // (з невеликою паузою, щоб вікно встигло розгорнутися на весь екран)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DefaultAppSetup.promptOnFirstLaunch()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedFromFinder = true
        let c = viewer()
        c.window?.makeKeyAndOrderFront(nil)
        c.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Дії меню

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .folder]
        panel.message = L("Оберіть зображення або папку")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.viewer().open(url)
        }
    }

    @objc func toggleInfoPanel(_ sender: Any?) { viewer().togglePanel() }
    @objc func fitToWindow(_ sender: Any?) { viewer().fit() }
    @objc func toggleRawDevelop(_ sender: Any?) { viewer().toggleRawDevelop() }
    @objc func toggleGroupPairs(_ sender: Any?) { viewer().toggleGroupPairs() }
    @objc func rotateLeft(_ sender: Any?) { viewer().rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { viewer().rotate(by: 1) }
    @objc func showInFinder(_ sender: Any?) { viewer().showInFinder() }
    @objc func copyImage(_ sender: Any?) { viewer().copyToPasteboard() }
    @objc func copyFile(_ sender: Any?) { viewer().copyFileToPasteboard() }
    @objc func openInEditor(_ sender: Any?) { viewer().openInExternalEditor() }
    @objc func chooseEditor(_ sender: Any?) { viewer().chooseExternalEditor() }
    @objc func actualSize(_ sender: Any?) { viewer().toggleActualSize() }
    @objc func zoomIn(_ sender: Any?) { viewer().zoomIn() }
    @objc func zoomOut(_ sender: Any?) { viewer().zoomOut() }
    @objc func nextImage(_ sender: Any?) { viewer().navigate(1) }
    @objc func previousImage(_ sender: Any?) { viewer().navigate(-1) }
    @objc func firstImage(_ sender: Any?) { viewer().goTo(first: true) }
    @objc func lastImage(_ sender: Any?) { viewer().goTo(first: false) }
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.check(silent: false) }
    @objc func makeDefaultApp(_ sender: Any?) { DefaultAppSetup.showDialog() }

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) else { return }
        AppLanguage.setting = lang
        buildMenu()
    }

    @objc func deleteImage(_ sender: Any?) { viewer().deleteCurrent() }
    @objc func undoDelete(_ sender: Any?) { viewer().undoDelete() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleInfoPanel(_:)) {
            menuItem.state = (controller?.isPanelPinned ?? false) ? .on : .off
        }
        if menuItem.action == #selector(toggleGroupPairs(_:)) {
            menuItem.state = (controller?.groupsPairs ?? true) ? .on : .off
        }
        if menuItem.action == #selector(openInEditor(_:)) {
            let name = controller?.externalEditorName
            menuItem.title = name.map { L("Відкрити в %@ (E)", $0) } ?? L("Відкрити в іншій програмі (E)")
        }
        if menuItem.action == #selector(undoDelete(_:)) {
            return controller?.canUndoDelete ?? false
        }
        return true
    }

    // MARK: - Меню

    private func buildMenu() {
        let main = NSMenu()

        func submenu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            fill(menu)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target ?? self
            menu.addItem(item)
        }

        _ = submenu(AppInfo.name) { m in
            add(m, L("Про %@", AppInfo.name), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            add(m, L("Перевірити оновлення…"), #selector(checkForUpdates(_:)))
            add(m, L("Зробити типовою для фото…"), #selector(makeDefaultApp(_:)))
            m.addItem(.separator())
            add(m, L("Сховати %@", AppInfo.name), #selector(NSApplication.hide(_:)), "h", target: NSApp)
            add(m, L("Сховати інші"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
            m.addItem(.separator())
            add(m, L("Завершити %@", AppInfo.name), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }

        _ = submenu(L("Файл")) { m in
            add(m, L("Відкрити…"), #selector(openDocument(_:)), "o")
            add(m, L("Показати у Finder"), #selector(showInFinder(_:)), "r")
            m.addItem(.separator())
            add(m, L("Відкрити в іншій програмі (E)"), #selector(openInEditor(_:)))
            add(m, L("Обрати програму для E…"), #selector(chooseEditor(_:)))
            m.addItem(.separator())
            let close = NSMenuItem(title: L("Закрити вікно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            m.addItem(close)
        }

        _ = submenu(L("Правка")) { m in
            add(m, L("Відновити видалене фото"), #selector(undoDelete(_:)), "z")
            add(m, L("Копіювати файл"), #selector(copyFile(_:)), "c")
            add(m, L("Копіювати як картинку"), #selector(copyImage(_:)), "c", [.command, .option])
            m.addItem(.separator())
            add(m, L("Перемістити в Кошик (Delete)"), #selector(deleteImage(_:)), "\u{8}")
        }

        _ = submenu(L("Вигляд")) { m in
            add(m, L("Закріпити інформаційну панель (I)"), #selector(toggleInfoPanel(_:)), "i")
            m.addItem(.separator())
            add(m, L("Проявити RAW / вбудований JPEG (A)"), #selector(toggleRawDevelop(_:)))
            add(m, L("Обʼєднувати пари RAW+JPEG"), #selector(toggleGroupPairs(_:)))
            add(m, L("Повернути ліворуч (L)"), #selector(rotateLeft(_:)))
            add(m, L("Повернути праворуч (R)"), #selector(rotateRight(_:)))
            m.addItem(.separator())
            add(m, L("Вписати у вікно (0)"), #selector(fitToWindow(_:)), "0")
            add(m, L("Реальний розмір 100% (Z)"), #selector(actualSize(_:)), "1")
            add(m, L("Збільшити (+)"), #selector(zoomIn(_:)), "=")
            add(m, L("Зменшити (−)"), #selector(zoomOut(_:)), "-")
            m.addItem(.separator())
            let fs = NSMenuItem(title: L("Повний екран (F / Enter)"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            fs.keyEquivalentModifierMask = [.command, .control]
            m.addItem(fs)
        }

        _ = submenu(L("Перехід")) { m in
            add(m, L("Наступне (→ / Пробіл)"), #selector(nextImage(_:)), "]")
            add(m, L("Попереднє (←)"), #selector(previousImage(_:)), "[")
            m.addItem(.separator())
            add(m, L("Перше (Home)"), #selector(firstImage(_:)), "")
            add(m, L("Останнє (End)"), #selector(lastImage(_:)), "")
        }

        _ = submenu(L("Мова / Language")) { m in
            for lang in AppLanguage.allCases {
                let title: String
                switch lang {
                case .system: title = L("Як у системі")
                case .uk: title = "Українська"
                case .en: title = "English"
                }
                let item = NSMenuItem(title: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = lang.rawValue
                item.state = AppLanguage.setting == lang ? .on : .off
                m.addItem(item)
            }
        }

        let windowMenu = submenu(L("Вікно")) { m in
            add(m, L("Згорнути"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        }
        windowMenu.items.first?.target = nil

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
