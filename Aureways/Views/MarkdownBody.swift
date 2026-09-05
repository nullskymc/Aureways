import AppKit
import SwiftStreamingMarkdown
import SwiftUI

/// Agent 正文交给 Microsoft SwiftStreamingMarkdown（cmark-gfm），本仓库不维护解析器。
/// 字体对齐对话画布 13.5pt；颜色用 Palette / 系统语义色，不走 Copilot 资源。
///
/// 用 `DocumentView`（渲染已解析文档）而不是 `MarkdownView`（自己在视图里解析）：
/// 解析结果存在 `MarkdownDocumentCache` 里，回收重建时能在 `init` 同步拿到，块一
/// 放上去就有真实高度——`LazyVStack` 的高度估算依赖这一点。
struct MarkdownBody: View {
    let source: String
    var isStreaming: Bool

    @State private var document: RenderableDocument?

    init(source: String, isStreaming: Bool = false) {
        self.source = source
        self.isStreaming = isStreaming
        _document = State(initialValue: MarkdownDocumentCache.shared.cached(source))
    }

    private var config: MarkdownRenderConfig {
        isStreaming ? AurewaysMarkdown.animated : AurewaysMarkdown.plain
    }

    var body: some View {
        Group {
            if let document {
                DocumentView(renderableDocument: document, config: config)
            } else {
                // 解析落地前用同字号明文占位。高度只是近似，但远好过 0——
                // 高度 0 会让虚拟化的 stack 把这条消息当成不存在。
                Text(source)
                    .font(.system(size: AurewaysMarkdown.body))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            document = await MarkdownDocumentCache.shared.document(
                for: source,
                config: config,
                // 流式中间态不入缓存：不会被回看，只会把有用的条目挤出去。
                store: !isStreaming
            )
        }
    }
}

/// 对话画布的 Markdown 渲染配置。`MarkdownDocumentCache` 预热时也用 `plain`。
enum AurewaysMarkdown {
    static let body: CGFloat = 13.5
    static let code: CGFloat = 12.5
    static let table: CGFloat = 12.5
    static let chrome: CGFloat = 11

    /// 两个配置各只构造一次。每次求值新建 config 会让库里
    /// `CodeBlockView.onChange(of: config)` 判定不等，白白重跑一次语法高亮。
    static let plain = config.withShouldAnimateText(value: false)
    static let animated = config.withShouldAnimateText(value: true)

    static let bodyFonts = fonts(body)
    static let tableFonts = fonts(table)
    static let chromeFonts = fonts(chrome)
    static let codeFonts = TextFonts(
        normal: mono(code),
        italic: nil,
        bold: NSFont.monospacedSystemFont(ofSize: code, weight: .semibold),
        boldItalic: nil,
        preferredLetterSpacing: nil,
        preferredLineHeight: nil
    )

    static let config: MarkdownRenderConfig = {
        let defaults = MarkdownRenderConfig.default
        return MarkdownRenderConfig(
            shouldAnimateText: false,
            blockQuoteStyle: .init(textFonts: bodyFonts, textColor: .secondary),
            headingStyle: .init(
                h1Font: headingFonts(21),
                h2Font: headingFonts(17.5),
                h3Font: headingFonts(15.5),
                h4Font: headingFonts(14),
                h5Font: headingFonts(13.5),
                h6Font: headingFonts(13.5),
                textColor: .primary
            ),
            orderedListStyle: .init(textFonts: bodyFonts, textColor: .primary),
            paragraphStyle: .init(textFonts: bodyFonts, textColor: .primary),
            tableStyle: .init(
                textFonts: tableFonts,
                headerTextColor: .primary,
                regularTextColor: .primary,
                headerBackgroundColor: Palette.badgeBg,
                borderColor: Palette.border,
                actionButtonColor: Palette.accent
            ),
            inlineStyle: .init(
                boldTextColor: .primary,
                linkTextFont: system(body),
                linkTextColor: Palette.accent,
                linkUnderlineStyle: [],
                codeTextFont: mono(code),
                codeTextColor: .primary,
                codeBackgroundColor: Palette.badgeBg,
                codeUnderlineColor: .clear
            ),
            textContextMenu: defaults.textContextMenu,
            citationConfig: .init(
                font: defaults.citationConfig.font,
                textColor: .secondary,
                backgroundColor: Palette.badgeBg
            ),
            codeBlockConfig: CodeBlockConfig(
                theme: .xcode,
                backgroundColor: Palette.badgeBg,
                foregroundColor: .secondary,
                codeTextFonts: codeFonts,
                chromeTextFonts: chromeFonts
            ),
            blockSpacing: defaults.blockSpacing,
            textSelectionConfig: defaults.textSelectionConfig,
            thematicBreakColor: Palette.border,
            imageConfig: defaults.imageConfig
        )
    }()

    static func headingFonts(_ size: CGFloat) -> TextFonts {
        fonts(size, weight: .semibold)
    }

    static func fonts(_ size: CGFloat, weight: NSFont.Weight = .regular) -> TextFonts {
        TextFonts(
            normal: system(size, weight: weight),
            italic: system(size, weight: weight, italic: true),
            bold: system(size, weight: .semibold),
            boldItalic: system(size, weight: .semibold, italic: true),
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }

    static func system(
        _ size: CGFloat,
        weight: NSFont.Weight = .regular,
        italic: Bool = false
    ) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
