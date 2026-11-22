import AppKit
import Combine
import SwiftUI

@main
struct PinyinSingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("拼音 Sing", systemImage: "music.note") {
            Button("Show / Hide Lyrics Island") { delegate.toggleOverlay() }
                .keyboardShortcut("l")
            Button("Open Library…") { delegate.showLibrary() }
                .keyboardShortcut("o")
            Divider()
            Button("Quit 拼音 Sing") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var overlay: OverlayPanel?
    private var libraryWindow: NSWindow?
    private var spacesWatch: AnyCancellable?
    private var islandWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer check: PinyinSing --test "title" "artist" [seconds]
        let args = CommandLine.arguments
        // Developer check: PinyinSing --snapshot <home|now> <out.png>  (draws the dashboard to an image)
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 {
            showLibrary()
            if let w = ProcessInfo.processInfo.environment["YY_SNAP_W"].flatMap(Double.init) {
                libraryWindow?.setContentSize(NSSize(width: w, height: ProcessInfo.processInfo.environment["YY_SNAP_H"].flatMap(Double.init) ?? 680))
            }
            let page = args[i + 1], out = args[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: .init("debugPage"), object: page)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let v = self?.libraryWindow?.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("status=\(String(describing: self?.model.status)) track=\(self?.model.nowPlaying.track?.title ?? "-")")
                exit(0)
            }
            return
        }
        // Developer check: PinyinSing --qishui "<share link or track id>"
        if let i = args.firstIndex(of: "--qishui"), args.count > i + 1 {
            Task { @MainActor in
                if let r = try? await Qishui.fetch(link: args[i + 1]) {
                    print("\(r.title) — \(r.artist) \(Int(r.duration))s timing=\(r.song.timing) lines=\(r.song.lines.count)")
                    for l in r.song.lines.prefix(3) {
                        print(String(format: "%7.2f  ", l.start) + l.text + "  words=\(l.words?.count ?? 0) first=\(l.words?.first.map { String(format: "%.2f", $0.start) } ?? "-")")
                    }
                } else { print("no lyrics") }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--test"), args.count > i + 2 {
            let track = Track(title: args[i + 1], artist: args[i + 2], album: "",
                              duration: args.count > i + 3 ? Double(args[i + 3]) ?? 0 : 0, bundleID: "test")
            Task { @MainActor in
                if let s = await LyricsService.find(for: track) {
                    print("source=\(s.source) timing=\(s.timing) lines=\(s.lines.count)")
                    for l in s.lines.prefix(6) {
                        let py = PinyinEngine.shared.tokens(for: l, style: .marks, japanese: PinyinEngine.shared.isJapanese(s)).compactMap(\.pinyin)
                        print(String(format: "%7.2f  ", l.start) + l.text + "\n         " + py.joined(separator: " "))
                    }
                } else {
                    print("no lyrics found")
                }
                exit(0)
            }
            return
        }
        let view = OverlayView(model: model, settings: model.settings,
                               openLibrary: { [weak self] in self?.showLibrary() },
                               hide: { [weak self] in self?.model.islandShown = false })
        overlay = OverlayPanel(content: view)
        model.resetIsland = { [weak self] in self?.resetOverlayPosition() }
        overlay?.setAllSpaces(model.settings.allSpaces)
        overlay?.setOnTop(model.settings.alwaysOnTop)
        // Opening the app shows the dashboard; the island comes up from its toggle.
        islandWatch = model.$islandShown.sink { [weak self] shown in
            if shown { self?.overlay?.orderFrontRegardless() } else { self?.overlay?.orderOut(nil) }
        }
        applyAppearance()
        showLibrary()
        spacesWatch = model.settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay?.setAllSpaces(self.model.settings.allSpaces)
                self.overlay?.setOnTop(self.model.settings.alwaysOnTop)
                self.applyAppearance()
            }
        }
    }

    private func applyAppearance() {
        switch model.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.nowPlaying.stop()
    }

    func toggleOverlay() {
        model.islandShown.toggle()
    }

    func resetOverlayPosition() {
        model.islandShown = true
        overlay?.moveToBottomCenter()
    }

    func showLibrary() {
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "拼音 Sing"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LibraryView(model: model, library: model.library,
                                                           settings: model.settings))
            // The window can't be made smaller than the layout needs, so nothing slides off the edge.
            host.sizingOptions = [.minSize]
            w.contentView = host
            w.contentMinSize = NSSize(width: 900, height: 620)
            w.center()
            w.setFrameAutosaveName("LibraryWindow")
            libraryWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }
}
