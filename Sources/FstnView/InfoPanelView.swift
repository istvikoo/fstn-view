import SwiftUI
import AppKit

final class ViewerState: ObservableObject {
    @Published var fileName = ""
    @Published var position = ""
    @Published var zoomText = ""
    @Published var decodeText = ""
    @Published var info: ImageInfo?
    @Published var histogram: Histogram?
    /// Кнопку «Копіювати всі дані» щойно натиснули — на мить показуємо галочку.
    @Published var infoCopied = false
}

/// Інформаційна бокова панель: гістограма + EXIF, як у FastStone.
struct InfoPanelView: View {
    @ObservedObject var state: ViewerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.fileName.isEmpty ? L("Немає зображення") : state.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let info = state.info {
                        CopyInfoButton(state: state, info: info)
                    }
                }
                HStack {
                    Text(state.position)
                    Spacer()
                    Text(state.zoomText)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let histogram = state.histogram {
                        HistogramView(histogram: histogram)
                            .frame(height: 100)
                    }
                    if let info = state.info {
                        ForEach(info.sections) { section in
                            InfoSectionView(section: section)
                        }
                    }
                    if !state.decodeText.isEmpty {
                        Text(state.decodeText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Маленька кнопка «скопіювати всі дані»: після натискання на мить показує галочку.
private struct CopyInfoButton: View {
    @ObservedObject var state: ViewerState
    /// Текст складається лише при натисканні, а не при кожному оновленні панелі.
    let info: ImageInfo
    private var copied: Bool { state.infoCopied }

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(info.plainText, forType: .string)
            state.infoCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [state] in state.infoCopied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? .green : .secondary)
        .help(L("Копіювати всі дані"))
    }
}

private struct InfoSectionView: View {
    let section: InfoSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11))
            }
        }
    }
}

private struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { ctx, size in
            func area(_ bins: [Float]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<bins.count {
                    let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
                    let y = size.height - CGFloat(bins[i]) * (size.height - 2)
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(area(histogram.luminance), with: .color(.white.opacity(0.18)))
            ctx.blendMode = .plusLighter
            ctx.fill(area(histogram.red), with: .color(.red.opacity(0.5)))
            ctx.fill(area(histogram.green), with: .color(.green.opacity(0.5)))
            ctx.fill(area(histogram.blue), with: .color(.blue.opacity(0.6)))
        }
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
