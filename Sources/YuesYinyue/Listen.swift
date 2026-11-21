import AppKit
import AVFoundation
import CoreAudio
import Speech

/// Captures the sound of one app (the music player) with a Core Audio process tap.
/// Only that app's audio is captured, never the microphone. macOS asks for
/// "System Audio Recording" permission the first time.
final class AppAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "listen.tap")
    private(set) var format: AVAudioFormat?

    enum TapError: LocalizedError {
        case appNotRunning, failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .appNotRunning: return "The music app isn't running."
            case .failed(let step, let code): return "Couldn't capture the app's sound (\(step), code \(code))."
            }
        }
    }

    func start(bundleID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        // Browsers and Electron apps play sound from helper processes, so tap every process of the app.
        let objects = Self.audioProcesses().filter { obj in
            guard let pid = Self.pid(of: obj) else { return false }
            if pids.contains(pid) { return true }
            return Self.bundleID(of: obj)?.hasPrefix(bundleID) == true
        }
        guard !objects.isEmpty else { throw TapError.appNotRunning }

        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.failed("tap", err) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { throw TapError.failed("format", err) }
        format = fmt

        let outputUID = try Self.defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyrics listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &deviceID)
        guard err == noErr else { throw TapError.failed("device", err) }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: input, deallocator: nil),
                  let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength) else { return }
            copy.frameLength = src.frameLength
            let n = Int(fmt.channelCount)
            if let s = src.floatChannelData, let d = copy.floatChannelData {
                for c in 0..<(fmt.isInterleaved ? 1 : n) {
                    d[c].update(from: s[c], count: Int(src.frameLength) * (fmt.isInterleaved ? n : 1))
                }
            }
            onBuffer(copy)
        }
        guard err == noErr else { throw TapError.failed("reader", err) }
        err = AudioDeviceStart(deviceID, procID)
        guard err == noErr else { throw TapError.failed("start", err) }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(deviceID, p) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        deviceID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    deinit { stop() }

    // MARK: Core Audio lookups

    private static func audioProcesses() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr
        else { return [] }
        return list
    }

    private static func pid(of obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func bundleID(of obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard err == noErr else { throw TapError.failed("output", err) }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
        guard err == noErr, let u = uid?.takeRetainedValue() else { throw TapError.failed("output id", err) }
        return u as String
    }
}

/// Listens to the music app and writes down what's sung, with a time for every character,
/// using Apple's on-device Mandarin speech recognition. Nothing leaves the Mac.
@MainActor
final class Listener: ObservableObject {
    struct Heard: Hashable {
        var text: String
        var start: Double   // song time, seconds
        var duration: Double
    }

    enum State: Equatable { case idle, listening, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var heard: [Heard] = []
    /// Live text of the phrase being recognized right now.
    @Published private(set) var partial = ""

    private let tap = AppAudioTap()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var hints: [String] = []
    /// Song time when the current recognition request started.
    private var base: Double = 0
    private var songTime: () -> Double = { 0 }

    /// `hints`: lyric lines we already know (helps the recognizer pick the right characters).
    func start(bundleID: String, hints: [String], songTime: @escaping () -> Double) async {
        stop()
        heard = []
        partial = ""
        self.hints = Array(hints.prefix(100))
        self.songTime = songTime

        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else {
            state = .failed("Speech Recognition is off for this app. Turn it on in System Settings → Privacy & Security → Speech Recognition.")
            return
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), r.isAvailable else {
            state = .failed("Mandarin speech recognition isn't available on this Mac.")
            return
        }
        recognizer = r
        newRequest()
        do {
            try tap.start(bundleID: bundleID) { [weak self] buffer in
                Task { @MainActor in self?.feed(buffer) }
            }
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
            stop()
        }
    }

    func stop() {
        tap.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        converter = nil
        if state == .listening { state = .idle }
    }

    private func newRequest() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.taskHint = .dictation
        req.contextualStrings = hints
        request = req
        base = songTime()
        let startedAt = base
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let result {
                    if result.isFinal {
                        self.commit(result.bestTranscription, base: startedAt)
                        self.partial = ""
                    } else {
                        self.partial = result.bestTranscription.formattedString
                    }
                }
                // A request ends after a long pause (or ~1 minute); keep going with a fresh one.
                if (result?.isFinal ?? false) || error != nil, self.state == .listening {
                    self.newRequest()
                }
            }
        }
    }

    private func commit(_ t: SFTranscription, base: Double) {
        for seg in t.segments where !seg.substring.isEmpty {
            heard.append(Heard(text: seg.substring, start: base + seg.timestamp, duration: seg.duration))
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let request else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: speechFormat)
        }
        guard let converter else { return }
        let ratio = speechFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: cap) else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if out.frameLength > 0 { request.append(out) }
    }

    // MARK: Turning what was heard into lyrics

    /// Groups heard characters into lines wherever the singer pauses.
    func lines(gap: Double = 0.7) -> [LyricLine] {
        var out: [LyricLine] = []
        var words: [LyricWord] = []
        for h in heard.sorted(by: { $0.start < $1.start }) {
            if let last = words.last, h.start - (last.start + last.duration) > gap || words.count >= 18 {
                out.append(LyricLine(start: words[0].start, text: words.map(\.text).joined(), words: words))
                words = []
            }
            words.append(LyricWord(text: h.text, start: h.start, duration: max(0.08, h.duration)))
        }
        if !words.isEmpty {
            out.append(LyricLine(start: words[0].start, text: words.map(\.text).joined(), words: words))
        }
        return out
    }
}

/// How close the recognizer got, judged by sound (pinyin without tones) so that
/// a right-sounding wrong character (同音字) still counts as heard correctly.
enum ListenScore {
    struct Report {
        var heardCount: Int
        var expectedCount: Int
        var matched: Int
        var characterMatched: Int
        var timingError: Double?   // average seconds between heard and real time, matched characters only
        var soundAccuracy: Double { expectedCount == 0 ? 0 : Double(matched) / Double(expectedCount) }
        var characterAccuracy: Double { expectedCount == 0 ? 0 : Double(characterMatched) / Double(expectedCount) }
    }

    /// Compares what was heard between `from` and `to` (song seconds) with the real lyrics.
    @MainActor
    static func compare(heard: [Listener.Heard], with song: SavedSong, from: Double, to: Double) -> Report {
        let heardChars = heard.flatMap { h -> [(String, Double)] in
            let chars = h.text.map(String.init).filter(isHan)
            let step = chars.isEmpty ? 0 : h.duration / Double(chars.count)
            return chars.enumerated().map { ($0.element, h.start + Double($0.offset) * step) }
        }
        // Real characters sung inside the listening window, with their time when known.
        var real: [(String, Double?)] = []
        for (i, line) in song.lines.enumerated() {
            let end = i + 1 < song.lines.count ? song.lines[i + 1].start : line.start + 8
            guard end > from, line.start < to else { continue }
            if let words = line.words {
                for w in words {
                    let chars = w.text.map(String.init).filter(isHan)
                    let step = chars.isEmpty ? 0 : w.duration / Double(chars.count)
                    for (k, c) in chars.enumerated() where w.start + Double(k) * step >= from - 0.5 && w.start < to {
                        real.append((c, w.start + Double(k) * step))
                    }
                }
            } else {
                real += line.text.map(String.init).filter(isHan).map { ($0, nil) }
            }
        }
        let a = heardChars.map { sound($0.0) }, b = real.map { sound($0.0) }
        let pairs = lcsPairs(a, b)
        var charHits = 0
        var errs: [Double] = []
        for (i, j) in pairs {
            if heardChars[i].0 == real[j].0 || simplified(heardChars[i].0) == simplified(real[j].0) { charHits += 1 }
            if let t = real[j].1 { errs.append(abs(heardChars[i].1 - t)) }
        }
        return Report(heardCount: heardChars.count, expectedCount: real.count, matched: pairs.count,
                      characterMatched: charHits, timingError: errs.isEmpty ? nil : errs.reduce(0, +) / Double(errs.count))
    }

    private static func isHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    private static func simplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }

    @MainActor
    private static func sound(_ c: String) -> String {
        PinyinEngine.shared.tokens(for: LyricLine(start: 0, text: simplified(c)), style: .none).first?.pinyin ?? c
    }

    /// Longest common subsequence, returned as matched index pairs.
    private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0, out: [(Int, Int)] = []
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }
}
