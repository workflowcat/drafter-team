// Shared page chrome for full-window pages (Names, Links, Screen Inspector, Dictionary, Shortcuts, Settings, Help).
// Keeps header typography, search bars, cards, inline fields, and horizontal margins identical across every page.
import SwiftUI

enum PageLayout {
    static let margin: CGFloat = 24
    static let searchWidth: CGFloat = 280
}

/// The page's place (Rebuild B, 26 November 2026: no page titles, the place is a chip): a small glass chip with the
/// page's name and its count, the one muted line after it, the trailing slot (a search field or the page's controls)
/// at the right. No hairline under it: the page floats on the window's ground.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var count: Int? = nil
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PlaceChip(title: title, count: count)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(NativeFont.text(12))
                    .foregroundStyle(UIInk.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Where you are, as a chip: the page's name in 13 pt semibold on the glass, its count after it.
struct PlaceChip: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(NativeFont.text(13, .semibold)).foregroundStyle(UIInk.ink).lineLimit(1)
            if let count {
                Text("\(count)").font(NativeFont.num(11)).foregroundStyle(UIInk.muted)
                    .accessibilityLabel("\(count) items")
            }
        }
        .padding(.horizontal, 12).frame(height: 28)
        .glassCard(radius: 14)
        .accessibilityAddTraits(.isHeader)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, count: Int? = nil) {
        self.init(title, subtitle: subtitle, count: count) { EmptyView() }
    }
}

/// Unified page search field: 30pt height, UIInk.well fill, search glyph, optional spinner, clear button,
/// and consistent focus border (1pt UIInk.blue focused vs 0.5pt UIInk.rule unfocused).
struct PageSearchField: View {
    let placeholder: String
    @Binding var text: String
    var loading: Bool = false
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    var accessibility: String? = nil
    @FocusState private var localFocus: Bool

    private var isFocused: Bool { focus?.wrappedValue ?? localFocus }
    private var focusBinding: FocusState<Bool>.Binding { focus ?? $localFocus }

    var body: some View {
        HStack(spacing: 8) {
            Glyph("search", size: 14)
                .foregroundStyle(isFocused ? UIInk.ink : UIInk.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(NativeFont.text(13))
                .focused(focusBinding)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(accessibility ?? placeholder)
            if loading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Loading")
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    focusBinding.wrappedValue = true
                } label: {
                    Glyph("close", size: 12)
                        .foregroundStyle(UIInk.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
        .overlay {
            RoundedRectangle(cornerRadius: Native.corner(2))
                .strokeBorder(isFocused ? UIInk.blue : UIInk.rule, lineWidth: isFocused ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusBinding.wrappedValue = true }
    }
}

/// Unified card container: UIInk.card surface, Native.corner(2) radius, 0.5pt UIInk.line border, 14pt padding.
struct PageCard<Content: View>: View {
    var padding: CGFloat = 14
    let content: Content

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.card))
            .overlay {
                RoundedRectangle(cornerRadius: Native.corner(2))
                    .strokeBorder(UIInk.line, lineWidth: 0.5)
            }
    }
}

/// Compact section header inside a PageCard: glyph + 13.5pt semibold title.
struct PageSectionHead: View {
    let title: String
    var glyph: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let glyph {
                Glyph(glyph, size: 14).foregroundStyle(UIInk.muted)
            }
            Text(title)
                .font(NativeFont.text(13, .semibold))
                .foregroundStyle(UIInk.ink)
        }
    }
}

/// Styled inline text field replacing raw system .roundedBorder boxes: UIInk.well fill with crisp UIInk.line border.
struct PageField: View {
    let placeholder: String
    @Binding var text: String
    var mono: Bool = false
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    @FocusState private var localFocus: Bool

    private var isFocused: Bool { focus?.wrappedValue ?? localFocus }
    private var focusBinding: FocusState<Bool>.Binding { focus ?? $localFocus }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? NativeFont.mono(12) : NativeFont.text(13))
            .focused(focusBinding)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
            .overlay {
                RoundedRectangle(cornerRadius: Native.corner(2))
                    .strokeBorder(isFocused ? UIInk.blue : UIInk.line, lineWidth: isFocused ? 1 : 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture { focusBinding.wrappedValue = true }
    }
}

/// Consistent capsule action button for secondary/primary controls inside page headers and cards.
struct PagePillButton: View {
    let title: String
    var glyph: String? = nil
    var primary: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph {
                    Glyph(glyph, size: 12)
                }
                Text(title)
                    .font(NativeFont.text(12, .medium))
            }
            .foregroundStyle(!enabled ? UIInk.faint : primary ? UIInk.onPrimary : UIInk.ink)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule().fill(
                    !enabled ? UIInk.well
                    : primary ? UIInk.primary
                    : hover ? UIInk.hover : UIInk.well
                )
            )
            .overlay {
                if !primary {
                    Capsule().strokeBorder(UIInk.line, lineWidth: 0.5)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}
