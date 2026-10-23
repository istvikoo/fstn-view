import AppKit

// Режим перевірки без вікна: "fstn view" --info <файл>
// Друкує час декодування і дані для інформаційної панелі.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--bench" {
    // "fstn view" --bench <файли…>: двічі декодує кожен файл (холодний і теплий запуск)
    for path in args.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let maxPixel = ImageLoader.shared.previewMaxPixel
        let times = (0..<2).map { _ in ImageLoader.decodePreview(url: url, maxPixel: maxPixel).map { Int($0.decodeTime * 1000) } ?? -1 }
        let quick = ImageLoader.decodeQuick(url: url, maxPixel: maxPixel)
        let quickText = quick.map { "швидке \($0.image.width)×\($0.image.height) за \(Int($0.decodeTime * 1000)) мс, " } ?? "без швидкого етапу, "
        print("\(url.lastPathComponent): \(quickText)чітке \(times[0]) мс, повторно \(times[1]) мс")
    }
    exit(0)
}
if args.count >= 3, args[1] == "--copy" {
    // "fstn view" --copy <файл> [повороти]: скопіювати фото в буфер так само, як ⌘C
    let url = URL(fileURLWithPath: args[2])
    if args.count >= 4, args[3] == "file" { Clipboard.write(file: url); print("Файл скопійовано"); exit(0) }
    let rotation = args.count >= 4 ? Int(args[3]) ?? 0 : 0
    guard let jpeg = Clipboard.jpegData(for: url, developed: nil, rotation: rotation) else { print("Не вдалося"); exit(1) }
    Clipboard.write(jpeg: jpeg)
    print("Скопійовано \(jpeg.count) байт")
    exit(0)
}
if args.count >= 3, args[1] == "--info" {
    let url = URL(fileURLWithPath: args[2])
    guard let image = ImageLoader.decodePreview(url: url, maxPixel: ImageLoader.shared.previewMaxPixel) else {
        print("Не вдалося відкрити \(url.path)")
        exit(1)
    }
    print("Прев'ю \(image.preview.width)×\(image.preview.height), декодовано за \(Int(image.decodeTime * 1000)) мс")
    for section in image.info.sections {
        print("\n[\(section.title)]")
        for row in section.rows { print("  \(row.label): \(row.value)") }
    }
    print("\nГістограма: \(image.histogram != nil ? "є" : "немає")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
