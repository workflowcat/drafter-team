// Small pieces the window's pages share: Back to the journal (BackRow), buttons that wrap (FlowRow), why a tag is
// there. Kept from the journal's panes, which the stream round (23 November 2026, app/Stream.swift) replaced.
import AppKit
import SwiftUI

/// Buttons that wrap to the next line when the pane is narrow.
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

struct BackRow: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Button { m.back() } label: {
                HStack(spacing: 6) {
                    Glyph("arrow-left", size: 14)
                    Text("Back").font(NativeFont.text(13, .medium))
                    KeyChip("esc")
                }
                .foregroundStyle(hover ? UIInk.ink : UIInk.muted)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(hover ? UIInk.hover : .clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityLabel("Back to the journal")
            .help("Back to the journal (esc)")
            if !title.isEmpty {
                Glyph("chevron-right", size: 11).foregroundStyle(UIInk.faint)
                Text(title).font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.muted).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

extension WindowModel {
    /// Why a tag is there, from the entity store (its own line), when it has one.
    func reason(_ t: TapeTag) -> String? { JournalTags.reason(t, store: Entities.store) }
    func links(_ t: TapeTag, others: [TapeTag]) -> [JournalTags.Link] { JournalTags.links(t, others: others.filter { $0 != t }, store: Entities.store, max: 3) }
}
