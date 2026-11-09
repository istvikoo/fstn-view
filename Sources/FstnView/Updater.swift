import AppKit
import CryptoKit

/// Оновлення з GitHub Releases: шукає новішу версію, завантажує zip, замінює програму і перезапускає її.
/// Релізи збирає GitHub Actions (.github/workflows/release.yml) з тегу vX.Y.Z — див. README.
final class Updater {
    static let shared = Updater()

    private let lastCheckKey = "lastUpdateCheck"
    private var isBusy = false

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            /// Контрольна сума файлу від GitHub: «sha256:…» (у старих релізах її немає).
            let digest: String?
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    /// Тиха перевірка при запуску — не частіше ніж раз на добу.
    func checkOnLaunch() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(silent: true)
    }

    /// silent = true: повідомляти тільки якщо є оновлення.
    func check(silent: Bool) {
        guard !isBusy else { return }
        isBusy = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.githubRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    if !silent {
                        // 404 — релізів ще немає, тобто нової версії теж
                        status == 404 ? self.showUpToDate() : self.showError(error?.localizedDescription ?? "HTTP \(status)")
                    }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if Self.isVersion(latest, newerThan: AppInfo.version) {
                    self.offer(release, version: latest)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Діалоги

    private func offer(_ release: Release, version: String) {
        let alert = NSAlert()
        alert.messageText = L("Доступна нова версія %@ %@", AppInfo.name, version)
        var info = L("У вас версія %@.", AppInfo.version)
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + String(notes.prefix(800))
        }
        alert.informativeText = info
        let zip = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        if zip != nil { alert.addButton(withTitle: L("Встановити і перезапустити")) }
        alert.addButton(withTitle: L("Сторінка релізу"))
        alert.addButton(withTitle: L("Пізніше"))

        let response = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        if let zip, response == first {
            install(zip)
        } else if response == (zip == nil ? first : .alertSecondButtonReturn) {
            NSWorkspace.shared.open(release.html_url)
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L("У вас найновіша версія")
        alert.informativeText = "\(AppInfo.name) \(AppInfo.version)"
        alert.runModal()
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Не вдалося оновити програму")
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Встановлення

    /// Чому програму не можна замінити новою версією (nil — можна):
    /// запущено прямо з DMG чи з тимчасової копії (App Translocation), або немає прав на запис у папку.
    private static var replaceProblem: String? {
        let app = Bundle.main.bundleURL
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        if app.path.contains("/AppTranslocation/") || readOnly {
            return L("Програму запущено не з папки «Програми» (напр. прямо з DMG), тому її не можна замінити. Перетягніть %@ у «Програми», запустіть звідти і спробуйте ще раз.", AppInfo.name)
        }
        let folder = app.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            return L("Немає прав на запис у папку «%@», тому програму не можна замінити. Оновіть її з облікового запису адміністратора або встановіть новий DMG зі сторінки релізу.", FileManager.default.displayName(atPath: folder.path))
        }
        return nil
    }

    private func install(_ asset: Release.Asset) {
        if let problem = Self.replaceProblem {
            showError(problem)
            return
        }
        isBusy = true
        let task = URLSession.shared.downloadTask(with: asset.browser_download_url) { [weak self] file, _, error in
            var result: Result<URL, Error>
            if let file {
                result = Result {
                    try Self.verify(file, digest: asset.digest)
                    return try Self.unpack(zip: file)
                }
            } else {
                result = .failure(error ?? URLError(.unknown))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.hideProgress()
                switch result {
                case .success(let newApp):
                    do {
                        try self.replaceAndRelaunch(with: newApp)
                    } catch {
                        try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent())
                        self.showError(error.localizedDescription)
                    }
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
        showProgress(for: task)
        task.resume()
    }

    // MARK: - Хід завантаження

    private var progressPanel: NSPanel?
    private var progressObservation: NSKeyValueObservation?

    private func showProgress(for task: URLSessionDownloadTask) {
        let label = NSTextField(labelWithString: L("Завантаження оновлення…"))
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = AppInfo.name
        panel.contentView = stack
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.orderFront(nil)
        progressPanel = panel
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { bar.doubleValue = value }
        }
    }

    private func hideProgress() {
        progressObservation = nil
        progressPanel?.close()
        progressPanel = nil
    }

    /// Звіряє завантажений файл з контрольною сумою з GitHub — пошкоджений або підмінений архів не встановлюємо.
    private static func verify(_ file: URL, digest: String?) throws {
        guard let digest = digest?.lowercased(), digest.hasPrefix("sha256:") else { return }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest.dropFirst("sha256:".count) else {
            throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Завантажений файл оновлення пошкоджено: контрольна сума не збігається. Спробуйте ще раз або встановіть DMG зі сторінки релізу.")])
        }
    }

    /// Розпаковує zip у тимчасову папку і повертає знайдений .app (перевіряючи, що це саме наша програма).
    private static func unpack(zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fstn-view-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: dir) } }   // не лишаємо сміття після невдачі
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])

        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: L("В архіві оновлення немає програми %@", AppInfo.name)])
        }
        // Файл завантажено не браузером, але про всяк випадок знімаємо позначку карантину
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        keep = true
        return app
    }

    private func replaceAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent())   // порожня тимчасова папка
        // Перезапуск після виходу поточного процесу
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) exited with \(p.terminationStatus)"])
        }
    }

    // MARK: - Порівняння версій

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
