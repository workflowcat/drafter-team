// The first-run window (cohesion round, 26 November 2026): one short page that walks a new user through what Drafter needs,
// in the order docs/onboarding.md gives. Shown once at the first launch; the menu bar's "Welcome and setup…" opens it again.
// Every step can be skipped; nothing here is required except Accessibility.
import AppKit
import AVFoundation
import EventKit
import SwiftUI

enum Welcome {
    private static var window: NSWindow?
    static var marker: URL { Home.data.appendingPathComponent(".welcomed") }

    /// The permission list Settings and this window share.
    static func permissions(_ s: Settings, preview: Bool = false, accessibility: Bool? = nil, screen: Bool? = nil,
                            calendar: Bool? = nil, systemKey: Bool? = nil) -> [PermissionItem] {
        let mic = preview ? true : AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return SettingsSearchRules.permissions(
            accessibility: accessibility ?? (preview || Focus.trusted()), microphone: mic,
            screenRecording: screen ?? (preview || Screen.allowed),
            calendar: calendar ?? (preview || EKEventStore.authorizationStatus(for: .event) == .fullAccess),
            voiceOn: s.voice, screenUsed: s.shots || s.screenContext,
            captureSystemKeyOn: systemKey ?? (!preview && Capture.systemKeyOn), captureEnabled: !s.captureKey.isEmpty)
    }

    /// At launch: the real app only, and only until the user has finished or closed it once.
    static func showIfFirstRun() {
        guard CommandLine.arguments.count == 1, !FileManager.default.fileExists(atPath: marker.path) else { return }
        show()
    }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Drafter"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView(done: { finish() }))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            markDone(); window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func finish() { markDone(); window?.close() }
    private static func markDone() { try? Data().write(to: marker) }

    /// Accessibility takes effect after a restart: start a new copy a moment after this one quits.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Saves the name and languages into data/drafter.local.json, keeping every other key.
    static func saveUser(name: String, languages: [String]) -> Bool {
        var json = LocalConfig.json
        var user = json["user"] as? [String: Any] ?? [:]
        user["name"] = name.trimmingCharacters(in: .whitespaces)
        if !languages.isEmpty { user["languages"] = languages }
        json["user"] = user
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do { try data.write(to: LocalConfig.file, options: .atomic) } catch { return false }
        SnippetRules.initials = SnippetRules.initials(name: name, given: LocalConfig.user("initials"))
        return true
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var tick = 0
    @State private var name = LocalConfig.user("name")
    @State private var languages = ((LocalConfig.json["user"] as? [String: Any])?["languages"] as? [String] ?? ["en"]).joined(separator: ", ")
    @State private var saved = ""
    @State private var voice = Drafter.shared.settings.voice
    @State private var nameDone = !LocalConfig.user("name").trimmingCharacters(in: .whitespaces).isEmpty
    @State private var picked: Int? = nil   // a step the user opened by its title
    /// Rebuild B: the step you are on lifts and opens (the first one not done, or the one picked); done steps fade, the
    /// rest wait folded to their titles.
    private var doneFlags: [Bool] {
        [item("accessibility")?.ok == true, nameDone, voice && item("microphone")?.ok == true,
         item("screen")?.ok == true && item("calendar")?.ok == true, false, false]
    }
    private var current: Int { picked ?? ((doneFlags.firstIndex(of: false) ?? 5) + 1) }
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var items: [PermissionItem] { _ = tick; return Welcome.permissions(Drafter.shared.settings) }
    private func item(_ id: String) -> PermissionItem? { items.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Drafter").font(NativeFont.display(22))
                    Text("Grey text at the caret from a small model on this Mac, voice on Right Option, and notes from your calls. Your text stays on this Mac unless you connect a model.")
                        .font(NativeFont.text(13)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                }
                step(1, "Allow Accessibility", done: item("accessibility")?.ok == true) {
                    Text("Drafter reads the field you type in and puts text into it. macOS asks once; quit and reopen Drafter after allowing it.")
                    HStack(spacing: 8) {
                        if let p = item("accessibility"), !p.ok {
                            Button("Open Accessibility") { Focus.trusted(prompt: true) }.buttonStyle(.borderedProminent)
                            Button("Reopen Drafter") { Welcome.relaunch() }
                        } else { ready }
                    }
                }
                step(2, "Your name and languages", done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Text("Used for your own lines in calls and your initials for the e-mail snippet. Saved in data/drafter.local.json on this Mac.")
                    TextField("Your name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    TextField("Languages, e.g. en, uk", text: $languages).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    HStack(spacing: 8) {
                        Button("Save") {
                            let langs = languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                            let ok = Welcome.saveUser(name: name, languages: langs)
                            saved = ok ? "Saved" : "Could not save. Check that data/ can be written."
                            if ok { nameDone = true; picked = nil }
                        }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        if !saved.isEmpty { Text(saved).foregroundStyle(UIInk.muted) }
                    }
                }
                step(3, "Voice on Right Option", done: voice && item("microphone")?.ok == true) {
                    Text("Hold Right Option and speak; let go, then press ↵ to put the words in. Needs the voice models: `scripts/setup.sh --voice`.")
                    HStack(spacing: 8) {
                        Toggle("Voice on Right Option", isOn: $voice).toggleStyle(.switch)
                            .onChange(of: voice) { _, on in
                                let st = Drafter.shared.change { $0.voice = on }
                                if st.voice {
                                    VoiceEngine.shared.preload()
                                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { tick += 1 } }
                                } else { Talk.shared.cancel(); VoiceEngine.shared.stop() }
                            }
                        if voice, let p = item("microphone"), !p.ok { openButton(p) }
                    }
                }
                step(4, "Calls and calendars", done: item("screen")?.ok == true && item("calendar")?.ok == true, optional: true) {
                    Text("Screen & System Audio Recording hears the other side of a call and keeps screenshots while recording. Calendars name your meetings and offer notes before a call. Both stay on this Mac.")
                    HStack(spacing: 8) {
                        if let p = item("screen") { p.ok ? AnyView(Text("Screen recording ready").foregroundStyle(UIInk.muted)) : AnyView(openButton(p)) }
                        if let p = item("calendar") {
                            p.ok ? AnyView(Text("Calendars ready").foregroundStyle(UIInk.muted))
                                 : AnyView(Button("Allow Calendars") { Actions.store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async { tick += 1 } } })
                        }
                    }
                }
                step(5, "Connect a model", done: false, optional: true) {
                    Text("For bigger rewrites and call summaries, connect Claude or any OpenAI-compatible server. Each feature that sends text has its own switch, off until you turn it on.")
                    Button("Open Settings › Cloud") { AppWindow.shared.show(); AppWindow.shared.model.page = .settings }
                }
                step(6, "Try it", done: false) {
                    Text("In any app, type a few words and pause: grey text appears. Tab takes the next word, ⇧Tab all of it. Hold Right Option to speak. Open the window from the pen in the menu bar to see what you typed, said, copied and recorded.")
                }
                HStack {
                    Text("Open this again from the menu bar: Welcome and setup…").font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                    Spacer()
                    HudPill([], go: ("↵", "Done")) { done() }   // Rebuild B: the keys in one pill
                    Button("Done") { done() }.keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }.padding(.top, 12)
            }
            .padding(24).font(NativeFont.text(13))
            .glassCard()   // Rebuild B: one glass card on the washed ground
            .padding(20)
        }
        .background {
            LinearGradient(colors: [UIInk.blue.opacity(0.06), UIInk.paper, UIInk.violet.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .frame(width: 600, height: 720)
        .onReceive(timer) { _ in tick += 1 }
    }

    private var ready: some View {
        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Color(nsColor: Native.ok))
    }

    private func openButton(_ p: PermissionItem) -> some View {
        Button(p.actionLabel) { if let u = URL(string: p.settingsURL) { NSWorkspace.shared.open(u) } }
    }

    private func step<C: View>(_ n: Int, _ title: String, done: Bool, optional: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        let on = n == current
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(on ? UIInk.blue : done ? Color(nsColor: Native.ok) : UIInk.soft).frame(width: 24, height: 24)
                if done && !on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(NativeFont.mono(12)).foregroundStyle(on ? .white : UIInk.muted) }
            }.accessibilityLabel(done ? "Step \(n), done" : on ? "Step \(n), current" : "Step \(n)")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(NativeFont.text(on ? 15 : 13, on ? .semibold : .regular)).foregroundStyle(on ? UIInk.ink : UIInk.muted)
                    if optional { Text("optional").font(NativeFont.text(11)).foregroundStyle(UIInk.faint) }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .onTapGesture { if !on { picked = n } }
                .accessibilityAddTraits(on ? [] : .isButton)
                if on { content().foregroundStyle(UIInk.ink).fixedSize(horizontal: false, vertical: true).transition(.opacity) }
            }
        }
        .padding(.horizontal, on ? 16 : 6).padding(.vertical, on ? 14 : 4)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: Native.lift))
                    .shadow(color: .black.opacity(Native.dark ? 0.4 : 0.10), radius: 14, y: 5)
            }
        }
        .opacity(done && !on ? 0.55 : 1)
        .animation(.easeOut(duration: Native.motion("fold")), value: on)
    }
}
