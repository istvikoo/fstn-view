import AppKit

/// Перенесення відібраних фото в папку «Відсортовано» (клавіші M / C і «Перемістити позначені…»).
enum Sorter {
    enum Mode { case move, copy }

    private static let folderKey = "sortFolderPath"

    /// Обрана користувачем папка; nil — підпапка «Відсортовано» в поточній папці.
    static var customFolder: URL? {
        get { UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: folderKey) }
    }

    static func destination(for photo: URL) -> URL {
        customFolder ?? photo.deletingLastPathComponent().appendingPathComponent(L("Відсортовано"), isDirectory: true)
    }

    /// Переносить групу файлів одного кадру (фото, його пара, .xmp) в `folder`.
    /// Наявні файли не перезаписує: група отримує спільний номер «IMG_0001 (2).JPG», «IMG_0001 (2).CR3».
    /// Якщо щось не вдалося — уже перенесене повертається назад, і помилка йде далі.
    /// Повертає пари (звідки, куди).
    static func transfer(_ group: [URL], to folder: URL, mode: Mode) throws -> [(original: URL, moved: URL)] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        func target(_ url: URL, _ n: Int) -> URL {
            let base = url.deletingPathExtension().lastPathComponent
            let name = n == 1 ? base : "\(base) (\(n))"
            return folder.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        }
        var n = 1
        while group.contains(where: { fm.fileExists(atPath: target($0, n).path) }) { n += 1 }

        var done: [(original: URL, moved: URL)] = []
        do {
            for url in group {
                let to = target(url, n)
                // Між дисками moveItem копіює і лише після успішного копіювання видаляє оригінал
                if mode == .move { try fm.moveItem(at: url, to: to) } else { try fm.copyItem(at: url, to: to) }
                done.append((url, to))
            }
        } catch {
            for item in done.reversed() {
                if mode == .move { try? fm.moveItem(at: item.moved, to: item.original) } else { try? fm.removeItem(at: item.moved) }
            }
            throw error
        }
        return done
    }
}

/// Ціль для списків у діалозі: будь-яка зміна — перерахувати.
final class PopUpActions: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func changed() { handler() }
}
