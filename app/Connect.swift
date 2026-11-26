import Foundation
import Security
import SwiftUI

/// "Connect a model" (2026-11-14): with nothing connected Drafter is fully local and every switch that sends text to a
/// model is shown but off and disabled. Connecting is the user's own act, one of three ways picked from a list: the
/// signed-in `claude` CLI, an Anthropic API key, or an OpenAI-compatible endpoint. Keys live in the macOS Keychain
/// only; after each engine start the app hands the key to the engine's memory over its local port (POST /model-key).
/// Never in data/settings.json, a log or a process argument. engine/provider.py makes the calls; engine/cloud.py gates.
enum Connect {
    enum Way: String, CaseIterable, Identifiable {
        case cli, anthropic, openai
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cli: return "Claude Code on this Mac (signed-in claude CLI)"
            case .anthropic: return "Anthropic API key"
            case .openai: return "OpenAI-compatible endpoint (other providers, a local server)"
            }
        }
    }

    static let service = "Drafter model key"

    // MARK: Keychain

    static func saveKey(_ key: String, for way: Way) -> Bool {
        deleteKey(for: way)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: way.rawValue, kSecValueData as String: Data(key.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func key(for way: Way) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: way.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func deleteKey(for way: Way) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: way.rawValue]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    // MARK: engine

    /// After each engine start and after connecting: the connected way (and its key, for an API) into the engine.
    /// Only into the engine this app started and checked (Engine.verified: its /health gave our instance id); any
    /// other process holding the port gets nothing.
    static func handOver() {
        guard Engine.shared.verified else { log("connect: engine not verified, key kept back"); return }
        let c = Drafter.shared.settings.connect
        guard let way = Way(rawValue: c.provider) else { return }
        var body: [String: Any] = ["provider": way.rawValue]
        if way == .anthropic { guard let k = key(for: way) else { return }; body["key"] = k }
        else if way == .openai, let k = key(for: way) { body["key"] = k }   // a local server may need no key
        Engine.shared.post("/model-key", body, timeout: 3)
    }

    /// The claude CLI is there (the local config's path, PATH, or a `claude` in ~/.local/bin).
    static func cliFound() -> Bool {
        let fm = FileManager.default
        if let p = LocalConfig.integration("claude")["bin"] as? String, !p.isEmpty,
           fm.isExecutableFile(atPath: (p as NSString).expandingTildeInPath) { return true }
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.contains { fm.isExecutableFile(atPath: $0 + "/claude") }
    }

    /// Connects one way; nil when done, else what went wrong. Every feature switch stays as it is (off on a new install).
    static func connect(_ way: Way, key: String, baseURL: String, apiModel: String, save: ((inout Settings) -> Void) -> Void) -> String? {
        switch way {
        case .cli:
            guard cliFound() else { return "No claude CLI found on this Mac. Install Claude Code and sign in, then try again." }
        case .anthropic:
            guard !key.isEmpty else { return "Paste your Anthropic API key." }
        case .openai:
            guard URL(string: baseURL)?.scheme?.hasPrefix("http") == true else { return "Enter the endpoint's base URL, like http://127.0.0.1:11434/v1." }
            guard !apiModel.isEmpty else { return "Enter the model name at that endpoint." }
        }
        if way != .cli, !saveKey(key, for: way) { return "The Keychain did not take the key." }
        for other in Way.allCases where other != way { deleteKey(for: other) }
        save { st in
            st.connect.provider = way.rawValue
            if way == .openai { st.connect.baseURL = baseURL; st.connect.apiModel = apiModel }
        }
        handOver()
        return nil
    }

    /// Turns every model switch off, removes the keys and tells the engine to forget them.
    static func disconnect(save: ((inout Settings) -> Void) -> Void) {
        for way in Way.allCases { deleteKey(for: way) }
        save { st in
            st.connect.provider = ""
            st.rework = false; st.callNotes = false; st.voiceClaude = false; st.entityClassify = false; st.pauseRewrite = false
        }
        Engine.shared.post("/model-key", ["provider": ""], timeout: 3)
    }
}

/// The top of Settings: local by default, one main button; connected, which way and Disconnect.
struct ConnectSection: View {
    @ObservedObject var m: WindowModel
    @State private var open = false
    @State private var way: Connect.Way = .cli
    @State private var key = ""
    @State private var baseURL = ""
    @State private var apiModel = ""
    @State private var status = ""

    var body: some View {
        let c = m.settings.connect
        VStack(alignment: .leading, spacing: 8) {
            Text("Models outside this Mac").font(NativeFont.display(13)).foregroundStyle(UIInk.muted)
            if c.connected, let w = Connect.Way(rawValue: c.provider) {
                Text("Connected: \(w.title). Each switch marked with a cloud sends text only when you turn it on.")
                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                if w == .anthropic {
                    HStack {
                        TextField("Fast model", text: Binding(get: { c.fastModel }, set: { v in m.save { $0.connect.fastModel = v } }))
                        TextField("Careful model", text: Binding(get: { c.carefulModel }, set: { v in m.save { $0.connect.carefulModel = v } }))
                    }.textFieldStyle(.roundedBorder).font(NativeFont.mono(12))
                }
                Button("Disconnect") { Connect.disconnect(save: m.save); status = "Disconnected. Drafter is local only." }
                    .disabled(m.preview)
            } else {
                Text("Drafter works fully on this Mac. Connect a model to let the switches marked with a cloud send text to it.")
                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                if !open {
                    Button("Connect a model") { open = true }.keyboardShortcut(.defaultAction).disabled(m.preview)
                } else {
                    SwiftUI.Picker("How", selection: $way) {
                        ForEach(Connect.Way.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                    if way == .openai {
                        TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                        TextField("Model name", text: $apiModel).textFieldStyle(.roundedBorder)
                    }
                    if way != .cli { SecureField("API key (kept in the Keychain)", text: $key).textFieldStyle(.roundedBorder) }
                    HStack {
                        Button("Connect") {
                            if let e = Connect.connect(way, key: key, baseURL: baseURL, apiModel: apiModel, save: m.save) { status = e }
                            else { status = "Connected. Turn on the switches you want."; key = ""; open = false }
                        }.keyboardShortcut(.defaultAction)
                        Button("Cancel") { open = false; key = "" }
                    }
                }
            }
            if !status.isEmpty { Text(status).font(NativeFont.text(12)).foregroundStyle(UIInk.muted) }
        }
        .padding(.top, 14).overlay(alignment: .top) { Rectangle().fill(UIInk.line).frame(height: 1) }
    }
}
