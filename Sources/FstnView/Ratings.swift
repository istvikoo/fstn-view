import AppKit
import ImageIO

/// Кольорова мітка, як у Lightroom (клавіші 6–9). Назви в XMP — англійські, їх читають
/// Lightroom, Bridge і Capture One.
enum ColorLabel: String, CaseIterable {
    case red = "Red", yellow = "Yellow", green = "Green", blue = "Blue"

    var title: String {
        switch self {
        case .red: return L("Червона")
        case .yellow: return L("Жовта")
        case .green: return L("Зелена")
        case .blue: return L("Синя")
        }
    }

    var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
        case .green: return NSColor(srgbRed: 0.2, green: 0.85, blue: 0.3, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.25, green: 0.55, blue: 1, alpha: 1)
        }
    }
}

/// Оцінка (0–5 зірок) і кольорова мітка фото.
struct PhotoMark: Equatable {
    var rating = 0
    var label: ColorLabel?

    var stars: String { rating > 0 ? String(repeating: "★", count: rating) : "" }
}

/// Читання і запис оцінок у XMP, щоб їх бачили Lightroom, Bridge і Capture One:
/// - RAW — у файл-супутник `IMG_0001.xmp` поруч (наявний файл Lightroom лише доповнюється);
/// - JPEG, PNG, TIFF, HEIC — у сам файл, без перекодування зображення
///   (Lightroom для таких файлів .xmp-супутник не читає).
enum Ratings {
    enum Failure: LocalizedError {
        case unreadable(URL), unwritable(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let u): return L("Не вдалося прочитати «%@»", u.lastPathComponent)
            case .unwritable(let u): return L("Не вдалося записати «%@»", u.lastPathComponent)
            }
        }
    }

    static func sidecar(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Читання

    /// Оцінка фото. Для RAW (і JPEG, у якого є RAW-пара) головний — .xmp-супутник,
    /// інакше — те, що записано в самому файлі (зокрема оцінка, поставлена в камері).
    static func read(_ url: URL) -> PhotoMark {
        let side = sidecar(for: url)
        if let data = try? Data(contentsOf: side), let meta = CGImageMetadataCreateFromXMPData(data as CFData) {
            return mark(from: meta)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return PhotoMark() }
        return mark(from: meta)
    }

    private static func mark(from meta: CGImageMetadata) -> PhotoMark {
        func value(_ path: String) -> String? {
            CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
        }
        let rating = value("xmp:Rating").flatMap { Int($0) }.map { min(max($0, 0), 5) } ?? 0
        let label = value("xmp:Label").flatMap { name in
            ColorLabel.allCases.first { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }
        }
        return PhotoMark(rating: rating, label: label)
    }

    // MARK: - Запис

    /// Записує оцінку в усі файли кадру (напр. IMG_0001.CR3 + IMG_0001.JPG).
    static func write(_ mark: PhotoMark, to files: [URL]) throws {
        var sidecarDone = Set<URL>()
        for url in files {
            let side = sidecar(for: url)
            // RAW — завжди супутник. Якщо поряд уже є .xmp (від RAW-пари) — оновлюємо і його.
            if ImageLoader.isRaw(url) || FileManager.default.fileExists(atPath: side.path) {
                if sidecarDone.insert(side).inserted { try writeSidecar(mark, to: side) }
                if ImageLoader.isRaw(url) { continue }
            }
            if !(try writeEmbedded(mark, to: url)), sidecarDone.insert(side).inserted {
                // Формат, у який ImageIO не вміє писати без перекодування, — тоді супутник
                try writeSidecar(mark, to: side)
            }
        }
    }

    // MARK: Файл-супутник .xmp

    private static let xmpNS = "http://ns.adobe.com/xap/1.0/"

    private static func writeSidecar(_ mark: PhotoMark, to url: URL) throws {
        var text: String
        if let data = try? Data(contentsOf: url) {
            // Наявний файл (напр. від Lightroom з налаштуваннями проявки) — міняємо лише
            // xmp:Rating і xmp:Label, решту лишаємо як є.
            guard let existing = String(data: data, encoding: .utf8) else { throw Failure.unreadable(url) }
            text = existing
        } else {
            text = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="fstn view">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="\(xmpNS)"/>
             </rdf:RDF>
            </x:xmpmeta>

            """
        }
        text = setProperty("Rating", mark.rating > 0 ? String(mark.rating) : nil, in: text)
        text = setProperty("Label", mark.label?.rawValue, in: text)

        // Перевіряємо, що файл лишився правильним XMP і містить саме те, що ми записали
        guard verify(text, has: mark), let data = text.data(using: .utf8) else { throw Failure.unwritable(url) }
        // Наш власний супутник без оцінки і мітки більше не потрібен
        if mark == PhotoMark(), text.contains("x:xmptk=\"fstn view\""),
           CGImageMetadataCreateFromXMPData(data as CFData) == nil {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            return
        }
        do { try data.write(to: url, options: .atomic) } catch { throw Failure.unwritable(url) }
    }

    /// Ставить або прибирає xmp:<name> у тексті XMP (атрибут або елемент).
    private static func setProperty(_ name: String, _ value: String?, in text: String) -> String {
        var text = text
        let attribute = "\\s*xmp:\(name)=\"[^\"]*\""
        let element = "\\s*<xmp:\(name)>[^<]*</xmp:\(name)>"
        let attrNew = value.map { "\n   xmp:\(name)=\"\($0)\"" } ?? ""
        let elemNew = value.map { "\n   <xmp:\(name)>\($0)</xmp:\(name)>" } ?? ""
        if text.range(of: attribute, options: .regularExpression) != nil {
            return text.replacingOccurrences(of: attribute, with: attrNew, options: .regularExpression)
        }
        if text.range(of: element, options: .regularExpression) != nil {
            return text.replacingOccurrences(of: element, with: elemNew, options: .regularExpression)
        }
        guard value != nil, let open = text.range(of: "<rdf:Description") else { return text }
        var insert = attrNew
        if !text.contains("xmlns:xmp=") { insert = "\n   xmlns:xmp=\"\(xmpNS)\"" + insert }
        text.insert(contentsOf: insert, at: open.upperBound)
        return text
    }

    // MARK: Усередині JPEG

    private static let xmpHeader = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]

    /// Міняє лише блок XMP усередині JPEG, решта файлу (EXIF з даними камери, MPF, саме зображення)
    /// лишається байт у байт. false — це не JPEG, тоді пишемо .xmp-супутник.
    private static func writeEmbedded(_ mark: PhotoMark, to url: URL) throws -> Bool {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }

        // Сегменти до початку зображення (SOS)
        var i = 2
        var xmpRange: Range<Int>?          // увесь сегмент APP1 з XMP
        var insertAt = 2                   // куди вставити новий XMP: після APP0 / EXIF
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let end = i + 2 + length
            guard length >= 2, end <= bytes.count else { throw Failure.unreadable(url) }
            if marker == 0xE1, Array(bytes[(i + 4)..<min(end, i + 4 + xmpHeader.count)]) == xmpHeader {
                xmpRange = i..<end
            }
            if marker == 0xE0 || (marker == 0xE1 && xmpRange?.lowerBound != i) { insertAt = end }
            i = end
        }

        var packet: String
        if let r = xmpRange {
            let body = Data(bytes[(r.lowerBound + 4 + xmpHeader.count)..<r.upperBound])
            guard let text = String(data: body, encoding: .utf8) else { throw Failure.unreadable(url) }
            packet = text
        } else {
            guard mark != PhotoMark() else { return true }      // нічого прибирати
            packet = emptyPacket
        }
        packet = setProperty("Rating", mark.rating > 0 ? String(mark.rating) : nil, in: packet)
        packet = setProperty("Label", mark.label?.rawValue, in: packet)
        guard verify(packet, has: mark) else { throw Failure.unwritable(url) }

        let payload = xmpHeader + Array(packet.utf8)
        guard payload.count + 2 <= 0xFFFF else { throw Failure.unwritable(url) }
        let segment: [UInt8] = [0xFF, 0xE1, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload
        var out = bytes
        if let r = xmpRange {
            out.replaceSubrange(r, with: segment)
        } else {
            out.insert(contentsOf: segment, at: insertAt)
        }

        // Пишемо в тимчасовий файл поруч, перевіряємо і лише тоді підміняємо оригінал
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).fstn-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: temp) }
        do { try Data(out).write(to: temp) } catch { throw Failure.unwritable(url) }
        guard let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              let original = CGImageSourceCreateWithURL(url as CFURL, nil),
              size(of: check) != nil, size(of: check) == size(of: original) else { throw Failure.unwritable(url) }
        let checkMeta = CGImageSourceCopyMetadataAtIndex(check, 0, nil)
        guard checkMeta.map({ self.mark(from: $0) }) ?? PhotoMark() == mark else { throw Failure.unwritable(url) }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            throw Failure.unwritable(url)
        }
        return true
    }

    private static var emptyPacket: String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="fstn view">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(xmpNS)"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// XMP після правки читається і містить саме цю оцінку. Якщо після видалення оцінки
    /// в описі не лишилось жодної властивості, ImageIO такий XMP не читає — тоді досить,
    /// що тегів оцінки в тексті вже немає.
    private static func verify(_ text: String, has mark: PhotoMark) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        if let meta = CGImageMetadataCreateFromXMPData(data as CFData) { return self.mark(from: meta) == mark }
        return mark == PhotoMark() && !text.contains("xmp:Rating") && !text.contains("xmp:Label")
    }

    private static func size(of source: CGImageSource) -> [Int]? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return [w, h]
    }
}
