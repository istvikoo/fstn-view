import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InfoRow: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

struct InfoSection: Identifiable {
    var id: String { title }
    let title: String
    let rows: [InfoRow]
}

/// Дані для бокової панелі. Сирі метадані зберігаються, а текст будується
/// при показі — тому зміна мови одразу оновлює панель.
struct ImageInfo {
    let url: URL
    let pixelSize: CGSize
    let fileSize: Int64?
    private let modified: Date?
    private let created: Date?
    private let typeName: String?
    private let frames: Int
    private let props: [CFString: Any]

    static func make(url: URL, source: CGImageSource, props: [CFString: Any]) -> ImageInfo {
        var w = intValue(props[kCGImagePropertyPixelWidth]) ?? 0
        var h = intValue(props[kCGImagePropertyPixelHeight]) ?? 0
        let orientation = intValue(props[kCGImagePropertyOrientation]) ?? 1
        if (5...8).contains(orientation) { swap(&w, &h) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        return ImageInfo(
            url: url,
            pixelSize: CGSize(width: w, height: h),
            fileSize: values?.fileSize.map { Int64($0) },
            modified: values?.contentModificationDate,
            created: values?.creationDate,
            typeName: CGImageSourceGetType(source).flatMap { UTType($0 as String) }?.localizedDescription,
            frames: CGImageSourceGetCount(source),
            props: props
        )
    }

    var sections: [InfoSection] {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var sections: [InfoSection] = []
        func section(_ title: String, _ pairs: [(String, String?)]) {
            let rows = pairs.compactMap { pair in pair.1.map { InfoRow(label: L(pair.0), value: $0) } }
            if !rows.isEmpty { sections.append(InfoSection(title: L(title), rows: rows)) }
        }

        section("Файл", [
            ("Ім'я", url.lastPathComponent),
            ("Папка", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath),
            ("Розмір", fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }),
            ("Змінено", modified.map { Self.dateOut.string(from: $0) }),
            ("Створено", created.map { Self.dateOut.string(from: $0) }),
        ])

        section("Зображення", [
            ("Розміри", w > 0 ? L("%d × %d (%@ Мп)", w, h, String(format: "%.1f", Double(w * h) / 1_000_000)) : nil),
            ("Формат", typeName ?? url.pathExtension.uppercased()),
            ("Глибина", Self.intValue(props[kCGImagePropertyDepth]).map { L("%d біт/канал", $0) }),
            ("Колір", Self.string(props[kCGImagePropertyColorModel])),
            ("Профіль", Self.string(props[kCGImagePropertyProfileName])),
            ("DPI", Self.doubleValue(props[kCGImagePropertyDPIWidth]).map { "\(Int($0.rounded()))" }),
            ("Прозорість", (props[kCGImagePropertyHasAlpha] as? Bool) == true ? L("Так") : nil),
            ("Кадрів", frames > 1 ? "\(frames)" : nil),
        ])

        let make = Self.string(tiff[kCGImagePropertyTIFFMake])
        let model = Self.string(tiff[kCGImagePropertyTIFFModel])
        var camera: String?
        if let model, let make, !model.lowercased().hasPrefix(make.lowercased().components(separatedBy: " ").first ?? "") {
            camera = "\(make) \(model)"
        } else {
            camera = model ?? make
        }
        section("Камера", [
            ("Модель", camera),
            ("Об'єктив", Self.string(exif[kCGImagePropertyExifLensModel]) ?? Self.string(exifAux[kCGImagePropertyExifAuxLensModel])),
            ("ПЗ", Self.string(tiff[kCGImagePropertyTIFFSoftware])),
        ])

        let taken = Self.string(exif[kCGImagePropertyExifDateTimeOriginal])
        var focal: String?
        if let f = Self.doubleValue(exif[kCGImagePropertyExifFocalLength]) {
            focal = L("%@ мм", Self.trim(f))
            if let eq = Self.doubleValue(exif[kCGImagePropertyExifFocalLenIn35mmFilm]), eq > 0, abs(eq - f) > 0.5 {
                focal! += L(" (%d мм екв.)", Int(eq))
            }
        }
        section("Зйомка", [
            ("Дата", taken.map { Self.exifIn.date(from: $0).map { Self.dateOut.string(from: $0) } ?? $0 }),
            ("Витримка", Self.doubleValue(exif[kCGImagePropertyExifExposureTime]).map(Self.shutter)),
            ("Діафрагма", Self.doubleValue(exif[kCGImagePropertyExifFNumber]).map { "f/\(Self.trim($0))" }),
            ("ISO", Self.iso(exif).map { "\($0)" }),
            ("Фокусна", focal),
            ("Експокорекція", Self.doubleValue(exif[kCGImagePropertyExifExposureBiasValue]).map { $0 == 0 ? "0 EV" : String(format: "%+.1f EV", $0) }),
            ("Режим", Self.intValue(exif[kCGImagePropertyExifExposureProgram]).flatMap { Self.programs[$0] }.map { L($0) }),
            ("Замір", Self.intValue(exif[kCGImagePropertyExifMeteringMode]).flatMap { Self.metering[$0] }.map { L($0) }),
            ("Спалах", Self.intValue(exif[kCGImagePropertyExifFlash]).map { L($0 & 1 == 1 ? "Спрацював" : "Без спалаху") }),
            ("Баланс білого", Self.intValue(exif[kCGImagePropertyExifWhiteBalance]).map { L($0 == 0 ? "Авто" : "Ручний") }),
        ])

        if let lat = Self.doubleValue(gps[kCGImagePropertyGPSLatitude]),
           let lon = Self.doubleValue(gps[kCGImagePropertyGPSLongitude]) {
            let latRef = Self.string(gps[kCGImagePropertyGPSLatitudeRef]) ?? "N"
            let lonRef = Self.string(gps[kCGImagePropertyGPSLongitudeRef]) ?? "E"
            section("GPS", [
                ("Широта", "\(String(format: "%.6f", lat))° \(latRef)"),
                ("Довгота", "\(String(format: "%.6f", lon))° \(lonRef)"),
                ("Висота", Self.doubleValue(gps[kCGImagePropertyGPSAltitude]).map { L("%d м", Int($0.rounded())) }),
            ])
        }

        return sections
    }

    // MARK: - Допоміжне

    private static let programs = [0: "Не визначено", 1: "Ручний (M)", 2: "Програмний (P)", 3: "Пріоритет діафрагми (A)",
                                   4: "Пріоритет витримки (S)", 5: "Творчий", 6: "Спорт", 7: "Портрет", 8: "Пейзаж"]
    private static let metering = [0: "Невідомо", 1: "Середній", 2: "Центрозважений", 3: "Точковий",
                                   4: "Багатоточковий", 5: "Матричний", 6: "Частковий", 255: "Інший"]

    private static let dateOut: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    private static let exifIn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// ISO буває в різних полях: JPG і DNG — ISOSpeedRatings, а Canon CR3 — ISOSpeed / RecommendedExposureIndex.
    private static func iso(_ exif: [CFString: Any]) -> Int? {
        if let value = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue, value > 0 { return value }
        for key in [kCGImagePropertyExifISOSpeed, kCGImagePropertyExifRecommendedExposureIndex,
                    kCGImagePropertyExifStandardOutputSensitivity] {
            if let value = intValue(exif[key]), value > 0 { return value }
        }
        return nil
    }

    private static func intValue(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    private static func doubleValue(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return t.isEmpty ? nil : t
    }

    private static func trim(_ d: Double) -> String {
        let s = String(format: "%.1f", d)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private static func shutter(_ t: Double) -> String {
        if t >= 0.3 { return L("%@ с", trim(t)) }
        return L("1/%d с", Int((1 / t).rounded()))
    }
}
