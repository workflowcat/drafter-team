// Settings on the tape's grid (look round "Tape", 14 November 2026). Each switch is a row: the gutter holds what it
// earned in the last 7 days (the take rate in mono) or a value ("⌃⌥V", "7 today"), then the switch, the name, a
// ten-cell meter coloured by the take rate (under 30 % bad, 30-50 % waiting, 50 % and up good), taken / shown in mono,
// and the cloud glyph when text leaves the Mac. Group headings with a hairline after them. The grid columns are
// 132 · 48 · name · 78 · 112 · 24, as on the concept board.
//
// Rows stay data: SettingsView's body (Window.swift) says `row(name, on, sends:, stat:) { set }` and `group(name) { }`;
// this file is only how they look, so new rows (another track adds some) take the look with no change here.
// Native look (23 November 2026): the system switch, system colours and font.
import AppKit
import SwiftUI

enum SettingsGrid {
    static let gutter: CGFloat = 132, gap: CGFloat = 20, toggle: CGFloat = 48, meter: CGFloat = 78, numbers: CGFloat = 112, cloud: CGFloat = 24
    static let rowH: CGFloat = 44
    /// 1 470 / 2 410: thousands apart by a thin space, as the concept.
    static func n(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "\u{202F}"; f.groupingSize = 3
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func rateColor(_ r: Double) -> Color { Color(nsColor: r < 0.3 ? Native.crit : r < 0.5 ? Native.warn : Native.ok) }
}

extension SettingsView {
    typealias G = SettingsGrid

    /// One line of the grid: the gutter (with its hairline), then the content; a hairline under it.
    func line<C: View>(gutter: String = "", tall: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(gutter).font(NativeFont.mono(13)).foregroundStyle(UIInk.muted).lineLimit(1)
                .frame(width: G.gutter - 14, alignment: .trailing).padding(.trailing, 14)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().fill(UIInk.line).frame(width: 1) }
            content().padding(.leading, G.gap).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: tall ? 56 : G.rowH)
        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 1) }
    }

    /// One switch: the take rate (or `value`) in the gutter, the switch, its name, the meter and taken / shown when it
    /// has numbers, the cloud when it sends text to Claude. No explanation under it (13 November).
    /// `to`: where a `sends` row's text goes; only Claude's rows wait for a connected model (Connect a model).
    @ViewBuilder
    func row(_ title: String, _ on: Bool, sends: Bool = false, to: String = "Claude", stat: String? = nil, typing: Bool = false, value: String? = nil,
             _ set: @escaping (inout Settings, Bool) -> Void) -> some View {
        if SettingsSearchRules.matches(query: search, title: title, extra: sends ? "cloud \(to)" : "") {
            let needs = sends && to == "Claude"
            let c: LogStats.Count? = stat.flatMap { k in m.stats.map { $0[k] ?? LogStats.Count() } }
            let rate: Double? = c.flatMap { $0.shown > 0 ? min(1, Double($0.taken) / Double($0.shown)) : nil }
            let gutter = rate.map { "\(Int(($0 * 100).rounded()))%" } ?? value ?? ""
            line(gutter: gutter) {
                HStack(spacing: 0) {
                    Toggle(title, isOn: Binding(get: { on && (!needs || m.settings.connect.connected) }, set: { v in m.save { set(&$0, v) } })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(needs && !m.settings.connect.connected && !m.preview)   // nothing connected: shown, off, disabled (app/Connect.swift)
                        .frame(width: G.toggle, alignment: .leading)
                    Text(title).font(NativeFont.text(16)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let c, c.shown > 0 { Meter(share: rate ?? 0, lit: c.taken > 0) } else { Color.clear }
                    }.frame(width: G.meter, alignment: .leading)
                    Text(c.map { $0.shown > 0 ? "\(G.n($0.taken)) / \(G.n($0.shown))" : "0 / 0" } ?? "")
                        .font(NativeFont.mono(13)).foregroundStyle(c?.shown == 0 ? UIInk.faint : UIInk.muted).lineLimit(1)
                        .frame(width: G.numbers, alignment: .trailing)
                    Group {
                        if sends { Glyph("cloud", size: 16).foregroundStyle(UIInk.muted).help("Sends text to \(to)").accessibilityLabel("Sends text to \(to)") }
                        else { Color.clear }
                    }.frame(width: G.cloud + 12, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(c.map { "Last 7 days: \($0.taken) taken of \($0.shown) shown" } ?? "")
            }
        }
    }

    /// A group: its heading (18 semibold) with a hairline after it. `column` non-empty: the column heads over the rows
    /// ("7 days" in the gutter, "taken / shown" over the numbers).
    func group<C: View>(_ title: String, column: String = "", @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            line(gutter: column.isEmpty ? "" : "7 days", tall: true) {
                HStack(spacing: 14) {
                    Text(title).font(NativeFont.text(18, .semibold)).lineLimit(1).fixedSize()
                    Rectangle().fill(UIInk.line).frame(height: 1)
                    if !column.isEmpty {
                        Text("taken / shown").font(NativeFont.text(13)).foregroundStyle(UIInk.faint)
                            .frame(width: G.numbers, alignment: .trailing)
                        Color.clear.frame(width: G.cloud - 2, height: 1)
                    }
                }
            }
            rows()
        }
    }

    /// A heading inside a group (an account, "Offer to record"), said once instead of on every row.
    func sub(_ title: String) -> some View {
        line {
            Text(title).font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.muted).padding(.leading, G.toggle)
        }
    }
}

extension SettingsView {
    @ViewBuilder func lookRow(_ title: String, _ choices: [(String, String)], _ value: String, _ tip: String, _ set: @escaping (String) -> Void) -> some View {
        if SettingsSearchRules.matches(query: search, title: title, extra: choices.map(\.1).joined(separator: " ") + " " + tip) {
            line {
                HStack(spacing: 0) {
                    Color.clear.frame(width: G.toggle, height: 1)
                    Text(title).font(NativeFont.text(16)).frame(maxWidth: .infinity, alignment: .leading)
                    WordPicker(choices: choices, value: value, pick: set).help(tip)
                    Color.clear.frame(width: G.cloud + 12, height: 1)
                }
            }
        }
    }
}

/// A few words to pick one from, the chosen one on the soft lift (as the light / dark choice).
struct WordPicker: View {
    let choices: [(String, String)]
    let value: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.0) { id, name in
                Button { pick(id) } label: {
                    Text(name).font(NativeFont.text(13)).foregroundStyle(value == id ? UIInk.ink : UIInk.muted)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(value == id ? UIInk.soft : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(value == id ? .isSelected : [])
            }
        }
        .padding(2).overlay { RoundedRectangle(cornerRadius: Native.corner(2) + 2).strokeBorder(UIInk.line, lineWidth: 1) }
    }
}

/// The meter: ten cells 5 x 12, 2 pt apart, rounded a little, lit for the share taken in the take rate's colour.
struct Meter: View {
    let share: Double
    let lit: Bool
    static let cells = 10
    var body: some View {
        let on = lit ? max(1, Int((share * Double(Self.cells)).rounded())) : 0
        let col = SettingsGrid.rateColor(share)
        HStack(spacing: 2) {
            ForEach(0..<Self.cells, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(i < on ? col : UIInk.soft).frame(width: 5, height: 12) }
        }
    }
}
