import AppKit
import Foundation
import UniformTypeIdentifiers

/// UTF-8 文本读盘：工作台编辑器与 Finder 打开的 Markdown 共用。
enum TextFile {
    static let maxBytes: Int64 = 2 * 1024 * 1024

    enum ReadError: Error, Equatable {
        case unreadable
        case tooLarge
        case binaryOrNotUTF8
    }

    static func read(from url: URL, maxBytes: Int64 = maxBytes) throws -> String {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            throw ReadError.unreadable
        }
        guard size <= maxBytes else { throw ReadError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ReadError.binaryOrNotUTF8
        }
        return text
    }
}

/// Finder / `open -a` / Dock 拖放识别的 Markdown 文件。
enum MarkdownFile {
    static let filenameExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn",
    ]

    static let importedTypeIdentifier = "net.daringfireball.markdown"

    static var importedType: UTType {
        UTType(importedAs: importedTypeIdentifier)
    }

    static var contentTypes: [UTType] {
        var types: [UTType] = [importedType]
        if let publicMarkdown = UTType("public.markdown") {
            types.append(publicMarkdown)
        }
        for ext in filenameExtensions.sorted() {
            if let type = UTType(filenameExtension: ext, conformingTo: .plainText),
               type.identifier != UTType.plainText.identifier {
                types.append(type)
            }
        }
        return types
    }

    static func matches(url: URL) -> Bool {
        filenameExtensions.contains(url.pathExtension.lowercased())
    }

    static func matches(path: String) -> Bool {
        matches(url: URL(fileURLWithPath: path))
    }

    static func standardizedPath(from url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// Launch Services 默认打开方式。只动 Markdown UTI，不动 `public.plain-text`。
enum MarkdownDefaultApp {
    static let bundleIdentifier = "ai.aureways.client"

    static var isCurrent: Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: MarkdownFile.importedType) else {
            return false
        }
        return Bundle(url: appURL)?.bundleIdentifier == bundleIdentifier
            || appURL.lastPathComponent == "Aureways.app"
    }

    static func register() async throws {
        let appURL = Bundle.main.bundleURL
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: MarkdownFile.importedType)
        if let publicMarkdown = UTType("public.markdown") {
            try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: publicMarkdown)
        }
    }
}
