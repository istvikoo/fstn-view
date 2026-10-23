import AppKit
import ImageIO
import UniformTypeIdentifiers

/// ⌘C: копіювання фото в буфер обміну, щоб вставити в месенджер чи документ.
enum Clipboard {
    /// Готує JPEG для буфера. Для JPEG-файлу без повороту — оригінальні байти (без втрати якості);
    /// інакше — кодування картинки (проявленого RAW, вбудованого JPEG камери тощо) з якістю 92%.
    static func jpegData(for url: URL, developed: CGImage?, rotation: Int) -> Data? {
        let isJPEGFile = UTType(filenameExtension: url.pathExtension)?.conforms(to: .jpeg) ?? false
        if developed == nil, rotation == 0, isJPEGFile {
            return try? Data(contentsOf: url)
        }
        guard var image = developed ?? ImageLoader.decodeFull(url: url) else { return nil }
        if rotation != 0, let turned = rotated(image, quarterTurns: rotation) { image = turned }
        return encodeJPEG(image)
    }

    /// ⌘C: сам файл, як «Копіювати» у Finder.
    static func write(file url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    static func write(jpeg: Data) {
        let item = NSPasteboardItem()
        item.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        // TIFF/PNG — лише якщо якась програма їх попросить (кодуються на вимогу)
        let provider = LazyImageProvider(jpeg: jpeg)
        item.setDataProvider(provider, forTypes: [.tiff, .png])
        LazyImageProvider.current = provider
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Поворот на 90°·n за годинниковою стрілкою (як клавіші L / R).
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let k = ((quarterTurns % 4) + 4) % 4
        guard k != 0 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = k % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch k {
        case 1: ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)
        case 2: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
        default: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Віддає TIFF/PNG з JPEG лише тоді, коли програма-отримувач їх попросить.
private final class LazyImageProvider: NSObject, NSPasteboardItemDataProvider {
    static var current: LazyImageProvider?
    private let jpeg: Data
    init(jpeg: Data) { self.jpeg = jpeg }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let rep = NSBitmapImageRep(data: jpeg) else { return }
        if type == .png, let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        } else if type == .tiff, let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }
}
