import Foundation

/// Мова інтерфейсу. Вибір зберігається; «як у системі» — за мовою macOS.
enum AppLanguage: String, CaseIterable {
    case system, uk, en

    static let changed = Notification.Name("FstnView.languageChanged")
    private static let defaultsKey = "appLanguage"

    /// Що обрав користувач у меню.
    static var setting: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            resolved = resolve(newValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Мова, якою зараз показуються тексти (тільки uk або en).
    private(set) static var resolved: AppLanguage = resolve(setting)

    private static func resolve(_ lang: AppLanguage) -> AppLanguage {
        guard lang == .system else { return lang }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("uk") ? .uk : .en
    }
}

/// Переклад: ключ — український текст. Для англійської шукаємо в таблиці нижче.
/// Плейсхолдери %@ / %d підставляються через String(format:).
func L(_ uk: String) -> String {
    guard AppLanguage.resolved == .en else { return uk }
    return english[uk] ?? uk
}

func L(_ uk: String, _ args: CVarArg...) -> String {
    String(format: L(uk), arguments: args)
}

private let english: [String: String] = [
    // Меню
    "Про %@": "About %@",
    "Сховати %@": "Hide %@",
    "Сховати інші": "Hide Others",
    "Завершити %@": "Quit %@",
    "Перевірити оновлення…": "Check for Updates…",
    "Файл": "File",
    "Відкрити…": "Open…",
    "Закрити вікно": "Close Window",
    "Правка": "Edit",
    "Відновити видалене фото": "Restore Deleted Photo",
    "Перемістити в Кошик (Delete)": "Move to Trash (Delete)",
    "Вигляд": "View",
    "Закріпити інформаційну панель (I)": "Pin Info Panel (I)",
    "Обʼєднувати пари RAW+JPEG": "Group RAW+JPEG Pairs",
    "Пара": "Pair",
    "Порівняння: авто (%@)": "Compare: auto (%@)",
    "одне над одним": "one above the other",
    "поруч": "side by side",
    "Порівняння: поруч": "Compare: side by side",
    "Порівняння: одне над одним": "Compare: one above the other",
    "Розкладка порівняння (\\): %@": "Compare Layout (\\): %@",
    "Закрити порівняння (Esc)": "Close Comparison (Esc)",
    "Поруч": "Side by Side",
    "Одне над одним": "One Above the Other",
    "Розкладка порівняння (\\)": "Compare Layout (\\)",
    "Скасувати видалення або переміщення": "Undo Delete or Move",
    "Відсортовано": "Sorted",
    "Переміщено в «%@»": "Moved to “%@”",
    "Скопійовано в «%@»": "Copied to “%@”",
    "Не вдалося перенести «%@»": "Could not transfer “%@”",
    "Читання оцінок…": "Reading ratings…",
    "%@ і вище": "%@ and above",
    "Мітка: %@": "Label: %@",
    "Перемістити": "Move",
    "Скопіювати": "Copy",
    "Куди: %@": "To: %@",
    "Перемістити позначені фото": "Move Marked Photos",
    "Підходить: %d фото (%d файлів)": "Matching: %d photos (%d files)",
    "Які фото:": "Photos:",
    "Дія:": "Action:",
    "Переміщення…": "Moving…",
    "Переміщено %d фото в «%@»": "Moved %d photos to “%@”",
    "Скопійовано %d фото в «%@»": "Copied %d photos to “%@”",
    "Папка для відсортованих фото": "Folder for Sorted Photos",
    "підпапка «%@» у папці з фото": "the “%@” subfolder in the photo’s folder",
    "Зараз: %@": "Now: %@",
    "Обрати папку…": "Choose Folder…",
    "Підпапка «%@»": "“%@” Subfolder",
    "Обрати": "Choose",
    "Куди переносити фото клавішами M і C": "Where M and C send photos",
    "Перемістити в «%@» (M)": "Move to “%@” (M)",
    "Скопіювати в «%@» (C)": "Copy to “%@” (C)",
    "Перемістити позначені…": "Move Marked…",
    "Перемістити у відсортовані (M)": "Move to Sorted (M)",
    "Скопіювати у відсортовані (C)": "Copy to Sorted (C)",
    "Папка для відсортованих…": "Folder for Sorted…",
    "Червона": "Red",
    "Жовта": "Yellow",
    "Зелена": "Green",
    "Синя": "Blue",
    "Оцінка і мітка": "Rating and Label",
    "Не вдалося зберегти оцінку": "Could not save the rating",
    "Не вдалося прочитати «%@»": "Could not read “%@”",
    "Не вдалося записати «%@»": "Could not write “%@”",
    "Вписати у вікно (0)": "Fit to Window (0)",
    "Реальний розмір 100% (Z)": "Actual Size 100% (Z)",
    "Збільшити (+)": "Zoom In (+)",
    "Зменшити (−)": "Zoom Out (−)",
    "Повний екран (F / Enter)": "Full Screen (F / Enter)",
    "Перехід": "Go",
    "Наступне (→ / Пробіл)": "Next (→ / Space)",
    "Попереднє (←)": "Previous (←)",
    "Перше (Home)": "First (Home)",
    "Останнє (End)": "Last (End)",
    "Вікно": "Window",
    "Згорнути": "Minimize",
    "Мова / Language": "Language / Мова",
    "Як у системі": "System Default",
    "Оберіть зображення або папку": "Choose an image or a folder",

    // RAW
    "Проявити RAW / вбудований JPEG (A)": "Develop RAW / Embedded JPEG (A)",
    "RAW проявлено за %d мс · %d×%d": "RAW developed in %d ms · %d×%d",
    "Проявка RAW…": "Developing RAW…",
    "Вбудований JPEG камери %d×%d": "Camera’s embedded JPEG %d×%d",
    "Не вдалося проявити RAW": "Couldn’t develop RAW",

    // Поворот, Finder, інша програма
    "Показати у Finder": "Show in Finder",
    "Копіювати файл": "Copy File",
    "Копіювати як картинку": "Copy as Image",
    "Файл скопійовано": "File copied",
    "Копіювання…": "Copying…",
    "Скопійовано": "Copied",
    "Не вдалося скопіювати": "Couldn’t copy",
    "Відкрити в іншій програмі (E)": "Open in Another App (E)",
    "Відкрити в %@ (E)": "Open in %@ (E)",
    "Обрати програму для E…": "Choose App for E…",
    "Оберіть програму, в якій відкривати фото клавішею E": "Choose the app to open photos in with the E key",
    "Повернути ліворуч (L)": "Rotate Left (L)",
    "Повернути праворуч (R)": "Rotate Right (R)",

    // Типова програма
    "Зробити типовою для фото…": "Make Default for Photos…",
    "Зробити %@ типовою програмою для фото?": "Make %@ the default app for photos?",
    "Оберіть, які файли відкривати подвійним кліком у %@. Змінити вибір можна будь-коли в меню %@.": "Choose which files open in %@ when you double-click them. You can change this any time from the %@ menu.",
    "Звичайні фото (JPEG, HEIC, PNG, TIFF, WebP…)": "Regular photos (JPEG, HEIC, PNG, TIFF, WebP…)",
    "RAW (CR3, CR2, NEF, ARW, DNG, RAF…)": "RAW (CR3, CR2, NEF, ARW, DNG, RAF…)",
    "вже типова": "already default",
    "Зробити типовою": "Make Default",
    "Не зараз": "Not Now",
    "звичайних фото": "regular photos",
    " і ": " and ",
    "Готово": "Done",
    "%@ тепер відкриває %@ подвійним кліком.": "%@ now opens %@ when you double-click them.",
    "Не для всіх форматів вдалося": "Some formats couldn’t be changed",
    "Не змінено для: %@": "Not changed for: %@",

    // Оновлення
    "Доступна нова версія %@ %@": "A new version of %@ is available: %@",
    "У вас версія %@.": "You have version %@.",
    "Встановити і перезапустити": "Install and Relaunch",
    "Сторінка релізу": "Release Page",
    "Пізніше": "Later",
    "У вас найновіша версія": "You’re up to date",
    "Не вдалося оновити програму": "Couldn’t update the app",
    "В архіві оновлення немає програми %@": "The update archive doesn’t contain %@",

    // Вікно і підказки
    "Відкрийте зображення (⌘O) або перетягніть його сюди": "Open an image (⌘O) or drag it here",
    "У папці «%@» немає зображень": "No images in folder “%@”",
    "Не вдалося відкрити «%@»": "Couldn’t open “%@”",
    "У папці більше немає зображень": "No more images in this folder",
    "Не вдалося перемістити «%@» у Кошик": "Couldn’t move “%@” to the Trash",
    "Не вдалося відновити «%@»": "Couldn’t restore “%@”",
    "Перемістити фото в Кошик?": "Move photo to Trash?",
    "«%@» буде переміщено в Кошик, а не видалено назавжди. Повернути фото можна з Кошика або клавішами ⌘Z, поки програма відкрита.": "“%@” will be moved to the Trash, not deleted permanently. You can restore it from the Trash, or press ⌘Z while the app is open.",
    "Перемістити в Кошик": "Move to Trash",
    "Скасувати": "Cancel",
    "Більше не показувати": "Don’t show again",
    "З кешу (декодовано за %d мс)": "From cache (decoded in %d ms)",
    "Декодовано за %d мс · прев'ю %d×%d": "Decoded in %d ms · preview %d×%d",
    "Вписано · %d%%": "Fit · %d%%",
    "Не вдалося завантажити оригінал": "Couldn’t load the original",
    "Оригінал %d×%d": "Original %d×%d",
    "Немає зображення": "No image",

    // Розділи панелі
    "Зображення": "Image",
    "Камера": "Camera",
    "Зйомка": "Exposure",
    "GPS": "GPS",

    // Поля
    "Ім'я": "Name",
    "Папка": "Folder",
    "Розмір": "File size",
    "Змінено": "Modified",
    "Створено": "Created",
    "Розміри": "Dimensions",
    "Формат": "Format",
    "Глибина": "Bit depth",
    "Колір": "Color model",
    "Профіль": "Profile",
    "DPI": "DPI",
    "Прозорість": "Alpha",
    "Кадрів": "Frames",
    "Модель": "Model",
    "Об'єктив": "Lens",
    "ПЗ": "Software",
    "Дата": "Date taken",
    "Витримка": "Shutter",
    "Діафрагма": "Aperture",
    "ISO": "ISO",
    "Фокусна": "Focal length",
    "Експокорекція": "Exposure comp.",
    "Режим": "Program",
    "Замір": "Metering",
    "Спалах": "Flash",
    "Баланс білого": "White balance",
    "Широта": "Latitude",
    "Довгота": "Longitude",
    "Висота": "Altitude",

    // Значення
    "%d × %d (%@ Мп)": "%d × %d (%@ MP)",
    "%d біт/канал": "%d bits/channel",
    "Так": "Yes",
    "%@ мм": "%@ mm",
    " (%d мм екв.)": " (%d mm equiv.)",
    "%@ с": "%@ s",
    "1/%d с": "1/%d s",
    "%d м": "%d m",
    "Спрацював": "Fired",
    "Без спалаху": "No flash",
    "Авто": "Auto",
    "Ручний": "Manual",
    "Не визначено": "Not defined",
    "Ручний (M)": "Manual (M)",
    "Програмний (P)": "Program (P)",
    "Пріоритет діафрагми (A)": "Aperture priority (A)",
    "Пріоритет витримки (S)": "Shutter priority (S)",
    "Творчий": "Creative",
    "Спорт": "Action",
    "Портрет": "Portrait",
    "Пейзаж": "Landscape",
    "Невідомо": "Unknown",
    "Середній": "Average",
    "Центрозважений": "Center-weighted",
    "Точковий": "Spot",
    "Багатоточковий": "Multi-spot",
    "Матричний": "Evaluative / Matrix",
    "Частковий": "Partial",
    "Інший": "Other",
]
