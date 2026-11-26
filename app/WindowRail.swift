// The window's icon rail (Rebuild B, 26 November 2026, the user: "a bit more ephemeral and less like a document"):
// every page one symbol down the left edge, the page you are on lifted in the accent colour, Settings and Help at the
// foot. The pages stay in the ⋯ menu too, with their keys; the rail only shows where they are. No state of its own.
import SwiftUI

struct WindowRail: View {
    @EnvironmentObject var m: WindowModel
    struct Place: Identifiable {
        let page: WindowModel.Page, word: String, symbol: String, key: String
        var id: String { word }
    }
    static let top: [Place] = [
        Place(page: .tape, word: "Journal", symbol: "text.line.first.and.arrowtriangle.forward", key: "⌘F"),
        Place(page: .names, word: "Names", symbol: "person.2", key: "⇧⌘N"),
        Place(page: .links, word: "Links & Files", symbol: "link", key: "⇧⌘L"),
        Place(page: .screen, word: "What Drafter sees", symbol: "eye", key: "⇧⌘I"),
        Place(page: .dictionary, word: "Dictionary", symbol: "character.book.closed", key: "⇧⌘D"),
        Place(page: .shortcuts, word: "Shortcuts", symbol: "command", key: "⌘J"),
    ]
    static let foot: [Place] = [
        Place(page: .settings, word: "Settings", symbol: "gearshape", key: "⌘,"),
        Place(page: .help, word: "Help", symbol: "questionmark.circle", key: "⌘/"),
    ]
    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 40)   // the window's three dots
            ForEach(Self.top) { p in RailButton(place: p, on: on(p)) { go(p) } }
            Spacer(minLength: 8)
            ForEach(Self.foot) { p in RailButton(place: p, on: on(p)) { go(p) } }
        }
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
    }
    /// The journal's place covers a recording opened from it.
    func on(_ p: Place) -> Bool { m.page == p.page || (p.page == .tape && m.page == .doc) }
    func go(_ p: Place) {
        if p.page == .tape { m.back(); m.commandMode = false; m.nav.region = .search }
        else { m.page = p.page }
    }
}

/// One place on the rail: its symbol in a 36 pt square, lifted when it is the page you are on.
struct RailButton: View {
    let place: WindowRail.Place
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: place.symbol)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? UIInk.blue : hover ? UIInk.ink : UIInk.muted)
                .frame(width: 36, height: 36)
                .background {
                    if on { RoundedRectangle(cornerRadius: 10).fill(UIInk.blue.opacity(0.14)) }
                    else if hover { RoundedRectangle(cornerRadius: 10).fill(UIInk.hover) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(place.word) (\(place.key))")
        .accessibilityLabel(place.word)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
