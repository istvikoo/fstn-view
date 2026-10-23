import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Пропозиція зробити fstn view типовою програмою для фото.
/// Показується один раз при першому запуску; потім — з меню.
enum DefaultAppSetup {
    private static let promptShownKey = "defaultAppPromptShown"

    /// Звичайні формати фото.
    static var regularTypes: [UTType] {
        let ids = ["public.jpeg", "public.heic", "public.heif", "public.png", "public.tiff",
                   "org.webmproject.webp", "public.avif", "com.compuserve.gif", "com.microsoft.bmp"]
        return ids.compactMap { UTType($0) }.filter { supported.contains($0) }
    }

    /// Усі RAW-формати, які вміє читати macOS (CR3, CR2, NEF, ARW, DNG, RAF, ORF, RW2…).
    static var rawTypes: [UTType] {
        supported.filter { $0.conforms(to: .rawImage) }.sorted { $0.identifier < $1.identifier }
    }

    private static var supported: Set<UTType> {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return Set(ids.compactMap { UTType($0) })
    }

    // MARK: - Поточний стан

    static func isDefault(for type: UTType) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func isDefault(for types: [UTType]) -> Bool {
        !types.isEmpty && types.allSatisfy(isDefault(for:))
    }

    // MARK: - Перший запуск

    static func promptOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptShownKey) else { return }
        defaults.set(true, forKey: promptShownKey)
        // Вже типова для всього — питати нема про що
        if isDefault(for: regularTypes) && isDefault(for: rawTypes) { return }
        showDialog()
    }

    // MARK: - Вікно

    static func showDialog() {
        let alert = NSAlert()
        alert.messageText = L("Зробити %@ типовою програмою для фото?", AppInfo.name)
        alert.informativeText = L("Оберіть, які файли відкривати подвійним кліком у %@. Змінити вибір можна будь-коли в меню %@.", AppInfo.name, AppInfo.name)

        let regular = checkbox(L("Звичайні фото (JPEG, HEIC, PNG, TIFF, WebP…)"), alreadyDefault: isDefault(for: regularTypes))
        let raw = checkbox(L("RAW (CR3, CR2, NEF, ARW, DNG, RAF…)"), alreadyDefault: isDefault(for: rawTypes))
        let stack = NSStackView(views: [regular, raw])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("Зробити типовою"))
        alert.addButton(withTitle: L("Не зараз")).keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var types: [UTType] = []
        if regular.state == .on { types += regularTypes }
        if raw.state == .on { types += rawTypes }
        guard !types.isEmpty else { return }
        apply(types, regular: regular.state == .on, raw: raw.state == .on)
    }

    private static func checkbox(_ title: String, alreadyDefault: Bool) -> NSButton {
        let text = alreadyDefault ? title + " — " + L("вже типова") : title
        let box = NSButton(checkboxWithTitle: text, target: nil, action: nil)
        box.state = .on
        return box
    }

    // MARK: - Застосування

    private static func apply(_ types: [UTType], regular: Bool, raw: Bool) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failed: [String] = []
        let lock = NSLock()

        for type in types where !isDefault(for: type) {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if error != nil {
                    lock.lock()
                    failed.append(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let result = NSAlert()
            if failed.isEmpty {
                var groups: [String] = []
                if regular { groups.append(L("звичайних фото")) }
                if raw { groups.append(L("RAW")) }
                result.messageText = L("Готово")
                result.informativeText = L("%@ тепер відкриває %@ подвійним кліком.", AppInfo.name, groups.joined(separator: L(" і ")))
            } else {
                result.alertStyle = .warning
                result.messageText = L("Не для всіх форматів вдалося")
                result.informativeText = L("Не змінено для: %@", failed.joined(separator: ", "))
            }
            result.runModal()
        }
    }
}
