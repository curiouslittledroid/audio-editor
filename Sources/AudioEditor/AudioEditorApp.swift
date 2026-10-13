import AppKit
import SwiftUI

@main
struct AudioEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AudioDocumentModel()

    var body: some Scene {
        // A single unique window, not a WindowGroup: this is a one-document
        // editor, and a group would spawn an extra window every time the app is
        // opened with a file (double-click / Open With), leaving two windows.
        Window("Audio Editor", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.attach(model: model)
                }
        }
        .defaultSize(width: 1000, height: 580)
        // Without this, a launch carrying a document (running the executable with
        // a file argument) makes AppKit defer window presentation, and the app
        // comes up with no window at all.
        .defaultLaunchBehavior(.presented)
        .commands {
            // Replace the default New/Open group with our own.
            CommandGroup(replacing: .newItem) {
                Button("Open Audio File…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Close Audio File") { model.closeFile() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasFile)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Export Trimmed Audio…") { model.presentExportPanel() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.hasFile || model.isExporting)

                Button("Show Last Export in Finder") { model.revealLastExport() }
                    .disabled(model.lastExportURL == nil)
            }

            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.hasFile)

                Button("Play Selection From In Point") { model.togglePlayFromSelectionStart() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.hasFile)

                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.hasFile)

                Divider()

                Toggle("Loop Selection", isOn: Binding(get: { model.isLooping },
                                                      set: { model.setLooping($0) }))
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!model.hasFile)
            }

            CommandMenu("Trim") {
                Button("Set In Point to Playhead") { model.setTrimStartToPlayhead() }
                    .keyboardShortcut("i", modifiers: .option)
                    .disabled(!model.hasFile)

                Button("Set Out Point to Playhead") { model.setTrimEndToPlayhead() }
                    .keyboardShortcut("o", modifiers: .option)
                    .disabled(!model.hasFile)

                Button("Select All (Clear Trim)") { model.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.hasFile)
            }

            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .help) { }
        }
    }
}

/// Handles files opened from Finder ("Open With", double-click, or `open -a`),
/// and the `--snapshot` verification mode.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AudioDocumentModel?
    private var pendingURL: URL?
    private var snapshot: SnapshotController?

    func attach(model: AudioDocumentModel) {
        aeLog("AppDelegate.attach env-snapshot=\(ProcessInfo.processInfo.environment["AUDIOEDIT_SNAPSHOT"] ?? "none")")
        self.model = model
        if let pendingURL {
            self.pendingURL = nil
            model.load(url: pendingURL)
        }
        // Guard against a second call (an extra window, or a repeated onAppear)
        // clobbering an in-flight harness run.
        if snapshot == nil, let options = SnapshotOptions.fromEnvironment() {
            let controller = SnapshotController(options: options)
            snapshot = controller
            controller.attach(model: model)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[AudioEditor] open urls -> %@", urls.map(\.path).joined(separator: ", "))
        if let model {
            model.load(url: urls[0])
        } else {
            pendingURL = urls.first
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        aeLog("applicationDidFinishLaunching")
        // Headless pipeline check, used by tools/selftest.sh.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run(arguments: CommandLine.arguments))
        }
        if let raw = ProcessInfo.processInfo.environment["AUDIOEDIT_SELFTEST"], !raw.isEmpty {
            exit(SelfTest.run(paths: raw.split(separator: ":").map(String.init)))
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        NSLog("[AudioEditor] openFiles -> %@", filenames.joined(separator: ", "))
        guard let path = filenames.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        let url = URL(fileURLWithPath: path)
        if let model {
            model.load(url: url)
        } else {
            // The window has not appeared yet; hand it over once it does.
            pendingURL = url
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
