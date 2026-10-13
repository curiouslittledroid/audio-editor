import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 0) {
                header
                Divider()
                bannerArea
                waveformArea
                Divider()
                transportBar
            }

            if model.isDropTargeted {
                dropOverlay
            }
        }
        .frame(minWidth: 920, minHeight: 460)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTargeted) { providers in
            model.acceptDrop(providers: providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.hasFile ? model.displayName : "No audio file open")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.hasFile ? model.formatSummary : "Drag a .wav file here, or press ⌘O")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }

            Button {
                model.presentExportPanel()
            } label: {
                if model.isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Exporting…")
                    }
                } else {
                    Label("Export Trimmed", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasFile || model.isExporting)
            .help("Save the kept region (In → Out) as a new .wav file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Banners

    @ViewBuilder
    private var bannerArea: some View {
        if let message = model.errorMessage {
            banner(text: message,
                   icon: "exclamationmark.triangle.fill",
                   tint: .red,
                   action: nil) {
                model.errorMessage = nil
            }
        } else if let message = model.infoMessage {
            banner(text: message,
                   icon: "checkmark.circle.fill",
                   tint: .green,
                   action: ("Show in Finder", { model.revealLastExport() })) {
                model.infoMessage = nil
            }
        }
    }

    private func banner(text: String,
                        icon: String,
                        tint: Color,
                        action: (String, () -> Void)?,
                        onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 8)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.link).font(.system(size: 12))
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    // MARK: - Waveform

    @ViewBuilder
    private var waveformArea: some View {
        ZStack {
            if model.hasFile {
                WaveformView(
                    peaks: model.peaks,
                    duration: model.duration,
                    trimStart: model.trimStart,
                    trimEnd: model.trimEnd,
                    fadeIn: model.fadeInDuration,
                    fadeOut: model.fadeOutDuration,
                    playhead: model.playhead,
                    isPlaying: model.isPlaying,
                    onTrimStartChanged: { model.setTrimStart($0) },
                    onTrimEndChanged: { model.setTrimEnd($0) },
                    onTrimCommitted: { model.commitTrimChangeWhilePlaying() },
                    onSeek: { model.seek(to: $0) }
                )
                .padding(12)

                if model.isAnalyzing {
                    analyzingOverlay
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var analyzingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Analysing waveform…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Drop a .wav file here")
                .font(.system(size: 15, weight: .medium))

            Text("or use File ▸ Open Audio File (⌘O) to choose one from Finder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Choose File…") { model.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(.quaternary)
        )
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { model.presentOpenPanel() }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                .padding(10)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 34))
                Text("Release to load .wav file")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 15)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.hasFile)
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")

                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 15)
                }
                .disabled(!model.hasFile)
                .help("Stop and return to the start of the selection")

                Toggle(isOn: Binding(get: { model.isLooping },
                                     set: { model.setLooping($0) })) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .disabled(!model.hasFile)
                .help("Loop the kept region")
            }

            Divider().frame(height: 22)

            Text(TimeFormat.timestamp(model.playhead))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 96, alignment: .leading)
            Text("/ \(TimeFormat.timestamp(model.duration))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 22)

            HStack(spacing: 10) {
                statBox("IN", TimeFormat.timestamp(model.trimStart), tint: .orange)
                statBox("OUT", TimeFormat.timestamp(model.trimEnd), tint: .orange)
                statBox("KEPT", TimeFormat.duration(model.trimmedDuration), tint: .accentColor)
            }

            Divider().frame(height: 22)

            HStack(spacing: 8) {
                fadeField("FADE IN", value: Binding(
                    get: { model.fadeInDuration * 1000 },
                    set: { model.setFadeIn($0 / 1000) }
                ))
                fadeField("FADE OUT", value: Binding(
                    get: { model.fadeOutDuration * 1000 },
                    set: { model.setFadeOut($0 / 1000) }
                ))
            }
            .disabled(!model.hasFile)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button("Set In") { model.setTrimStartToPlayhead() }
                    .disabled(!model.hasFile)
                    .help("Move the In point to the playhead (⌥I)")
                Button("Set Out") { model.setTrimEndToPlayhead() }
                    .disabled(!model.hasFile)
                    .help("Move the Out point to the playhead (⌥O)")
                Button("Reset") { model.resetTrim() }
                    .disabled(!model.hasFile || !model.isEdited)
                    .help("Restore the full-length selection")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Editable fade duration in milliseconds. Deliberately not a slider: the
    /// point of a fade is precision (a 5 ms click-killer is not pickable by
    /// hand). Editing while the selection is short visibly snaps to what will
    /// actually be applied, because the stored value is itself clamped (G43).
    private func fadeField(_ title: String, value: Binding<Double>) -> some View {
        let tint = WavePalette.fade
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 42)
                Text("ms")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        .help("Linear fade at this boundary, in milliseconds. Limited to half the selection (\(TimeFormat.duration(model.maxFadeDuration))).")
    }

    private func statBox(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }
}
