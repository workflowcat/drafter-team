// Recordings as notes (2026-10-30, Andrii: "more similar to Granola: the text, search all of the conversation for a
// quick overview, quickly send info to the agents"). Since the look round "Tape" (14 November 2026) every call and long
// note is a block on the tape (TapeWindow.swift), found by the tape's one search; Return opens it as a page here: the
// recording as a document (title, people, summary,
// to-dos, then the conversation with times and the screenshots where they were taken). "For agent" puts the line that
// points an agent at it on the clipboard; on a search it copies the matching lines of every recording found.
import AppKit
import SwiftUI
import AVFoundation
import ObjectiveC

/// Per-window storage without changing Window.swift, which owns the window shell.
private final class CallPlaybackState {
    var noteDrafts: [String: CallStudioNoteDraft] = [:]
    var rate: Float = 1
    var video: AVPlayer?
    var videoID: String?
    var videoDuration = 0.0
    var timeObserver: Any?
    var rateObserver: NSKeyValueObservation?
    var jumpObserver: NSObjectProtocol?
    var seeking = false
    var scrubbing = false
    var seekGeneration = 0
    var requestedVideoTime = 0.0
    var audioMaster = false
    var generation = 0
    func clearVideo() {
        rateObserver = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver); self.jumpObserver = nil }
        if let timeObserver { video?.removeTimeObserver(timeObserver) }
        timeObserver = nil; video?.pause(); video = nil; videoID = nil; videoDuration = 0
        scrubbing = false; seeking = false; seekGeneration += 1; requestedVideoTime = 0; audioMaster = false
    }
    deinit { clearVideo() }
}

private var callPlaybackKey: UInt8 = 0

extension WindowModel {
    private var callPlayback: CallPlaybackState {
        if let state = objc_getAssociatedObject(self, &callPlaybackKey) as? CallPlaybackState { return state }
        let state = CallPlaybackState()
        objc_setAssociatedObject(self, &callPlaybackKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
    var playbackRate: Float {
        get { callPlayback.rate }
        set {
            guard CallStudioRules.playbackRates.contains(newValue), newValue != callPlayback.rate else { return }
            objectWillChange.send(); callPlayback.rate = newValue
            players.forEach { $0.enableRate = true; $0.rate = newValue }
            if let video = callPlayback.video, video.rate > 0 { video.rate = newValue }
        }
    }
    var studioVideo: AVPlayer? { callPlayback.video }
    var studioVideoDuration: Double { callPlayback.videoDuration }

    /// Native video controls and the master timeline share the same clock. When separate
    /// microphone tracks exist, mute the video's embedded audio to avoid playing it twice.
    func prepareStudioVideo(_ d: CallDoc, url: URL) {
        let state = callPlayback
        guard state.videoID != d.id else { return }
        stopPlaying(); state.clearVideo()
        let asset = AVURLAsset(url: url)
        let video = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        video.isMuted = ["me.wav", "them.wav"].contains { FileManager.default.fileExists(atPath: d.dir.appendingPathComponent($0).path) }
        state.audioMaster = video.isMuted
        state.video = video; state.videoID = d.id
        // A paused player need not emit a time tick, so load its duration independently.
        Task { @MainActor [weak self, weak video] in
            guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return }
            guard let self, let video, self.callPlayback.video === video else { return }
            self.objectWillChange.send(); self.callPlayback.videoDuration = duration.seconds
            let target = self.players.max(by: { $0.duration < $1.duration })?.currentTime ?? self.callPlayback.requestedVideoTime
            self.seekStudioVideo(target, resume: self.playing == d.id)
        }
        state.timeObserver = video.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak video] time in
            guard let self, let video, self.callPlayback.video === video, !self.callPlayback.seeking,
                  !self.callPlayback.scrubbing, time.seconds.isFinite else { return }
            if let duration = video.currentItem?.duration.seconds, duration.isFinite, duration > 0, duration != self.callPlayback.videoDuration {
                self.objectWillChange.send(); self.callPlayback.videoDuration = duration
            }
            let second = max(0, time.seconds)
            // Separate audio owns the clock, including the stretch after video ends.
            if !self.callPlayback.audioMaster {
                self.playhead = second
            }
            if self.playing == d.id, !self.callPlayback.audioMaster {
                self.playTurn = CallTimelineRules.nearestTurnID(at: second, turns: d.turns.map { ($0.id, $0.start) })
            }
        }
        state.jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification,
            object: video.currentItem, queue: .main) { [weak self, weak video] _ in
                guard let self, let video, self.callPlayback.video === video, !self.callPlayback.seeking,
                      !self.callPlayback.scrubbing else { return }
                let second = video.currentTime().seconds
                guard second.isFinite else { return }
                let requested = ScreenVideoRules.clampedVideoTime(target: self.callPlayback.requestedVideoTime,
                                                                  videoDuration: self.studioVideoDuration)
                guard abs(second - requested) > 0.05,
                      !CallStudioRules.videoEnded(at: second, duration: self.studioVideoDuration) else { return }
                self.playhead = second
                // Only an explicit native seek moves audio; ordinary video ticks and end-of-file never do.
                for player in self.players {
                    player.currentTime = min(second, player.duration)
                    if second < player.duration, self.playing == d.id { player.play() }
                }
            }
        state.rateObserver = video.observe(\.rate, options: [.new]) { [weak self, weak video] _, _ in
            DispatchQueue.main.async {
                guard let self, let video, self.callPlayback.video === video,
                      !self.callPlayback.seeking, !self.callPlayback.scrubbing else { return }
                if video.rate == 0 {
                    if !self.players.isEmpty, CallStudioRules.videoEnded(at: video.currentTime().seconds + 0.1,
                                                                 duration: self.studioVideoDuration) { return }
                    if self.playing == d.id { self.stopPlaying() }
                } else if self.playing != d.id {
                    self.play(d, from: video.currentTime().seconds)
                } else {
                    self.players.forEach { $0.rate = video.rate }
                }
            }
        }
        objectWillChange.send()
    }

    func releaseStudioVideo(_ id: String) {
        guard callPlayback.videoID == id else { return }
        stopPlaying(); callPlayback.clearVideo()
    }

    func previewStudioSeek(_ second: Double) {
        seekStudioVideo(second, resume: false)
    }

    /// Seek the existing players during navigation; silence skips must not reopen audio files.
    func seekStudioPlayback(_ d: CallDoc, to second: Double) {
        guard second.isFinite, second >= 0, playing == d.id else { return }
        // The clock hands off to video after the audio ends. Seeking back must restore those audio tracks.
        if players.isEmpty, callPlayback.video?.isMuted == true { play(d, from: second); return }
        for player in players {
            player.currentTime = min(second, player.duration)
            if second < player.duration { player.play() }
        }
        if callPlayback.videoID == d.id { seekStudioVideo(second, resume: true) }
        playTurn = CallTimelineRules.nearestTurnID(at: second, turns: d.turns.map { ($0.id, $0.start) })
        playhead = second
    }

    func studioNotes(_ d: CallDoc) -> CallStudioNoteDraft {
        if let draft = callPlayback.noteDrafts[d.id] { return draft }
        let draft = CallStudioNoteDraft(d)
        callPlayback.noteDrafts[d.id] = draft
        return draft
    }

    func copyShareBrief(_ d: CallDoc, duration: Double, chapters: [CallChapter]) {
        callPlayback.noteDrafts[d.id]?.refresh(d)
        let mine = callPlayback.noteDrafts[d.id]?.text ?? d.mine
        History.copy(CallChapterRules.shareBrief(title: d.title, dateLabel: CallDoc.day.string(from: d.started),
            duration: duration, people: d.people, myNotes: mine, summary: d.points, todos: d.todos, chapters: chapters,
            links: CallChapterRules.extractedURLs(from: d.turns.map(\.text))))
        status = "Share brief copied"
    }

    @discardableResult
    func beginStudioScrub() -> Bool {
        let state = callPlayback
        let wasPlayingVideo = (state.video?.rate ?? 0) > 0
        state.scrubbing = true; state.seeking = true; state.seekGeneration += 1
        state.video?.pause(); players.forEach { $0.pause() }
        return wasPlayingVideo
    }

    func endStudioScrub() {
        callPlayback.scrubbing = false
        // The final seek (or play) owns clearing `seeking`; stale preview completions cannot resume it.
    }

    private func seekStudioVideo(_ second: Double, resume: Bool) {
        let state = callPlayback
        guard let video = state.video, second.isFinite else { return }
        state.requestedVideoTime = second
        let duration = state.videoDuration
        let target = ScreenVideoRules.clampedVideoTime(target: second, videoDuration: duration)
        state.seekGeneration += 1
        let generation = state.seekGeneration
        state.seeking = true; video.pause()
        video.currentItem?.cancelPendingSeeks()
        video.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak video] finished in
            DispatchQueue.main.async {
                guard let self, let video, state.video === video, state.seekGeneration == generation else { return }
                guard !state.scrubbing else { return }
                // An audio clock never waits for this completion, even if video cannot seek or decode.
                if finished, resume, self.playing == state.videoID,
                   !CallStudioRules.videoEnded(at: second, duration: duration) {
                    video.playImmediately(atRate: self.playbackRate)
                }
                state.seeking = false
            }
        }
    }
    /// The recordings, read off the main thread (speed round: every open and every tick read them all on it).
    func loadDocs() {
        DispatchQueue.global(qos: .userInitiated).async {
            let d = WindowModel.readDocs()
            DispatchQueue.main.async { self.applyDocs(d) }
        }
    }

    /// Every recording as a document (any thread).
    static func readDocs(root: URL = Spool.root, notes folder: URL = Home.data.appendingPathComponent("notes")) -> [CallDoc] {
        let notes = CallDoc.notesIndex(folder)
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return dirs.map { CallDoc.load($0, notes: notes) }
            .filter { $0.mergedInto == nil }   // combined into another recording: that one shows (17 November 2026)
            .filter { !$0.turns.isEmpty || $0.live || $0.secs >= 20 }   // not a few seconds of silence
    }

    /// New recordings in; the journal is built again only when they changed (the 3 s and 30 s ticks read them all
    /// and rebuilt the whole journal each time, even with nothing new) or `rebuild` says so.
    func applyDocs(_ list: [CallDoc], rebuild: Bool = false) {
        let changed = list != docs
        // a live recording grows on every read: the journal is built again for it at most every 30 s
        // (RecordPaceRules.rebuild; 17 November 2026, the 3 s tick rebuilt the whole journal during a call)
        let old = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let again = rebuild || changed && RecordPaceRules.rebuild(docs: list.map { RecordPaceRules.Doc(id: $0.id, live: $0.live, same: old[$0.id] == $0) },
                                                       oldIds: docs.map(\.id), sinceLive: Date().timeIntervalSince(WindowModel.liveBuiltAt), forced: rebuild)
        if changed { docs = list }
        if changed, let d = doc { let n = docs.first { $0.id == d.id }; if n != d { doc = n } }
        // Read again is under way until a transcript newer than the click is written (an hour at most)
        for (id, since) in rereading {
            let t = (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: id).appendingPathComponent("transcript.txt").path)[.modificationDate] as? Date) ?? .distantPast
            if t > since || Date().timeIntervalSince(since) > 3600 { rereading[id] = nil }
        }
        if again { WindowModel.liveBuiltAt = Date(); rebuildTape() }
    }
    /// When the journal was last built with a live recording in it (applyDocs).
    static var liveBuiltAt = Date.distantPast

    /// brief.md for a recording that has none yet (no screenshots, or recorded before briefs existed).
    func ensureBrief(_ d: CallDoc) {
        let url = d.dir.appendingPathComponent("brief.md")
        guard !d.live, !FileManager.default.fileExists(atPath: url.path), !d.turns.isEmpty else { return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        Brief.write(dir: d.dir, rows: d.briefRows, shots: d.shots, meta: meta, minutes: d.secs / 60)
    }

    func sendToAgent(_ d: CallDoc) {
        if !preview { ensureBrief(d) }
        History.copy(d.handoff())
        status = "On the clipboard for an agent: «\(d.title)»" + (d.shots.isEmpty ? "" : " with \(d.shots.count) screenshots") + " · ⌘V into Claude or Codex"
    }

    func sendCallToObsidian(_ d: CallDoc) {
        let vault = settings.obsidianVault
        guard !vault.isEmpty else { status = "Set an Obsidian vault in Settings › Advanced"; return }
        if preview { status = "Sample export to Obsidian"; return }
        let notes = studioNotes(d).text
        let summary = d.points.map { "- " + $0 }.joined(separator: "\n")
        let entities = d.project.isEmpty ? [] : [d.project]
        let md = ObsidianExportRules.formatCallNote(
            title: d.title,
            date: d.started,
            people: d.people,
            entities: entities,
            summary: summary,
            todos: d.todos,
            notes: notes
        )
        let started = d.started, title = d.title
        status = "Saving to Obsidian…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            if let target = ObsidianExportRules.targetURL(vaultPath: vault, date: started, title: title) {
                result = ObsidianExportRules.writeAtomically(content: md, to: target)
            } else {
                result = .failure(ObsidianExportRules.ExportError.unsafePath)
            }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let url):
                    self?.status = "Saved to Obsidian · \(url.lastPathComponent)"
                    Engine.shared.post("/sources/run", ["name": "obsidian"])
                case .failure(let err):
                    self?.status = "Obsidian export failed: \(err.localizedDescription)"
                }
            }
        }
    }

    func stopRecording() {
        guard !preview else { return }
        Talk.shared.stopRecording("the window")
        status = "Stopped · reading both sides, the note follows in a few minutes"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.loadDocs() }
    }

    // MARK: editing a recording's details, its speakers and people (17 November 2026)

    static var bookURL: URL { Home.data.appendingPathComponent("speakers.json") }

    func saveDetails(_ d: CallDoc, title: String, app: String, place: String, project: String, details: String) {
        guard !preview else { return }
        let own = title.trimmingCharacters(in: .whitespaces)
        do {
            try CallDoc.saveMeta(d.dir, ["title": own == d.event ? "" : own, "app": app, "place": place, "project": project, "details": details])
            log("recording: details edited in \(d.dir.lastPathComponent)")
            status = "Saved · «\(own.isEmpty ? d.title : own)»"
        } catch { status = "Could not save the details: \(error.localizedDescription)" }
        loadDocs()
    }

    /// Names a speaker label for the whole recording (every line of it, the copies and the brief); the person goes into
    /// the people book so the next recordings offer them.
    func setSpeaker(_ d: CallDoc, _ label: String, _ person: String) {
        guard !preview else { return }
        var map = d.speakers
        map[label] = person.isEmpty ? nil : person
        try? CallDoc.saveMeta(d.dir, ["speakers": map])
        if !person.isEmpty { var b = PeopleBook.load(WindowModel.bookURL); b.add(person); try? b.save(WindowModel.bookURL) }
        log("recording: a speaker named in \(d.dir.lastPathComponent)")
        status = person.isEmpty ? "Speaker name taken off" : "«\(CallDoc.who(label))» is \(person) in this recording"
        loadDocs()
    }

    func setForms(_ person: String, _ text: String) {
        guard !preview else { return }
        var b = PeopleBook.load(WindowModel.bookURL)
        b.set(person, forms: text)
        try? b.save(WindowModel.bookURL)
        status = "Name forms for \(person): \(b.people[person]?.count ?? 0)"
    }

    func suggestions(_ d: CallDoc) -> [String] {
        let book = PeopleBook.load(WindowModel.bookURL)
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any]
        let ev = ((meta?["event"] as? [String: Any])?["people"] as? [String]) ?? []
        return PeopleBook.suggestions(event: ev + d.people, named: Array(d.speakers.values), known: Array(book.people.keys), me: CallDoc.me)
    }

    // MARK: combining recordings and voice takes of one talk (MergeRules)

    static func source(_ d: CallDoc) -> MergeSource {
        let me = d.dir.appendingPathComponent("me.wav"), them = d.dir.appendingPathComponent("them.wav")
        return MergeSource(id: d.id, kind: .recording, start: d.started.timeIntervalSince1970, secs: d.secs, call: d.call, app: d.app,
                           // lines.json keeps each line's track and end (speakers.py needs them again after the merge)
                           rows: (try? Data(contentsOf: d.dir.appendingPathComponent("lines.json"))).flatMap(MergeRules.rows(lines:))
                               ?? d.turns.map { MergeRow(who: $0.who, start: $0.start ?? 0, text: $0.text) },
                           me: FileManager.default.fileExists(atPath: me.path) ? me : nil,
                           them: FileManager.default.fileExists(atPath: them.path) ? them : nil)
    }

    /// What could join this recording (any thread): other recordings and voice takes overlapping it or within 10 min.
    static func mergeGroup(_ d: CallDoc, docs: [CallDoc], takes: URL = History.takesFile) -> [MergeSource] {
        guard !d.live, d.secs > 0 else { return [] }
        let target = source(d)
        let used = Set(docs.flatMap(\.merged) + d.merged)
        let lo = target.start - 3 * 3600, hi = target.end + 3 * 3600
        var all = docs.filter { $0.id != d.id && !$0.live && $0.mergedInto == nil && $0.secs > 0 && !used.contains($0.id) }.map(source)
        if let text = try? String(contentsOf: takes, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let t = row["t"] as? Double, t > lo, t < hi, let src = MergeRules.take(row),
                      !src.rows.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }), !used.contains(src.id) else { continue }
                all.append(src)
            }
        }
        return MergeRules.group(target, among: all)
    }

    func combine(_ d: CallDoc, _ others: [MergeSource]) {
        guard !preview, !others.isEmpty else { return }
        status = "Combining \(others.count + 1) into one recording…"
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let sources = [WindowModel.source(d)] + others
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var extra: [String: Any] = [:]
                if let ev = meta["event"] { extra["event"] = ev }
                for k in ["speakers", "place", "project", "details", "title"] { if let v = meta[k] { extra[k] = v } }
                let dir = try MergeRules.build(sources, root: Spool.root, extraMeta: extra)
                let tl = MergeRules.timeline(sources), call = sources.contains { $0.call }
                let text = MergeRules.transcript(tl.rows, call: call)
                log("recording: combined \(sources.count) (\(others.filter { $0.kind == .take }.count) takes) into \(dir.lastPathComponent)")
                DispatchQueue.main.async {
                    let note = { (text: String) in
                        var body: [String: Any] = ["text": text, "audio": dir.path, "call": call]
                        if let ev = meta["event"] { body["event"] = ev }
                        Engine.shared.post("/note", body, timeout: 120) { _ in self.loadDocs() }   // one summary for all of it
                    }
                    // a call: each line's voice placed again over the combined sound (the takes were "unknown"), then the note
                    if call {
                        Speakers.run(dir) { ok in
                            note(ok ? ((try? String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? text) : text)
                            self.loadDocs()
                        }
                    } else { note(text) }
                    self.status = "Combined into one recording · the summary follows"
                    self.loadDocs()
                    let notes = CallDoc.notesIndex(Home.data.appendingPathComponent("notes"))
                    self.openDoc(CallDoc.load(dir, notes: notes))
                }
            } catch {
                DispatchQueue.main.async { self.status = "Could not combine: \(error.localizedDescription)" }
            }
        }
    }

    func copyNotes(_ d: CallDoc) { History.copy(d.notesMarkdown()); status = "On the clipboard · the notes of «\(d.title)»" }

    // the transcript in three forms (17 November 2026, file transcription): plain text, SRT subtitles, Markdown
    enum CopyForm: String, CaseIterable { case text = "Text", srt = "SRT subtitles", markdown = "Markdown" }
    func formatted(_ d: CallDoc, _ f: CopyForm) -> String {
        let cues = d.turns.map { CueLine(who: d.name($0.who), start: $0.start, text: $0.text) }
        switch f {
        case .text: return TranscriptFormats.text(cues)
        case .srt: return TranscriptFormats.srt(cues, total: d.secs > 0 ? Double(d.secs) : nil)
        case .markdown:
            let meta = "\(d.kind) · \(CallDoc.day.string(from: d.started)) · \(CallDoc.length(d.secs))" + (d.file.isEmpty ? "" : " · \(d.file)")
                + (d.people.isEmpty ? "" : " · with \(d.people.joined(separator: ", "))")
            return TranscriptFormats.markdown(title: d.title, meta: meta, summary: d.points, todos: d.todos, lines: cues)
        }
    }
    func copyAs(_ d: CallDoc, _ f: CopyForm) { History.copy(formatted(d, f)); status = "On the clipboard · the transcript as \(f.rawValue)" }
    /// Subtitles saved beside the source: an .srt named after the recording.
    func saveSubtitles(_ d: CallDoc) {
        let p = NSSavePanel()
        p.nameFieldStringValue = (d.file.isEmpty ? d.title : (d.file as NSString).deletingPathExtension) + ".srt"
        p.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try formatted(d, .srt).write(to: url, atomically: true, encoding: .utf8); status = "Saved · \(url.lastPathComponent)" }
        catch { status = "Not saved: \(error.localizedDescription)" }
    }

    // MARK: playing both sides from a line

    func play(_ d: CallDoc, from t: Double) {
        if let id = callPlayback.videoID, id != d.id { releaseStudioVideo(id) }
        if let url = CallStudioRules.detectVideoFile(in: d.dir) { prepareStudioVideo(d, url: url) }
        stopPlaying()
        let files = ["me.wav", "them.wav"].map { d.dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let ps = files.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        let video = callPlayback.videoID == d.id ? callPlayback.video : nil
        video?.isMuted = !ps.isEmpty
        callPlayback.audioMaster = !ps.isEmpty
        guard !ps.isEmpty || video != nil else { status = "This recording has no audio to play"; return }
        let second = t.isFinite ? max(0, t) : 0
        for p in ps { p.enableRate = true; p.rate = playbackRate; p.currentTime = min(second, p.duration); p.prepareToPlay() }
        players = ps; playing = d.id; playhead = second
        let starts = d.turns.map { ($0.id, $0.start ?? .infinity) }
        func turn(_ at: Double) -> Int? { starts.last { $0.1 <= at }?.0 }
        playTurn = turn(second)
        if video != nil { seekStudioVideo(second, resume: true) }
        guard !ps.isEmpty else { return }
        // Audio starts independently: a short, missing or broken video must never stall the call.
        let at = ps[0].deviceCurrentTime + 0.05
        ps.filter { second < $0.duration }.forEach { $0.play(atTime: at) }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, !self.callPlayback.scrubbing,
                  let p = self.players.max(by: { $0.duration < $1.duration }) else { return }
            if !self.players.contains(where: { $0.isPlaying }) {
                self.playhead = p.duration
                if self.studioVideoDuration > p.duration, let video = self.studioVideo {
                    // Imported movies can outlast separate audio. Hand the remaining timeline back to video.
                    self.players = []; self.playTimer?.invalidate(); self.playTimer = nil
                    self.callPlayback.audioMaster = false
                    if !self.callPlayback.seeking { video.playImmediately(atRate: self.playbackRate) }
                } else { self.stopPlaying() }
                return
            }
            self.playhead = p.currentTime
            if let video = self.studioVideo {
                if CallStudioRules.videoNeedsSync(audioTime: p.currentTime, videoTime: video.currentTime().seconds,
                    videoDuration: self.studioVideoDuration, scrubbing: self.callPlayback.scrubbing, seeking: self.callPlayback.seeking) {
                    self.seekStudioVideo(p.currentTime, resume: true)
                }
            }
            let now = turn(p.currentTime)
            if now != self.playTurn { self.playTurn = now }
        }
        playTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    func stopPlaying() {
        callPlayback.generation += 1; callPlayback.seekGeneration += 1
        callPlayback.seeking = false; callPlayback.scrubbing = false
        callPlayback.video?.pause(); callPlayback.video?.currentItem?.cancelPendingSeeks()
        players.forEach { $0.stop() }; players = []; playTimer?.invalidate(); playTimer = nil
        if playing != nil { playing = nil }; if playTurn != nil { playTurn = nil }
    }
}

private func stamp(_ t: Double) -> String { Brief.stamp(t) }

/// Search words marked in a text.
enum Mark {
    static func text(_ s: String, _ terms: [String]) -> AttributedString {
        var a = AttributedString(s)
        let low = s.lowercased()
        for t in terms where !t.isEmpty {
            var from = low.startIndex
            while let r = low.range(of: t, range: from..<low.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
                    a[lo..<hi].backgroundColor = Color(nsColor: Native.blue).opacity(0.22)
                    a[lo..<hi].foregroundColor = UIInk.ink
                }
                from = r.upperBound
            }
        }
        return a
    }
}

struct PersonEdit: Identifiable { let label: String; let person: String; let forms: Bool; var id: String { label + "|" + person + "|\(forms)" } }

/// The display transcript merges turns and loses their end times. Read the timing source once per revision.
private struct CallStudioSource: Hashable {
    let id: String
    let turns: [Turn]
    let duration: Double
    let live: Bool

    func loadTurns() -> [CallChapterTurn] {
        let fallback = turns.map { CallChapterTurn(start: $0.start, end: nil, who: $0.who, text: $0.text) }
        guard !live else { return fallback }
        let dir = URL(fileURLWithPath: id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("lines.json")) else { return fallback }
        let result = CallChapterRules.transcriptTurns(from: data)
        return result.isEmpty ? fallback : result
    }
}

/// Drafts survive pane and recording changes. A concurrent writer is never silently overwritten.
final class CallStudioNoteDraft: ObservableObject {
    @Published var text: String
    @Published private(set) var saved: String
    @Published private(set) var notice = ""
    private let url: URL
    private var diskText: String?
    private var source: String
    var changed: Bool { text != saved }

    init(_ d: CallDoc) {
        url = d.dir.appendingPathComponent("my-notes.md")
        diskText = try? String(contentsOf: url, encoding: .utf8)
        source = d.mine; text = diskText ?? d.mine; saved = diskText ?? d.mine
    }
    func refresh(_ d: CallDoc) {
        guard source != d.mine, !changed else { return }
        source = d.mine
        diskText = try? String(contentsOf: url, encoding: .utf8)
        text = diskText ?? d.mine; saved = text
    }
    @discardableResult func save() -> Bool {
        do {
            let current = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
            guard current == diskText else { notice = "Notes changed elsewhere. Your draft is kept. Copy it before reloading."; return false }
            try text.write(to: url, atomically: true, encoding: .utf8)
            diskText = text; saved = text; notice = "Notes saved"
            return true
        } catch { notice = "Could not save notes. Your draft is kept."; return false }
    }
}

struct DocView: View {
    @EnvironmentObject var m: WindowModel
    let doc: CallDoc
    init(d: CallDoc) { doc = d }
    var d: CallDoc { doc }
    @State private var group: [MergeSource] = []
    @State private var editing = false
    @State private var person: PersonEdit?
    @State private var jumpedTurn: Int?
    @State private var videoURL: URL?
    @State private var videoDocumentID: String?
    @State private var scrubTime: Double?
    @State private var playbackTime = 0.0
    @State private var followPlayhead = true
    @State private var speaker = "All"
    @State private var pane = "Transcript"
    @State private var chapterTurns: [CallChapterTurn] = []
    @State private var chapters: [CallChapter] = []
    private var second: Double { scrubTime ?? playbackTime }
    private var hasVisual: Bool { !d.shots.isEmpty || videoURL != nil }
    private var wide: Bool { m.width >= 960 && hasVisual }
    private var totalSecs: Double {
        let known = ([d.secs, videoURL == nil ? 0 : m.studioVideoDuration] + d.shots.map(\.t) + d.turns.compactMap(\.start)).filter { $0.isFinite && $0 > 0 }
        return max(1, known.max() ?? 0)
    }
    private var currentTurn: Int? { CallTimelineRules.nearestTurnID(at: second, turns: d.turns.map { ($0.id, $0.start) }) }
    private var studioSource: CallStudioSource {
        CallStudioSource(id: d.id, turns: d.turns, duration: totalSecs, live: d.live)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header.padding(.horizontal, 24).padding(.vertical, 16)
                if !group.isEmpty { mergeOffer.padding(.horizontal, 24).padding(.bottom, 12) }
                Rectangle().fill(UIInk.line).frame(height: 1)
                if wide { wideLayout(proxy) } else { narrowLayout(proxy) }
                if d.secs > 0 || !d.turns.isEmpty || !d.shots.isEmpty || videoURL != nil {
                    CallMasterTimeline(
                        live: m.live,
                        d: d,
                        second: second,
                        totalSecs: totalSecs,
                        chapters: chapters,
                        turns: chapterTurns,
                        scrubTime: $scrubTime,
                        seek: { seek($0, proxy, revealTranscript: false, startPlayback: false) },
                        togglePlay: { at in
                            if m.playing == d.id { m.stopPlaying(); playbackTime = m.live.playhead }
                            else { seek(at, proxy, revealTranscript: false, startPlayback: true) }
                        }
                    )
                }
            }
            .foregroundStyle(UIInk.ink).background(UIInk.paper)
            .task(id: studioSource) {
                let source = studioSource
                chapterTurns = []; chapters = []
                let result = await Task.detached(priority: .userInitiated) {
                    let turns = source.loadTurns()
                    return (turns, CallChapterRules.chapters(turns: turns, duration: source.duration))
                }.value
                guard !Task.isCancelled else { return }
                chapterTurns = result.0; chapters = result.1
            }
            .task(id: d.id) {
                if let videoDocumentID, videoDocumentID != d.id { m.releaseStudioVideo(videoDocumentID) }
                group = []; jumpedTurn = nil; scrubTime = nil; speaker = "All"; pane = "Transcript"
                playbackTime = m.playing == d.id ? m.live.playhead : (m.preview ? d.shots.first?.t ?? 0 : 0)
                videoURL = CallStudioRules.detectVideoFile(in: d.dir)
                videoDocumentID = videoURL == nil ? nil : d.id
                if let videoURL { m.prepareStudioVideo(d, url: videoURL) }
                if empty { m.loadWarnings(d) }
                findGroup()
                if let first = d.hits(CallDoc.terms(m.query)).first { proxy.scrollTo(first.id, anchor: .center) }
            }
            .onReceive(m.live.$playhead) { time in
                // CallMasterTimeline observes m.live directly for smooth clock/needle redraws;
                // only redraw the full Call Studio page when the active screenshot or spoken turn actually changes.
                guard scrubTime == nil, m.playing == d.id || videoURL != nil else { return }
                let shotTimes = d.shots.map(\.t)
                let oldShot = CallStudioRules.activeShotIndex(at: playbackTime, shotTimes: shotTimes)
                let newShot = CallStudioRules.activeShotIndex(at: time, shotTimes: shotTimes)
                let turnStarts = d.turns.map { ($0.id, $0.start) }
                let oldTurn = CallTimelineRules.nearestTurnID(at: playbackTime, turns: turnStarts)
                let newTurn = CallTimelineRules.nearestTurnID(at: time, turns: turnStarts)
                let endChanged = CallStudioRules.videoEnded(at: playbackTime, duration: m.studioVideoDuration)
                    != CallStudioRules.videoEnded(at: time, duration: m.studioVideoDuration)
                if oldShot != newShot || oldTurn != newTurn || endChanged { playbackTime = time }
            }
            .onChange(of: currentTurn) { _, turn in
                if followPlayhead, pane == "Transcript", let turn { proxy.scrollTo(turn, anchor: .center) }
            }
            .onChange(of: m.playing) { _, id in
                if id == nil, scrubTime == nil { playbackTime = m.live.playhead }
            }
            .onChange(of: m.query) { _, _ in
                if let first = d.hits(CallDoc.terms(m.query)).first {
                    pane = "Transcript"; speaker = "All"
                    DispatchQueue.main.async { proxy.scrollTo(first.id, anchor: .center) }
                }
            }
            .onDisappear { m.releaseStudioVideo(d.id) }
            .sheet(isPresented: $editing) { DetailsSheet(d: d).environmentObject(m) }
            .sheet(item: $person) { p in PersonSheet(d: d, edit: p).environmentObject(m) }
        }
    }

    private func wideLayout(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { g in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    CallVisualStage(d: d, videoURL: videoURL, second: second, seek: { seek($0, proxy) })
                        .padding(20)
                }.frame(width: g.size.width * 0.52)
                Rectangle().fill(UIInk.line).frame(width: 1)
                VStack(spacing: 0) {
                    SwiftUI.Picker("Recording pane", selection: $pane) {
                        Text("Transcript").tag("Transcript")
                        Text("Summary & To-dos").tag("Summary & To-dos")
                        Text("Notes").tag("Notes")
                    }.pickerStyle(.segmented).labelsHidden().padding(16)
                    if pane == "Transcript" { transcriptControls.padding(.horizontal, 16).padding(.bottom, 12) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if pane == "Transcript" {
                                if empty { why }
                                conversation(proxy)
                            } else if pane == "Summary & To-dos" { summary }
                            else { ownNotes(proxy) }
                        }.padding(.horizontal, 16).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private func narrowLayout(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if hasVisual { CallVisualStage(d: d, videoURL: videoURL, second: second, seek: { seek($0, proxy) }) }
                if empty { why }
                ownNotes(proxy)
                recordingDetails
                section(d.live ? "Live transcript" : "Transcript") {
                    transcriptControls
                    conversation(proxy)
                }
            }.padding(24).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seek(_ time: Double, _ proxy: ScrollViewProxy, revealTranscript: Bool = true, startPlayback: Bool = false) {
        let target = CallStudioRules.seekTime(fraction: time / totalSecs, totalSecs: totalSecs)
        playbackTime = target; scrubTime = nil; m.playhead = target
        if revealTranscript { pane = "Transcript"; speaker = "All" }
        jumpedTurn = CallTimelineRules.nearestTurnID(at: target, turns: d.turns.map { ($0.id, $0.start) })
        if revealTranscript || (followPlayhead && pane == "Transcript"), let jumpedTurn {
            DispatchQueue.main.async { proxy.scrollTo(jumpedTurn, anchor: .center) }
        }
        let shouldPlay = startPlayback || m.playing == d.id
        if shouldPlay {
            if m.playing == d.id { m.seekStudioPlayback(d, to: target) }
            else if d.hasAudio || videoURL != nil { m.play(d, from: target) }
            else { m.status = "This recording has no audio to play" }
        } else if videoURL != nil {
            m.previewStudioSeek(target)
        }
    }

    private var transcriptControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { speakerPick; Spacer(minLength: 0); followToggle }
            VStack(alignment: .leading, spacing: 8) {
                HStack { speakerPick; Spacer(minLength: 0); followToggle }
            }
        }
    }
    private var speakerPick: some View {
        SwiftUI.Picker("Speaker", selection: $speaker) {
            Text("All").tag("All"); Text("You").tag("You"); Text("Them").tag("Them")
        }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
    }
    private var followToggle: some View {
        Toggle("Follow playhead", isOn: $followPlayhead).toggleStyle(.checkbox).font(NativeFont.text(12)).fixedSize()
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !d.points.isEmpty { section("Summary") { ForEach(Array(d.points.enumerated()), id: \.offset) { _, p in bullet(p, CallDoc.terms(m.query)) } } }
            if !d.todos.isEmpty { section("To-dos") { ForEach(Array(d.todos.enumerated()), id: \.offset) { _, p in todo(p, CallDoc.terms(m.query)) } } }
            if d.points.isEmpty && d.todos.isEmpty { Text(d.live ? "Summary follows when recording ends." : "No summary yet").font(NativeFont.text(13)).foregroundStyle(UIInk.muted) }
            recordingDetails
        }
    }
    @ViewBuilder private var recordingDetails: some View {
        if !d.place.isEmpty || !d.project.isEmpty || !d.details.isEmpty || !d.merged.isEmpty {
            DisclosureGroup("Details") { facts.padding(.top, 8) }.font(NativeFont.text(13))
        }
        if d.labels.contains(where: { !CallStudioRules.isMe($0) }) { people }
    }
    private func ownNotes(_ proxy: ScrollViewProxy) -> some View {
        CallStudioNotes(d: d, turns: chapterTurns, draft: m.studioNotes(d), seek: { seek($0, proxy, revealTranscript: false) })
            .id(d.id)
    }

    /// A finished recording with no words: why, and the one thing that helps.
    var empty: Bool { d.turns.isEmpty && !d.live }
    var reading: Bool { m.rereading[d.id] != nil }

    var why: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(d.whyEmpty(warnings: m.warnings[d.id] ?? []).enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(w.problem ? UIInk.coral : UIInk.faint).frame(width: 6, height: 6).offset(y: -2)
                        .accessibilityHidden(true)
                    Text(w.text).font(NativeFont.text(14)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if d.hasAudio {
                HStack(spacing: 8) {
                    if reading {
                        ProgressView().controlSize(.small)
                        Text("Reading again…").font(NativeFont.text(13)).foregroundStyle(UIInk.muted)
                    } else {
                        Button { m.reread(Entry(id: d.id, when: d.started, app: d.app, text: "", audio: d.id)) } label: {
                            Label("Read again", systemImage: "arrow.clockwise")
                        }.buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: .command).help("Read both sides with today's reader (⌘R)")
                    }
                }.padding(.top, 6)
            }
        }
    }

    var forAgent: some View {
        Button { m.sendToAgent(d) } label: { Label { Text("For agent") } icon: { Glyph("external", size: 14) } }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Copy a line that points Claude or Codex at everything said\(d.shots.isEmpty ? "" : " and the screenshots") (⇧⌘A)")
            .disabled(d.turns.isEmpty)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(d.title).font(NativeFont.display(22)).textSelection(.enabled).lineLimit(2)
                Spacer(minLength: 8)
                Text([CallDoc.day.string(from: d.started), CallDoc.length(d.secs), d.app].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { peoplePills; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 10) { peoplePills; ScrollView(.horizontal, showsIndicators: false) { actions } }
            }
        }
    }
    private var peoplePills: some View {
        HStack(spacing: 6) {
            ForEach(d.people, id: \.self) { name in
                HStack(spacing: 4) { Glyph("user", size: 12); Text(name).lineLimit(1) }
                    .font(NativeFont.text(12)).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(UIInk.soft))
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button { m.copyShareBrief(d, duration: totalSecs, chapters: chapters) } label: {
                Label { Text("Share Brief").font(NativeFont.text(12, .semibold)) } icon: { Glyph("copy", size: 14) }
            }.help("Copy a brief with notes, actions, chapters and links")
            Button { m.sendCallToObsidian(d) } label: {
                Label { Text("Send to Obsidian") } icon: { Glyph("external", size: 14) }
            }
            .disabled(m.settings.obsidianVault.isEmpty || d.live)
            .help(m.settings.obsidianVault.isEmpty ? "Set an Obsidian vault in Settings › Advanced" : "Save a Markdown note into your Obsidian vault's Drafter folder")
            if !d.live {
                Button { editing = true } label: { Label { Text("Edit") } icon: { Glyph("edit", size: 14) } }
                if d.hasAudio, !empty {
                    Button { m.reread(Entry(id: d.id, when: d.started, app: d.app, text: "", audio: d.id)) } label: {
                        Label { Text(reading ? "Reading again…" : "Read again") } icon: { Glyph("refresh", size: 14) }
                    }.disabled(reading)
                }
            } else {
                Button("Stop recording") { m.stopRecording() }.tint(UIInk.coral)
            }
            forAgent
            Button { m.copyNotes(d) } label: { Label { Text("Copy notes") } icon: { Glyph("copy", size: 14) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            SwiftUI.Menu {
                SwiftUI.Menu("Copy transcript as") {
                    ForEach(WindowModel.CopyForm.allCases, id: \.self) { f in Button(f.rawValue) { m.copyAs(d, f) } }
                }.disabled(d.turns.isEmpty)
                Button("Save subtitles (.srt)…") { m.saveSubtitles(d) }.disabled(!d.timed)
                if !d.note.isEmpty { Button("Open the note file") { NSWorkspace.shared.open(URL(fileURLWithPath: d.note)) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d.dir]) }
            } label: { Label { Text("More") } icon: { Glyph("more", size: 14) } }
            .menuStyle(.borderlessButton).fixedSize()
        }.font(NativeFont.text(12)).buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    // MARK: details, people, combining (17 November 2026)

    private func findGroup() {
        guard !m.preview else { return }
        let doc = d, docs = m.docs
        DispatchQueue.global(qos: .utility).async {
            let g = WindowModel.mergeGroup(doc, docs: docs)
            DispatchQueue.main.async { if doc.id == d.id { group = g } }
        }
    }

    var mergeOffer: some View {
        let takes = group.filter { $0.kind == .take }.count, recs = group.count - takes
        let what = [recs > 0 ? "\(recs) recording\(recs == 1 ? "" : "s")" : nil, takes > 0 ? "\(takes) voice note\(takes == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " and ")
        return HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(UIInk.blue).accessibilityHidden(true)
            Text("\(what) from the same time").font(NativeFont.text(13.5))
            Spacer(minLength: 8)
            Button("Combine into one") { m.combine(d, group); group = [] }.buttonStyle(.borderedProminent)
                .help("One recording: one timeline, the words in time order, one summary. The originals are kept.")
            Button { group = [] } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Not now")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Native.corner(1)).fill(UIInk.soft))
    }

    private static let hour: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f }()

    var facts: some View {
        let len = { (s: Double) in CallDoc.length(s) }
        let sides = d.call ? "You \(len(d.meSecs)) · them \(len(d.themSecs))" : len(d.meSecs)
        var when = ""
        if let a = d.eventStart, let b = d.eventEnd {
            when = DocView.hour.string(from: Date(timeIntervalSince1970: a)) + "-" + DocView.hour.string(from: Date(timeIntervalSince1970: b))
        }
        let ev = [d.event == d.title ? "" : d.event, when, d.calendar].filter { !$0.isEmpty }.joined(separator: " · ")
        let lang = d.language.flatMap { Locale(identifier: "en_GB").localizedString(forLanguageCode: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            if !ev.isEmpty { fact("calendar", ev, "Calendar event") }
            if !d.app.isEmpty { fact(d.call ? "video" : "app", d.app, "Call app") }
            if d.secs >= 1 { fact("waveform", sides, "Length") }
            if let lang { fact("character.bubble", lang, "Language") }
            if !d.place.isEmpty { fact("mappin.and.ellipse", d.place, "Place") }
            if !d.project.isEmpty { fact("folder", d.project, "Project") }
            if !d.details.isEmpty { fact("text.alignleft", d.details, "Notes") }
            if !d.merged.isEmpty { fact("rectangle.stack", "Combined from \(d.merged.count)", "Combined") }
        }
    }

    func fact(_ glyph: String, _ text: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: glyph).font(.system(size: 12)).foregroundStyle(UIInk.muted).frame(width: 16).accessibilityHidden(true)
            Text(text).font(NativeFont.text(13.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine).accessibilityLabel(what + ": " + text)
    }

    var people: some View {
        let names = m.preview ? d.people : m.suggestions(d)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(d.labels.filter { $0 != "Я" }, id: \.self) { label in
                HStack(spacing: 8) {
                    Circle().fill(label == "Я" ? UIInk.blue : UIInk.coral).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(CallDoc.who(label)).font(NativeFont.mono(11)).foregroundStyle(UIInk.muted).frame(minWidth: 44, alignment: .leading)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(UIInk.faint).accessibilityHidden(true)
                    SwiftUI.Menu {
                        ForEach(names, id: \.self) { n in Button(n) { m.setSpeaker(d, label, n) } }
                        if !names.isEmpty { Divider() }
                        Button("Someone else…") { person = PersonEdit(label: label, person: "", forms: false) }
                        if let p = d.speakers[label] {
                            Button("Name forms of \(p)…") { person = PersonEdit(label: label, person: p, forms: true) }
                            Button("Take the name off") { m.setSpeaker(d, label, "") }
                        }
                    } label: {
                        Text(d.speakers[label] ?? (label == "Я" ? "You" : "Name this speaker")).font(NativeFont.text(13.5))
                    }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Speaker \(CallDoc.who(label)): \(d.speakers[label] ?? "not named")")
                }
            }
        }
    }

    func section<C: View>(_ title: String, side: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(NativeFont.display(13)).foregroundStyle(UIInk.muted)
                Spacer(minLength: 8)
                if let side { side }
            }
            content()
        }
    }

    func bullet(_ s: String, _ terms: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(UIInk.ink).frame(width: 5, height: 5).offset(y: -3)
            Text(Mark.text(s, terms)).font(NativeFont.text(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    func todo(_ s: String, _ terms: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().strokeBorder(UIInk.muted, lineWidth: 1).frame(width: 11, height: 11).offset(y: 1)
            Text(Mark.text(s, terms)).font(NativeFont.text(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func conversation(_ proxy: ScrollViewProxy) -> some View {
        let terms = CallDoc.terms(m.query)
        let hits = Set(d.hits(terms).map(\.id))
        let activeTurn = currentTurn
        let turns = d.turns.filter { speaker == "All" || (speaker == "You" ? CallStudioRules.isMe($0.who) : !CallStudioRules.isMe($0.who)) }
        return LazyVStack(alignment: .leading, spacing: 8) {
            if turns.isEmpty { Text(d.live ? "Words appear here as they are heard." : "No turns for this speaker.").font(NativeFont.text(13)).foregroundStyle(UIInk.muted) }
            ForEach(turns) { t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(CallStudioRules.isMe(t.who) ? UIInk.blue : UIInk.coral).frame(width: 6, height: 6)
                        let speaker = CallStudioRules.isMe(t.who) ? "You" : { let n = d.name(t.who); return n == "them" ? "Them" : n }()
                        Text(speaker).font(NativeFont.text(12, .medium))
                        Spacer()
                        Button { if let start = t.start { seek(start, proxy, startPlayback: true) } } label: {
                            Text(t.start.map(CallTimelineRules.formatOffset) ?? "--:--").font(NativeFont.mono(11))
                        }.buttonStyle(.borderless).disabled(t.start == nil || t.start?.isFinite == false)
                            .help("Play from this turn")
                    }.foregroundStyle(UIInk.muted)
                    Text(Mark.text(t.text, terms)).font(NativeFont.text(14)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12)
                .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(activeTurn == t.id ? UIInk.selected : hits.contains(t.id) ? UIInk.soft : .clear))
                .overlay(alignment: .leading) { if activeTurn == t.id { RoundedRectangle(cornerRadius: 1).fill(UIInk.blue).frame(width: 2).padding(.vertical, 12) } }
                .id(t.id)
            }
        }
    }

}

/// Chips that wrap onto the next line.
struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { y += row + spacing; x = 0; row = 0 }
            x += z.width + spacing; row = max(row, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(w, widest), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { y += row + spacing; x = b.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}


/// Edit a recording's title, call app, place, project and notes (meta.json).
struct DetailsSheet: View {
    @EnvironmentObject var m: WindowModel
    @Environment(\.dismiss) private var dismiss
    let d: CallDoc
    @State private var title = ""
    @State private var app = ""
    @State private var place = ""
    @State private var project = ""
    @State private var details = ""
    static let apps = ["Microsoft Teams", "Google Meet", "Zoom", "Slack huddle", "FaceTime", "Telegram", "WhatsApp", "Discord", "Webex"]
    var body: some View {
        Form {
            TextField("Title", text: $title)
            HStack {
                TextField("Call app", text: $app)
                SwiftUI.Menu { ForEach(DetailsSheet.apps, id: \.self) { a in Button(a) { app = a } } } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Pick the call app")
            }
            TextField("Place", text: $place)
            TextField("Project", text: $project)
            TextField("Notes", text: $details, axis: .vertical).lineLimit(3...8)
        }
        .formStyle(.grouped).frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { m.saveDetails(d, title: title, app: app, place: place, project: project, details: details); dismiss() }
            }
        }
        .onAppear { title = d.title; app = d.app; place = d.place; project = d.project; details = d.details }
    }
}

/// Name a speaker someone not offered, or set a person's name forms (the people book, on this Mac).
struct PersonSheet: View {
    @EnvironmentObject var m: WindowModel
    @Environment(\.dismiss) private var dismiss
    let d: CallDoc
    let edit: PersonEdit
    @State private var name = ""
    @State private var forms = ""
    var body: some View {
        Form {
            if edit.forms {
                LabeledContent("Person", value: edit.person)
                TextField("Nicknames and name forms, comma separated", text: $forms, axis: .vertical).lineLimit(2...5)
            } else {
                TextField("Name", text: $name)
            }
        }
        .formStyle(.grouped).frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if edit.forms { m.setForms(edit.person, forms) } else { m.setSpeaker(d, edit.label, name.trimmingCharacters(in: .whitespaces)) }
                    dismiss()
                }.disabled(!edit.forms && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if edit.forms { forms = (PeopleBook.load(WindowModel.bookURL).people[edit.person] ?? []).joined(separator: ", ") } }
    }
}
