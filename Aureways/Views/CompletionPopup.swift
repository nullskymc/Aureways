import SwiftUI

struct CompletionItem: Identifiable, Equatable {
    enum Kind { case slash, file }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let file: IndexedFile?
}

struct CompletionPopup: View {
    let items: [CompletionItem]
    let selectedIndex: Int
    let onSelect: (CompletionItem) -> Void

    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 6

    static func height(itemCount: Int) -> CGFloat {
        CGFloat(min(max(itemCount, 0), maxVisibleRows)) * rowHeight + 8
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(index, item)
                            .id(item.id)
                            .frame(height: Self.rowHeight)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .frame(width: 400, height: Self.height(itemCount: items.count))
            .onChange(of: selectedIndex) { _, newIndex in
                if let item = items[safe: newIndex] {
                    proxy.scrollTo(item.id)
                }
            }
        }
        .liquidGlassCard(cornerRadius: 10, veil: 0.65)
    }

    private func row(_ index: Int, _ item: CompletionItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.kind == .slash ? "terminal" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                Text(item.title)
                    .font(.system(size: 12, weight: item.kind == .slash ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
            .glassRowHighlight(isSelected: index == selectedIndex, isHovered: false, cornerRadius: 6)
        }
        .buttonStyle(.plain)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
