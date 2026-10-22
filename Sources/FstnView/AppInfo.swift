import Foundation

enum AppInfo {
    static let name = "fstn view"
    /// Репозиторій на GitHub, з якого беруться оновлення.
    static let githubRepo = "istvikoo/fstn-view"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
