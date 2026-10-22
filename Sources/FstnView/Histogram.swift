import CoreGraphics

/// Гістограма RGB і яскравості, значення нормалізовані до 0...1.
struct Histogram {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let luminance: [Float]

    /// Рахує по зменшеній копії (до 256 пікселів по більшій стороні) — це займає частки мілісекунди.
    static func compute(from image: CGImage) -> Histogram? {
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var r = [UInt32](repeating: 0, count: 256)
        var g = r, b = r, l = r
        var i = 0
        let end = pixels.count
        while i < end {
            let R = Int(pixels[i]), G = Int(pixels[i + 1]), B = Int(pixels[i + 2])
            r[R] += 1; g[G] += 1; b[B] += 1
            l[(R * 54 + G * 183 + B * 19) >> 8] += 1
            i += 4
        }

        // Крайні значення (0 і 255) не враховуємо при нормалізації, щоб пересвіт не «сплющував» графік.
        let colorPeak = max(r[1..<255].max() ?? 0, g[1..<255].max() ?? 0, b[1..<255].max() ?? 0)
        let lumaPeak = l[1..<255].max() ?? 0
        func norm(_ a: [UInt32], _ peak: UInt32) -> [Float] {
            let p = Float(max(peak, 1))
            return a.map { min(Float($0) / p, 1) }
        }
        return Histogram(red: norm(r, colorPeak), green: norm(g, colorPeak), blue: norm(b, colorPeak), luminance: norm(l, lumaPeak))
    }
}
