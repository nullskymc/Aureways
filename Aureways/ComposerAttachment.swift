import AppKit
import UniformTypeIdentifiers

// 单张图片内联 base64 的体积上限：NDJSON 单行过大易撑爆连接层，超限降级为 resource_link。
let maxInlineImageBytes = 10 * 1024 * 1024

struct ComposerAttachment: Identifiable {
    enum Kind { case image, file }

    let id = UUID()
    var kind: Kind
    var name: String
    var url: URL?
    var mimeType: String
    var imageData: Data?
    var thumbnail: NSImage?
}

struct TranscriptAttachment: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var kind: String
    var name: String
    var path: String?
    var mimeType: String?
    var imageBase64: String?
}

struct OutgoingMessage: Equatable, Sendable {
    var text: String
    var attachments: [TranscriptAttachment] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    func contentBlocks() -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(.text(trimmed))
        }
        for attachment in attachments {
            switch attachment.kind {
            case "image":
                if let base64 = attachment.imageBase64 {
                    blocks.append(.image(
                        data: base64,
                        mimeType: attachment.mimeType ?? "image/png",
                        uri: attachment.path.map(fileURI)
                    ))
                } else if let path = attachment.path {
                    blocks.append(.resourceLink(uri: fileURI(path), name: attachment.name))
                }
            default:
                if let path = attachment.path {
                    blocks.append(.resourceLink(uri: fileURI(path), name: attachment.name))
                }
            }
        }
        return blocks
    }
}

func fileURI(_ path: String) -> String {
    URL(fileURLWithPath: path).absoluteString
}

extension ComposerAttachment {
    var transcriptAttachment: TranscriptAttachment {
        TranscriptAttachment(
            id: id,
            kind: kind == .image ? "image" : "file",
            name: name,
            path: url?.path,
            mimeType: mimeType,
            imageBase64: imageData?.base64EncodedString()
        )
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard) -> [ComposerAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap(fromFileURL)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return [imageAttachment(from: image, name: "图片")].compactMap { $0 }
        }
        return []
    }

    static func fromFileURLs(_ urls: [URL]) -> [ComposerAttachment] {
        urls.compactMap(fromFileURL)
    }

    private static func fromFileURL(_ url: URL) -> ComposerAttachment? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image),
           let data = try? Data(contentsOf: url), data.count <= maxInlineImageBytes,
           let image = NSImage(data: data) {
            return ComposerAttachment(
                kind: .image,
                name: url.lastPathComponent,
                url: url,
                mimeType: type.preferredMIMEType ?? "image/png",
                imageData: data,
                thumbnail: image
            )
        }
        return ComposerAttachment(
            kind: .file,
            name: url.lastPathComponent,
            url: url,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            imageData: nil,
            thumbnail: nil
        )
    }

    private static func imageAttachment(from image: NSImage, name: String) -> ComposerAttachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var data = rep.representation(using: .png, properties: [:])
        var mimeType = "image/png"
        if let png = data, png.count > maxInlineImageBytes, !rep.hasAlpha,
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mimeType = "image/jpeg"
        }
        guard let data, data.count <= maxInlineImageBytes else { return nil }
        return ComposerAttachment(
            kind: .image,
            name: name,
            url: nil,
            mimeType: mimeType,
            imageData: data,
            thumbnail: image
        )
    }
}
