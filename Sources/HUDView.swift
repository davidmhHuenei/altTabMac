import SwiftUI

final class HUDState: ObservableObject {
    @Published var selectedIndex = 0
    var windowCount = 0
}

struct HUDView: View {
    let windows: [WindowManager.WindowInfo]
    let windowManager: WindowManager
    @ObservedObject var state: HUDState

    @State private var thumbnails: [CGWindowID: NSImage] = [:]
    @State private var didLoadThumbnails = false

    private let maxThumbnailDimension: CGFloat = 300
    private let maxVisibleCount = 5
    private let fixedCardSize = CGSize(width: 530, height: 300)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VisualEffectView(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .opacity(0.35)

                carouselContent(in: geometry.size)
            }
            .padding(0)
            .onAppear {
                guard !didLoadThumbnails else { return }
                didLoadThumbnails = true
                loadThumbnails()
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.selectedIndex)
        }
    }

    @ViewBuilder
    private func carouselContent(in size: CGSize) -> some View {
        let items = visibleItems

        if items.isEmpty {
            VStack(spacing: 12) {
                Text("No windows")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Press Option+Tab to start switching")
                    .font(.subheadline)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack {
                Spacer(minLength: 0)

                ZStack {
                    ForEach(items) { item in
                        ThumbnailCard(
                            window: item.window,
                            thumbnail: thumbnails[item.window.id],
                            isFocused: item.offset == 0,
                            cardSize: fixedCardSize
                        )
                        .frame(width: fixedCardSize.width, height: fixedCardSize.height)
                        .offset(cardOffset(for: item.offset, in: size))
                        .opacity(cardOpacity(for: item.offset))
                        .scaleEffect(cardScale(for: item.offset))
                        .zIndex(cardZIndex(for: item.offset))
                        .onTapGesture {
                            state.selectedIndex = item.index
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadThumbnails() {
        Task {
            for window in windows {
                let image = await windowManager.captureThumbnail(
                    for: window,
                    targetSize: thumbnailTargetSize(for: window.frame.size)
                )
                if let image {
                    await MainActor.run {
                        thumbnails[window.id] = image
                    }
                }
            }
        }
    }

    private var visibleItems: [CarouselItem] {
        guard !windows.isEmpty else { return [] }

        let count = min(maxVisibleCount, windows.count)
        let offsets = Array([0, -1, 1, -2, 2].prefix(count))

        return offsets.map { offset in
            let index = wrappedIndex(state.selectedIndex + offset, count: windows.count)
            let window = windows[index]
            return CarouselItem(index: index, offset: offset, window: window)
        }
    }

    private func thumbnailTargetSize(for windowSize: CGSize) -> CGSize {
        guard windowSize.width > 0, windowSize.height > 0 else {
            return CGSize(width: maxThumbnailDimension, height: maxThumbnailDimension)
        }

        let longestEdge = max(windowSize.width, windowSize.height)
        let scale = maxThumbnailDimension / longestEdge
        return CGSize(width: windowSize.width * scale, height: windowSize.height * scale)
    }

    private func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let value = index % count
        return value >= 0 ? value : value + count
    }

    private func cardOffset(for offset: Int, in size: CGSize) -> CGSize {
        let centeredWidth = min(size.width * 0.58, 600)
        let xStep = centeredWidth * 0.35
        let yStep = min(size.height * 0.035, 0)

        switch offset {
        case 0:
            return .zero
        case 1:
            return CGSize(width: xStep, height: yStep)
        case -1:
            return CGSize(width: -xStep, height: yStep)
        case 2:
            return CGSize(width: xStep * 2, height: yStep * 2)
        case -2:
            return CGSize(width: -xStep * 2, height: yStep * 2)
        default:
            return .zero
        }
    }

    private func cardScale(for offset: Int) -> CGFloat {
        switch offset {
        case 0:
            return 1.0
        case -1, 1:
            return 0.75
        default:
            return 0.68
        }
    }

    private func cardOpacity(for offset: Int) -> Double {
        switch offset {
        case 0:
            return 1.0
        case -1, 1:
            return 0.75
        default:
            return 0.3
        }
    }

    private func cardZIndex(for offset: Int) -> Double {
        switch offset {
        case 0:
            return 10
        case -1, 1:
            return 8
        default:
            return 2
        }
    }

}

// MARK: - Thumbnail Card

private struct ThumbnailCard: View {
    let window: WindowManager.WindowInfo
    let thumbnail: NSImage?
    let isFocused: Bool
    let cardSize: CGSize

    var body: some View {
        let labelAreaHeight: CGFloat = 34
        let previewAreaHeight = max(0, cardSize.height - labelAreaHeight)

        VStack(spacing: 0) {
            previewFrame
                .frame(width: cardSize.width, height: previewAreaHeight, alignment: .center)

            HStack(spacing: 7) {
                if let icon = NSRunningApplication(processIdentifier: window.appPID)?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: isFocused ? 16 : 14, height: isFocused ? 16 : 14)
                }

                Text(window.title ?? window.appName)
                    .lineLimit(1)
                    .font(isFocused ? .subheadline.weight(.semibold) : .caption)
                    .foregroundStyle(isFocused ? .primary : .secondary)
            }
            .frame(width: cardSize.width, height: labelAreaHeight, alignment: .center)
            .padding(.horizontal, 4)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }

    @ViewBuilder
    private var previewFrame: some View {
        let cardRadius = 14.0
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(Color.black.opacity(0.75))

            if let thumbnail {
                AspectFitImageView(image: thumbnail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .stroke(isFocused ? Color.black.opacity(0.75) : Color.black.opacity(0.22), lineWidth: isFocused ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(isFocused ? 0.12 : 0.06), radius: isFocused ? cardRadius : 8, x: 0, y: 8)
    }

}

private struct AspectFitImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> AspectFitImageContainer {
        AspectFitImageContainer()
    }

    func updateNSView(_ nsView: AspectFitImageContainer, context: Context) {
        nsView.image = image
        nsView.needsDisplay = true
    }
}

private final class AspectFitImageContainer: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let image else { return }
        let sourceSize = image.size
        let targetSize = bounds.size
        guard sourceSize.width > 0, sourceSize.height > 0, targetSize.width > 0, targetSize.height > 0 else { return }

        let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect, from: NSRect(origin: .zero, size: sourceSize), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private struct CarouselItem: Identifiable {
    let index: Int
    let offset: Int
    let window: WindowManager.WindowInfo

    var id: CGWindowID { window.id }
}

// MARK: - VisualEffectView

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = material
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
