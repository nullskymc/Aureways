import AppKit
import MarkdownUI
import SwiftUI

struct MarkdownBody: View {
    let source: String

    var body: some View {
        Markdown(source)
            .markdownTheme(aurewaysTheme)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClearSelectableTextBackground())
    }

    private var aurewaysTheme: Theme {
        Theme()
            .text {
                FontSize(13.5)
                ForegroundColor(.primary)
                BackgroundColor(.clear)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(12.5)
                ForegroundColor(.primary)
                BackgroundColor(Palette.badgeBg)
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(Palette.accent)
            }
            .heading1 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 18, bottom: 10)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.6))
                        BackgroundColor(.clear)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 16, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.3))
                        BackgroundColor(.clear)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 14, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.15))
                        BackgroundColor(.clear)
                    }
            }
            .heading4 { configuration in
                configuration.label
                    .markdownMargin(top: 12, bottom: 6)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        BackgroundColor(.clear)
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 10)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.border)
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                            BackgroundColor(.clear)
                        }
                        .padding(.leading, 10)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 10)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.2))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(12)
                            BackgroundColor(.clear)
                        }
                        .padding(10)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .markdownMargin(top: 0, bottom: 10)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.2))
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: Palette.border))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(.clear, Palette.badgeBg)
                    )
                    .markdownMargin(top: 0, bottom: 10)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                        BackgroundColor(.clear)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 16, bottom: 16)
            }
    }
}

/// macOS 开启 textSelection 后，系统可能插入带白底的 NSTextView。
private struct ClearSelectableTextBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.clear()
    }

    final class ProbeView: NSView {
        private var handled = Set<ObjectIdentifier>()

        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clear()
        }

        override func layout() {
            super.layout()
            clear()
        }

        func clear() {
            walk(superview)
        }

        private func walk(_ view: NSView?) {
            guard let view else { return }
            if let textView = view as? NSTextView, handled.insert(ObjectIdentifier(textView)).inserted {
                textView.drawsBackground = false
                textView.backgroundColor = .clear
            }
            view.subviews.forEach(walk)
        }
    }
}
