import AppKit
import ImageIO
import QuestmasterCore
import SwiftUI

enum QuestAttachmentMetrics {
    static let side: CGFloat = 65
    static let cornerRadius = FormFieldMetrics.cornerRadius
    static let maxThumbnailPixels = 130
}

/// Small previews of the stored copies. File names stay available through the tooltip and accessibility label.
struct QuestAttachmentThumbnail: View {
    let attachment: QuestAttachment
    var highlighted = false
    var onOpen: () -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(attachment.name)
                        .font(AppFonts.questLogBody.swiftUI)
                        .foregroundStyle(RowLook.pick(highlighted: highlighted, areaFocused: true).text.color.swiftUI)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(Space.row)
                }
            }
            .frame(width: QuestAttachmentMetrics.side - 2 * Token.Size.divider, height: QuestAttachmentMetrics.side - 2 * Token.Size.divider)
            .clipShape(RoundedRectangle(cornerRadius: QuestAttachmentMetrics.cornerRadius))
            .padding(Token.Size.divider)
            .stateRow(.pick(highlighted: highlighted, areaFocused: true).listItem(underPointer: false), cornerRadius: QuestAttachmentMetrics.cornerRadius)
        }
        .buttonStyle(.plain)
        .help("\(attachment.name) (Return opens; d removes)")
        .accessibilityLabel("Open attachment \(attachment.name)")
        .task(id: attachment.path) {
            let loaded = await QuestAttachmentThumbnails.shared.load(path: attachment.path)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }
}

/// Decode one preview at a time, at its display size, rather than materialising full-resolution images on the UI thread.
private actor QuestAttachmentThumbnails {
    static let shared = QuestAttachmentThumbnails()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = NewQuestFormModel.maxAttachments
        cache.totalCostLimit = 2 << 20
        return cache
    }()

    func load(path: String) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: QuestAttachmentMetrics.maxThumbnailPixels,
              ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}
