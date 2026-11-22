import AVFoundation
import Foundation

/// "Sync words": times every character of a line-timed song against the singing itself.
///
/// While such a song plays, the music app's sound is recorded (only that app, never the mic).
/// When the song ends, pauses or jumps, the recording goes to `align.py`, which separates the
/// vocals (Demucs) and aligns each line's pinyin to them (torchaudio's MMS_FA). The times are
/// saved with the song, so every later play lights up exactly. Recordings are deleted after.
///
/// The Python tools live in ~/Library/Application Support/Yues Yinyue/sync-env.
@MainActor
final class WordSync: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(String)       // song id
        case aligning(String)
    }
    @Published private(set) var state: State = .idle

    struct Segment {
        var song: SavedSong
        var url: URL
        var start: Double            // song time when recording began
        var end: Double = 0
    }

    private var tap: AppAudioTap?
    private var writer: SegmentWriter?
    private var current: Segment?
    private var queue: [Segment] = []
    private var running = false
    /// Called with the updated song and how many lines got new timing.
    var onSynced: (SavedSong, Int) -> Void = { _, _ in }

    nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Yues Yinyue", isDirectory: true)
    }()
    nonisolated static var python: URL { folder.appendingPathComponent("sync-env/bin/python") }
    nonisolated static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }
    nonisolated private static var work: URL {
        let u = folder.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Lines that still need word timing (no word times from the lyrics source or a past sync).
    nonisolated static func needsSync(_ s: SavedSong) -> Bool {
        s.timing != .none && s.lines.contains { $0.words == nil && !$0.text.isEmpty }
    }

    func startRecording(_ song: SavedSong, bundleID: String, at position: Double) {
        guard current == nil, Self.isInstalled, Self.needsSync(song) else { return }
        let url = Self.work.appendingPathComponent(UUID().uuidString + ".wav")
        let tap = AppAudioTap()
        let writer = SegmentWriter(url: url)
        do {
            try tap.start(bundleID: bundleID) { buffer in writer.write(buffer) }
        } catch {
            log("record failed: \(error.localizedDescription)")
            return
        }
        self.tap = tap
        self.writer = writer
        current = Segment(song: song, url: url, start: position)
        state = .recording(song.id)
        log("recording \(song.title) from \(String(format: "%.1f", position))s")
    }

    /// Ends the current recording. With `keep`, it's aligned (if it's long enough).
    func stopRecording(at position: Double, keep: Bool) {
        guard var seg = current else { return }
        tap?.stop()
        writer?.close()
        tap = nil
        writer = nil
        current = nil
        seg.end = position
        if keep, seg.end - seg.start >= 12 {
            queue.append(seg)
            runNext()
        } else {
            try? FileManager.default.removeItem(at: seg.url)
        }
        if case .recording = state { state = running ? state : .idle }
        if !running, queue.isEmpty { state = .idle }
    }

    var recordingSongID: String? { current?.song.id }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        let seg = queue.removeFirst()
        running = true
        state = .aligning(seg.song.id)
        Task.detached(priority: .utility) {
            let result = await Self.align(seg)
            await MainActor.run {
                self.running = false
                try? FileManager.default.removeItem(at: seg.url)
                if let (song, count) = result, count > 0 { self.onSynced(song, count) }
                if self.current != nil { self.state = .recording(self.current!.song.id) }
                else if self.queue.isEmpty { self.state = .idle }
                self.runNext()
            }
        }
    }

    // MARK: Alignment job

    private struct Job: Encodable {
        struct Line: Encodable { let index: Int; let start: Double; let end: Double; let units: [String] }
        let offset: Double
        let lines: [Line]
    }
    private struct Result: Decodable {
        struct Line: Decodable { let index: Int; let score: Double; let times: [[Double]?] }
        let lines: [Line]
    }

    /// Lines fully inside the recording are sent with their pinyin (no tones). Returns the
    /// song with word times filled in for the lines that aligned confidently.
    nonisolated private static func align(_ seg: Segment) async -> (SavedSong, Int)? {
        let song = seg.song
        let units: [[Token]] = await MainActor.run {
            let ja = PinyinEngine.shared.isJapanese(song)
            return song.lines.map { PinyinEngine.shared.tokens(for: $0, style: .none, japanese: ja) }
        }
        var lines: [Job.Line] = []
        for (i, line) in song.lines.enumerated() where line.words == nil {
            let end = i + 1 < song.lines.count ? song.lines[i + 1].start : line.start + 6
            guard line.start >= seg.start - 0.5, end <= seg.end + 0.5, end > line.start else { continue }
            // The aligner reads plain letters, so drop accents (tēze → teze).
            let u = units[i].map { ($0.pinyin ?? $0.text).folding(options: .diacriticInsensitive, locale: nil) }
            guard u.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            lines.append(.init(index: i, start: line.start, end: end, units: u))
        }
        guard !lines.isEmpty else { log("nothing to align for \(song.title)"); return nil }

        let jobURL = seg.url.deletingPathExtension().appendingPathExtension("job.json")
        let outURL = seg.url.deletingPathExtension().appendingPathExtension("out.json")
        defer {
            try? FileManager.default.removeItem(at: jobURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        guard let data = try? JSONEncoder().encode(Job(offset: seg.start, lines: lines)),
              (try? data.write(to: jobURL)) != nil,
              let script = Bundle.main.url(forResource: "align", withExtension: "py") else { return nil }

        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, seg.url.path, jobURL.path, outURL.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        let started = Date()
        do { try p.run() } catch { log("align failed to start: \(error)"); return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = try? Data(contentsOf: outURL),
              let result = try? JSONDecoder().decode(Result.self, from: out) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("align failed (\(p.terminationStatus)): \(err.suffix(600))")
            return nil
        }

        var updated = song
        var count = 0
        for r in result.lines {
            guard r.score >= minScore, r.index < updated.lines.count else { continue }
            let toks = units[r.index]
            guard toks.count == r.times.count else { continue }
            var words: [LyricWord] = []
            var last = updated.lines[r.index].start
            for (tok, t) in zip(toks, r.times) {
                let text = tok.text
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                // Punctuation and anything the aligner skipped share the previous time.
                let s = t?[0] ?? last
                let e = t?[1] ?? s
                words.append(LyricWord(text: text, start: s, duration: max(0.06, e - s)))
                last = max(last, e)
            }
            guard let first = words.first else { continue }
            updated.lines[r.index].words = words
            updated.lines[r.index].start = first.start
            count += 1
        }
        log("aligned \(count)/\(lines.count) lines of \(song.title) in \(Int(Date().timeIntervalSince(started)))s, scores \(result.lines.map { String(format: "%.2f", $0.score) }.joined(separator: " "))")
        return (updated, count)
    }

    /// Lines whose alignment confidence is below this keep their line timing.
    nonisolated static let minScore = 0.45

    nonisolated static func log(_ s: String) {
        let url = folder.appendingPathComponent("sync.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
    private func log(_ s: String) { Self.log(s) }
}

/// Writes captured audio to a WAV file from the audio thread.
final class SegmentWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var closed = false

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if file == nil {
            let f = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: f.sampleRate,
                AVNumberOfChannelsKey: f.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: f.commonFormat, interleaved: f.isInterleaved)
        }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        file = nil
    }
}
