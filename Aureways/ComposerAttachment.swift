import AppKit
import UniformTypeIdentifiers

// 单张图片内联 base64 的体积上限：NDJSON 单行过大易撑爆连接层，超限降级为 resource_link。
let maxInlineImageBytes = 10 * 1024 * 1024
// 内嵌文件正文上限。超过则只发 resource_link，由 Agent 自己读。
let maxEmbeddedTextBytes = 256 * 1024

/// 用户气泡图片只解码一次，按附件 id 缓存。滚动复用时禁止在 onAppear 里再跑 base64。
enum TranscriptImageStore {
    /// Swift 6 不允许裸的 static 可变状态。NSCache 自身线程安全，decoding 由 lock 串行化，
    /// 两者一起收进这个盒子，unsafe 只留在这一处。
    private final class Store: @unchecked Sendable {
        private let cache = NSCache<NSString, NSImage>()
        private let lock = NSLock()
        private var decoding = Set<String>()

        func image(forKey key: String) -> NSImage? {
            cache.object(forKey: key as NSString)
        }

        func remember(_ image: NSImage, forKey key: String) {
            cache.setObject(image, forKey: key as NSString)
        }

        /// true 表示本次抢到解码权；false 表示已有调用方在解同一张图。
        func beginDecoding(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return decoding.insert(key).inserted
        }

        func endDecoding(_ key: String) {
            lock.lock()
            decoding.remove(key)
            lock.unlock()
        }
    }

    private static let store = Store()

    static func cached(_ attachment: TranscriptAttachment) -> NSImage? {
        store.image(forKey: attachment.id.uuidString)
    }

    static func remember(_ image: NSImage, for attachment: TranscriptAttachment) {
        store.remember(image, forKey: attachment.id.uuidString)
    }

    /// 在附件创建时调用。已有 NSImage / 文件路径则立刻入缓存；只有 base64 时同步解一次。
    @discardableResult
    static func prefetch(_ attachment: TranscriptAttachment, image: NSImage? = nil) -> NSImage? {
        if let image {
            remember(image, for: attachment)
            return image
        }
        if let existing = cached(attachment) {
            return existing
        }
        if let path = attachment.path, attachment.kind == "image" {
            let filePath = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
            if let loaded = NSImage(contentsOfFile: filePath) {
                remember(loaded, for: attachment)
                return loaded
            }
        }
        guard attachment.kind == "image", let base64 = attachment.imageBase64, !base64.isEmpty else {
            return nil
        }
        let key = attachment.id.uuidString
        guard store.beginDecoding(key) else { return cached(attachment) }
        let decoded = decodeBase64Image(base64)
        store.endDecoding(key)
        if let decoded {
            remember(decoded, for: attachment)
        }
        return decoded
    }

    private static func decodeBase64Image(_ base64: String) -> NSImage? {
        let clean = base64.contains(";base64,") ? String(base64.split(separator: ";base64,").last ?? "") : base64
        let stripped = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: stripped, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}

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

extension TranscriptAttachment {
    init?(contentBlock: ContentBlock) {
        switch contentBlock {
        case .image(let data, let mimeType, let uri):
            let path = uri.flatMap { (u: String) -> String? in
                if u.hasPrefix("file://"), let url = URL(string: u) {
                    return url.path
                } else if u.hasPrefix("/") {
                    return u
                }
                return nil
            }
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? uri.flatMap { URL(string: $0)?.lastPathComponent }
                ?? "图片"
            var base64: String? = data.isEmpty ? nil : data
            if base64 == nil, let path, let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)), fileData.count <= maxInlineImageBytes {
                base64 = fileData.base64EncodedString()
            }
            let attachment = TranscriptAttachment(
                id: UUID(),
                kind: "image",
                name: name,
                path: path,
                mimeType: mimeType.isEmpty ? "image/png" : mimeType,
                imageBase64: base64
            )
            TranscriptImageStore.prefetch(attachment)
            self = attachment
            return
        case .resourceLink(let uri, let name):
            let path = uri.hasPrefix("file://") ? URL(string: uri)?.path : (uri.hasPrefix("/") ? uri : nil)
            let ext = URL(fileURLWithPath: path ?? uri).pathExtension.lowercased()
            let isImg = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(ext)
            var base64: String? = nil
            if isImg, let path, let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)), fileData.count <= maxInlineImageBytes {
                base64 = fileData.base64EncodedString()
            }
            let attachment = TranscriptAttachment(
                id: UUID(),
                kind: isImg ? "image" : "file",
                name: name.isEmpty ? (path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "附件") : name,
                path: path,
                mimeType: isImg ? (UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png") : nil,
                imageBase64: base64
            )
            if isImg { TranscriptImageStore.prefetch(attachment) }
            self = attachment
            return
        case .audio:
            return nil
        case .resource(let uri, let mimeType, _, let blob):
            let path = uri.hasPrefix("file://") ? URL(string: uri)?.path : (uri.hasPrefix("/") ? uri : nil)
            let isImg = (mimeType ?? "").hasPrefix("image/")
            let attachment = TranscriptAttachment(
                id: UUID(),
                kind: isImg ? "image" : "file",
                name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "附件",
                path: path,
                mimeType: mimeType,
                imageBase64: isImg ? blob : nil
            )
            if isImg { TranscriptImageStore.prefetch(attachment) }
            self = attachment
            return
        case .other(let json):
            if json["type"]?.stringValue == "image" || json["mimeType"]?.stringValue?.hasPrefix("image/") == true {
                let data = json["data"]?.stringValue ?? json["source"]?["data"]?.stringValue
                let uri = json["uri"]?.stringValue ?? json["url"]?.stringValue
                let path = uri.flatMap { (u: String) -> String? in
                    if u.hasPrefix("file://"), let url = URL(string: u) {
                        return url.path
                    } else if u.hasPrefix("/") {
                        return u
                    }
                    return nil
                }
                let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "图片"
                let attachment = TranscriptAttachment(
                    id: UUID(),
                    kind: "image",
                    name: name,
                    path: path,
                    mimeType: json["mimeType"]?.stringValue ?? "image/png",
                    imageBase64: data
                )
                TranscriptImageStore.prefetch(attachment)
                self = attachment
                return
            } else {
                return nil
            }
        case .text:
            return nil
        }
    }
}

struct OutgoingMessage: Equatable, Sendable {
    var text: String
    var attachments: [TranscriptAttachment] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    func contentBlocks(promptCapabilities: PromptCapabilities? = nil) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(.text(trimmed))
        }
        let allowImage = promptCapabilities?.allowsImage ?? true
        let allowEmbedded = promptCapabilities?.allowsEmbeddedContext ?? true
        for attachment in attachments {
            switch attachment.kind {
            case "image":
                blocks.append(contentsOf: Self.imageBlocks(attachment, allowImage: allowImage))
            default:
                if let path = attachment.path {
                    blocks.append(Self.fileBlock(path: path, name: attachment.name, mimeType: attachment.mimeType, allowEmbedded: allowEmbedded))
                }
            }
        }
        return blocks
    }

    private static func imageBlocks(_ attachment: TranscriptAttachment, allowImage: Bool) -> [ContentBlock] {
        let uri = attachment.path.map(fileURI)
        if allowImage, let base64 = attachment.imageBase64, inlineImageFits(base64) {
            return [.image(data: base64, mimeType: attachment.mimeType ?? "image/png", uri: uri)]
        }
        if let path = attachment.path {
            return [.resourceLink(uri: fileURI(path), name: attachment.name)]
        }
        if allowImage, let base64 = attachment.imageBase64 {
            return [.image(data: base64, mimeType: attachment.mimeType ?? "image/png", uri: uri)]
        }
        return []
    }

    private static func fileBlock(path: String, name: String, mimeType: String?, allowEmbedded: Bool) -> ContentBlock {
        let uri = fileURI(path)
        if allowEmbedded, let embedded = embedTextFile(path: path, mimeType: mimeType) {
            return .resource(uri: uri, mimeType: embedded.mime, text: embedded.text, blob: nil)
        }
        return .resourceLink(uri: uri, name: name)
    }

    private static func inlineImageFits(_ base64: String) -> Bool {
        let padding = base64.filter { $0 == "=" }.count
        let bytes = max(0, base64.count * 3 / 4 - padding)
        return bytes <= maxInlineImageBytes
    }

    private static func embedTextFile(path: String, mimeType: String?) -> (text: String, mime: String)? {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= maxEmbeddedTextBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let mime = mimeType.flatMap { $0.hasPrefix("text/") || $0.contains("json") || $0.contains("xml") ? $0 : nil }
            ?? mimeTypeForTextFile(url)
        return (text, mime)
    }

    private static func mimeTypeForTextFile(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "ts", "tsx", "jsx": return "text/plain"
        case "py", "rb", "go", "rs", "swift", "c", "h", "cc", "cpp", "java", "kt", "sh": return "text/plain"
        case "yml", "yaml": return "text/yaml"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        default: return "text/plain"
        }
    }
}

func fileURI(_ path: String) -> String {
    URL(fileURLWithPath: path).absoluteString
}

extension ComposerAttachment {
    var transcriptAttachment: TranscriptAttachment {
        let attachment = TranscriptAttachment(
            id: id,
            kind: kind == .image ? "image" : "file",
            name: name,
            path: url?.path,
            mimeType: mimeType,
            imageBase64: imageData?.base64EncodedString()
        )
        if kind == .image {
            TranscriptImageStore.prefetch(attachment, image: thumbnail ?? imageData.flatMap(NSImage.init(data:)))
        }
        return attachment
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
