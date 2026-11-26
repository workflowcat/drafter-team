// Audio ducking (17 November 2026): while a push-to-talk take records, the Mac's other sounds (music, video) go down
// to 30% of their volume and come back after it. CoreAudio on the default output device, on its own queue so the press
// never waits for it. When: app/DuckRules.swift (pure). Never during a long note or a call.
// Crash safety: the volume to put back waits in UserDefaults ("duckRestore") while ducked; the next launch puts it back.
import Foundation
import CoreAudio

enum Duck {
    private static let queue = DispatchQueue(label: "drafter.duck", qos: .userInitiated)
    private static let key = "duckRestore"

    /// The ducked device and, per volume element, the volume before and the volume Drafter set. On `queue` only.
    private struct Ducked { var device: AudioDeviceID; var elements: [UInt32]; var before: [Float]; var set: [Float] }
    private static var ducked: Ducked?

    /// Main thread, once the take's microphone is open. Reads the settings and the call state here, sets on `queue`.
    static func begin(long: Bool, call: Bool) {
        let on = Drafter.shared.settings.duckAudio
        guard on, !long, !call else { return }   // the common "no" costs no CoreAudio call
        let callGoing = !CallWatch.micPids.isEmpty || CallWatch.offeredFor != nil || (Offer.active && Offer.app != nil)
        queue.async {
            guard ducked == nil, let dev = defaultOutput() else { return }
            let els = elements(dev)
            let vols = els.compactMap { volume(dev, $0) }
            let m = DuckRules.Moment(on: on, long: long, call: call, callGoing: callGoing, muted: muted(dev),
                                     volume: vols.count == els.count ? vols.max() : nil)
            guard DuckRules.shouldDuck(m), let top = m.volume else { return }
            let set = vols.map(DuckRules.target)
            // saved before the change: a crash between the two still finds it
            UserDefaults.standard.set(["before": vols.map(Double.init), "set": set.map(Double.init), "elements": els.map(Int.init)], forKey: key)
            for (e, v) in zip(els, set) { setVolume(dev, e, v) }
            ducked = Ducked(device: dev, elements: els, before: vols, set: set)
            log(DuckRules.duckLine(from: top, to: DuckRules.target(top)))
        }
    }

    /// Every way a take's microphone stops (end, cancel, Esc, engine failure). Nothing ducked: nothing happens.
    static func end(wait: Bool = false) {
        let work = {
            guard let d = ducked else { return }
            ducked = nil
            put(back: d.before, set: d.set, elements: d.elements, device: d.device, when: "")
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// At launch: a volume a crash or a kill left ducked goes back once (if the user did not change it since).
    static func launch() {
        queue.async {
            guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return }
            UserDefaults.standard.removeObject(forKey: key)
            let before = (saved["before"] as? [Double] ?? []).map(Float.init)
            let set = (saved["set"] as? [Double] ?? []).map(Float.init)
            let els = (saved["elements"] as? [Int] ?? []).map(UInt32.init)
            guard !before.isEmpty, before.count == els.count, let dev = defaultOutput() else { return }
            put(back: before, set: set.count == els.count ? set : [], elements: els, device: dev, when: " at launch")
        }
    }

    /// On `queue`: the old volume back when the volume is still what Drafter set; the saved copy goes either way.
    private static func put(back before: [Float], set: [Float], elements els: [UInt32], device dev: AudioDeviceID, when: String) {
        UserDefaults.standard.removeObject(forKey: key)
        let now = els.map { volume(dev, $0) }
        let current = now.contains(where: { $0 == nil }) ? nil : now.compactMap { $0 }.max()
        guard DuckRules.shouldRestore(current: current, set: set.max()) else {
            log("duck left: volume changed" + when); return
        }
        for (e, v) in zip(els, before) { setVolume(dev, e, v) }
        log(DuckRules.restoreLine(before.max() ?? 0) + when)
    }

    // MARK: CoreAudio

    private static func address(_ sel: AudioObjectPropertySelector, _ el: UInt32 = kAudioObjectPropertyElementMain,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static func settable(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ el: UInt32) -> Bool {
        var a = address(sel, el)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &a, &ok) == noErr && ok.boolValue
    }

    /// The main element when it has a volume, else channels 1 and 2 (many USB and built-in devices).
    private static func elements(_ dev: AudioDeviceID) -> [UInt32] {
        if settable(dev, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { settable(dev, kAudioDevicePropertyVolumeScalar, $0) }
    }

    private static func volume(_ dev: AudioDeviceID, _ el: UInt32) -> Float? {
        var a = address(kAudioDevicePropertyVolumeScalar, el)
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setVolume(_ dev: AudioDeviceID, _ el: UInt32, _ v: Float) {
        var a = address(kAudioDevicePropertyVolumeScalar, el)
        var x = Float32(max(0, min(1, v)))
        _ = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }

    /// Muted on the main element, else on channel 1.
    private static func muted(_ dev: AudioDeviceID) -> Bool {
        for el in [kAudioObjectPropertyElementMain, 1] {
            var a = address(kAudioDevicePropertyMute, el)
            guard AudioObjectHasProperty(dev, &a) else { continue }
            var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m) == noErr { return m != 0 }
        }
        return false
    }
}
