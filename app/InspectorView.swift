// Live Screen Context & Status Inspector: shows why Drafter is active or quiet, which app/window/field is targeted,
// whether context came from Accessibility or Screen OCR, a masked-by-default in-memory context preview, and the warm
// screen cache. Screen text stays in memory only (never logged or saved). Pure rules: app/InspectorRules.swift.
import AppKit
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var m: WindowModel
    @State private var snapshot = ScreenSnapshot()
    @State private var revealContext = false
    @State private var copied = false
    @State private var lastUpdated = Date()
    @State private var timer: Timer?

    private var summary: StatusSummary { InspectorRules.summarize(snapshot) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                statusBanner
                targetAndEngineCard
                contextPreviewCard
                warmScreensCard
            }
            .padding(.horizontal, PageLayout.margin)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refresh()
            startPolling()
        }
        .onDisappear {
            stopPolling()
            revealContext = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard AppWindow.shared.isOwnWindow(note.object) else { return }
            stopPolling()
            revealContext = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard AppWindow.shared.isOwnWindow(note.object), m.page == .screen, !m.preview else { return }
            refresh()
            if timer == nil { startPolling() }
        }
    }

    // MARK: header

    private var headerRow: some View {
        PageHeader("What Drafter sees", subtitle: InspectorRules.menuLine(snapshot)) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(m.preview ? UIInk.faint : UIInk.mint)
                        .frame(width: 6, height: 6)
                    Text(m.preview ? "Preview" : "Live · 1s")
                        .font(NativeFont.mono(11))
                        .foregroundStyle(UIInk.faint)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(Capsule().fill(UIInk.well))
                PagePillButton(title: "Refresh", glyph: "refresh") { refresh() }
                    .help("Refresh live snapshot now")
            }
        }
    }

    // MARK: 1. status banner

    private var statusBanner: some View {
        let s = summary
        let dotColor: Color = {
            switch s.tone {
            case .ok: return Color(nsColor: Native.ok)
            case .warn: return Color(nsColor: Native.warn)
            case .muted: return UIInk.faint
            }
        }()
        let tintBg: Color = {
            switch s.tone {
            case .ok: return Color(nsColor: Native.okBg)
            case .warn: return Color(nsColor: Native.warnBg)
            case .muted: return UIInk.well
            }
        }()
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .accessibilityLabel(s.tone.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.headline)
                    .font(NativeFont.text(14, .semibold))
                    .foregroundStyle(UIInk.ink)
                Text(s.detail)
                    .font(NativeFont.text(12))
                    .foregroundStyle(UIInk.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            bannerActions
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(tintBg))
        .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
    }

    @ViewBuilder
    private var bannerActions: some View {
        HStack(spacing: 8) {
            if !snapshot.accessibilityAllowed {
                actionButton("Open Accessibility", glyph: "external", primary: true) {
                    openPrivacyPane("Privacy_Accessibility")
                }
            } else if snapshot.pausedGlobal {
                actionButton("Resume", glyph: "play", primary: true) {
                    guard !m.preview else { snapshot.pausedGlobal = false; snapshot.quietReason = "ok"; return }
                    Drafter.shared.change { $0.paused = false }
                    Drafter.shared.apply()
                    refresh()
                }
            }
            if !snapshot.screenRecordingAllowed {
                actionButton("Open Screen Recording", glyph: "external", primary: false) {
                    openPrivacyPane("Privacy_ScreenCapture")
                }
            }
        }
    }

    // MARK: 2. target & engine grid card

    private var targetAndEngineCard: some View {
        PageCard {
            VStack(alignment: .leading, spacing: 10) {
                PageSectionHead(title: "Target & Engine", glyph: "device-desktop")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                    gridRow("Active App") {
                        HStack(spacing: 8) {
                            Text(snapshot.appName.isEmpty ? "-" : snapshot.appName)
                                .font(NativeFont.text(13, .medium))
                                .foregroundStyle(UIInk.ink)
                                .lineLimit(1)
                            if !snapshot.bundleID.isEmpty && snapshot.bundleID != snapshot.appName {
                                Text(snapshot.bundleID)
                                    .font(NativeFont.mono(11))
                                    .foregroundStyle(UIInk.faint)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    gridRow("Window Title") {
                        Text(snapshot.windowTitle.isEmpty ? "-" : snapshot.windowTitle)
                            .font(NativeFont.text(13))
                            .foregroundStyle(snapshot.windowTitle.isEmpty ? UIInk.faint : UIInk.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    gridRow("Field Role") {
                        Text(snapshot.fieldRole.isEmpty ? "-" : snapshot.fieldRole)
                            .font(NativeFont.mono(12))
                            .foregroundStyle(snapshot.fieldRole.isEmpty ? UIInk.faint : UIInk.muted)
                    }
                    gridRow("Context Source") {
                        HStack(spacing: 8) {
                            sourceBadge(snapshot.contextSource)
                            Text(contextSizeLine)
                                .font(NativeFont.mono(11))
                                .foregroundStyle(UIInk.muted)
                        }
                    }
                    gridRow("Last Ghost") {
                        Text(lastGhostLine)
                            .font(NativeFont.mono(12))
                            .foregroundStyle(snapshot.lastGhostMs == nil && snapshot.lastGhostSrc.isEmpty ? UIInk.faint : UIInk.ink)
                    }
                    gridRow("Engine") {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(engineDotColor)
                                .frame(width: 7, height: 7)
                            Text(engineStatusLine)
                                .font(NativeFont.mono(11))
                                .foregroundStyle(UIInk.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    gridRow("Permissions") {
                        HStack(spacing: 8) {
                            permBadge("Accessibility", ok: snapshot.accessibilityAllowed)
                            permBadge("Screen Recording", ok: snapshot.screenRecordingAllowed)
                        }
                    }
                }
            }
        }
    }

    private var contextSizeLine: String {
        guard snapshot.contextChars > 0 else { return "0 chars · -" }
        return "\(snapshot.contextChars) chars · \(InspectorRules.formatAge(snapshot.contextAgeSec))"
    }

    private var lastGhostLine: String {
        guard !snapshot.lastGhostSrc.isEmpty || snapshot.lastGhostMs != nil else { return "-" }
        var parts: [String] = []
        if !snapshot.lastGhostSrc.isEmpty { parts.append(snapshot.lastGhostSrc) }
        if let ms = snapshot.lastGhostMs { parts.append("\(ms) ms") }
        if let age = snapshot.lastGhostAgeSec { parts.append(InspectorRules.formatAge(age)) }
        return parts.joined(separator: " · ")
    }

    private var engineDotColor: Color {
        if !snapshot.engineReady { return Color(nsColor: Native.warn) }
        if snapshot.modelAsleep { return UIInk.faint }
        return Color(nsColor: Native.ok)
    }

    private var engineStatusLine: String {
        let state = !snapshot.engineReady ? "Loading" : snapshot.modelAsleep ? "Asleep" : "Ready"
        return snapshot.engineInfo.isEmpty ? state : "\(state) · \(snapshot.engineInfo)"
    }

    // MARK: 3. in-memory screen context preview box

    private var contextPreviewCard: some View {
        PageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PageSectionHead(title: "Screen Context", glyph: "text")
                    HStack(spacing: 4) {
                        Glyph("check", size: 11)
                        Text("In memory only · never saved or logged")
                            .font(NativeFont.text(11))
                    }
                    .foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(UIInk.well))
                    Spacer(minLength: 8)
                    if revealContext, !snapshot.contextText.isEmpty {
                        Button { copyContext() } label: {
                            HStack(spacing: 4) {
                                Glyph(copied ? "check" : "copy", size: 12)
                                Text(copied ? "Copied" : "Copy").font(NativeFont.text(12))
                            }
                            .foregroundStyle(copied ? Color(nsColor: Native.ok) : UIInk.muted)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Capsule().fill(UIInk.well))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Copy the in-memory screen context to the clipboard")
                    }
                    Button {
                        revealContext.toggle()
                        copied = false
                    } label: {
                        HStack(spacing: 4) {
                            Glyph("blur", size: 12)
                            Text(revealContext ? "Hide" : "Show").font(NativeFont.text(12, .medium))
                        }
                        .foregroundStyle(UIInk.ink)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(revealContext ? UIInk.pick : UIInk.well))
                        .overlay { Capsule().strokeBorder(UIInk.line, lineWidth: 0.5) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(revealContext ? "Mask the in-memory context preview" : "Reveal the in-memory screen context")
                }

                Group {
                    if revealContext {
                        if snapshot.contextText.isEmpty {
                            Text("No screen context in memory for the current target.")
                                .font(NativeFont.text(12))
                                .foregroundStyle(UIInk.faint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else {
                            ScrollView {
                                Text(snapshot.contextText)
                                    .font(NativeFont.mono(12))
                                    .foregroundStyle(UIInk.ink)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(minHeight: 90, maxHeight: 220)
                        }
                    } else {
                        Text(InspectorRules.maskText(snapshot.contextText, lines: 6))
                            .font(NativeFont.mono(12))
                            .foregroundStyle(UIInk.muted)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
            }
        }
    }

    // MARK: 4. warm screens list

    private var warmScreensCard: some View {
        PageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PageSectionHead(title: "Warm Screens", glyph: "app-window")
                    Text("\(snapshot.cachedScreens.count)")
                        .font(NativeFont.mono(11))
                        .foregroundStyle(UIInk.muted)
                        .padding(.horizontal, 7).frame(height: 19)
                        .background(Capsule().fill(UIInk.well))
                    Spacer()
                    Text("In-memory cache for fast switching")
                        .font(NativeFont.text(11))
                        .foregroundStyle(UIInk.faint)
                }

                if snapshot.cachedScreens.isEmpty {
                    Text("No warm screens cached in memory yet.")
                        .font(NativeFont.text(12))
                        .foregroundStyle(UIInk.faint)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.cachedScreens.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 10) {
                                Glyph("app-window", size: 13).foregroundStyle(UIInk.faint)
                                Text(Self.prettyWarmTitle(item.title))
                                    .font(NativeFont.text(13))
                                    .foregroundStyle(UIInk.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                sourceBadge(item.source)
                                Text("\(item.chars) chars")
                                    .font(NativeFont.mono(11))
                                    .foregroundStyle(UIInk.muted)
                                    .frame(width: 72, alignment: .trailing)
                                Text(InspectorRules.formatAge(item.ageSec))
                                    .font(NativeFont.mono(11))
                                    .foregroundStyle(UIInk.faint)
                                    .frame(width: 72, alignment: .trailing)
                            }
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) {
                                if idx > 0 { Rectangle().fill(UIInk.line).frame(height: 0.5) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func prettyWarmTitle(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " · ")
        guard let first = parts.first, first.contains(".") else { return raw }
        let known: [String: String] = [
            "com.automattic.beeper.desktop": "Beeper",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.apple.mail": "Mail",
            "com.apple.safari": "Safari",
            "com.apple.notes": "Notes",
            "com.apple.finder": "Finder",
            "com.apple.terminal": "Terminal",
            "md.obsidian": "Obsidian",
            "notion.id": "Notion",
            "com.anthropic.claudefordesktop": "Claude",
            "com.openai.chat": "ChatGPT",
        ]
        let lower = first.lowercased()
        let app: String
        if let mapped = known[lower] {
            app = mapped
        } else {
            let segs = first.split(separator: ".").map(String.init)
            let pick = segs.last.map { ["desktop", "app", "mac", "client"].contains($0.lowercased()) && segs.count >= 2 ? segs[segs.count - 2] : $0 } ?? first
            app = pick.prefix(1).uppercased() + pick.dropFirst()
        }
        if parts.count == 1 { return app }
        return ([app] + parts.dropFirst()).joined(separator: " · ")
    }

    // MARK: reusable pieces

    private func gridRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(NativeFont.text(12))
                .foregroundStyle(UIInk.muted)
                .frame(width: 112, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceBadge(_ src: String) -> some View {
        let lower = src.lowercased()
        let label = InspectorRules.sourceLabel(src)
        let fg: Color = lower == "ax" ? UIInk.blue : lower == "ocr" ? UIInk.violet : UIInk.faint
        let bg: Color = lower == "ax" ? UIInk.selected : lower == "ocr" ? Color(nsColor: Native.actionBg) : UIInk.well
        return Text(label)
            .font(NativeFont.text(11, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(bg))
    }

    private func permBadge(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Color(nsColor: Native.ok) : Color(nsColor: Native.warn))
                .frame(width: 6, height: 6)
            Text("\(name): \(ok ? "On" : "Off")")
                .font(NativeFont.text(11))
                .foregroundStyle(ok ? UIInk.muted : UIInk.ink)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(Capsule().fill(ok ? UIInk.well : Color(nsColor: Native.warnBg)))
    }

    private func actionButton(_ title: String, glyph: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Glyph(glyph, size: 12)
                Text(title).font(NativeFont.text(12, .medium))
            }
            .foregroundStyle(primary ? UIInk.onPrimary : UIInk.ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(primary ? UIInk.primary : UIInk.card))
            .overlay { if !primary { Capsule().strokeBorder(UIInk.rule, lineWidth: 0.5) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: actions & polling

    private func refresh() {
        lastUpdated = Date()
        if m.preview {
            snapshot = InspectorPreview.sample()
        } else {
            snapshot = Keys.shared.liveSnapshot()
        }
    }

    private func startPolling() {
        stopPolling()
        guard !m.preview else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard AppWindow.shared.isVisible else { stopPolling(); return }
            refresh()
        }
        t.tolerance = 0.2
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func copyContext() {
        guard !snapshot.contextText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snapshot.contextText, forType: .string)
        // Mark as Drafter's own + concealed so neither Drafter's clipboard journal nor other clipboard managers store screen text on disk.
        pb.setString("1", forType: History.ownType)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        History.skipChange(pb.changeCount)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }

    private func openPrivacyPane(_ anchor: String) {
        if anchor == "Privacy_Accessibility" {
            Focus.trusted(prompt: true)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Synthetic sample snapshot for `--ui-preview` (no real data, no private names).
enum InspectorPreview {
    static func sample() -> ScreenSnapshot {
        let sampleContext = """
        Them: Can we review the release checklist at 3?
        Me: Sure, I will finish the notes in ten minutes.
        Them: Great, drop the link here once ready.
        """
        return ScreenSnapshot(
            appName: "Beeper",
            bundleID: "com.automattic.beeper.desktop",
            windowTitle: "Product Sync",
            fieldRole: "AXTextArea",
            contextSource: "ocr",
            contextChars: sampleContext.count,
            contextAgeSec: 6,
            contextText: sampleContext,
            quietReason: "ok",
            pausedGlobal: false,
            pausedInField: false,
            engineReady: true,
            engineInfo: "local-3b · 2.1 GB · 412 words",
            modelAsleep: false,
            secureHolder: nil,
            screenRecordingAllowed: true,
            accessibilityAllowed: true,
            lastGhostSrc: "model",
            lastGhostMs: 34,
            lastGhostAgeSec: 9,
            cachedScreens: [
                CachedScreenInfo(id: "p1", title: "com.automattic.beeper.desktop · Product Sync", chars: 137, ageSec: 6, source: "ocr"),
                CachedScreenInfo(id: "p2", title: "com.tinyspeck.slackmacgap · #design-review", chars: 482, ageSec: 47, source: "ax"),
                CachedScreenInfo(id: "p3", title: "com.apple.mail · Weekly summary draft", chars: 315, ageSec: 185, source: "ax"),
            ]
        )
    }
}
