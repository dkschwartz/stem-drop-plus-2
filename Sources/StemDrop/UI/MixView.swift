import SwiftUI
import AppKit

struct MixView: View {
    @ObservedObject var history: MixHistoryStore
    @ObservedObject var prefs: AppPreferences
    @StateObject private var preview = MixPreviewController()
    @StateObject private var waveformCache = WaveformCache()

    @State private var selectedRecordID: UUID?
    @State private var selectedStems: Set<StemType> = []
    @State private var levels: [StemType: Double] = [:]
    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var lastExportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            exportHistory

            if let record = selectedRecord {
                stemMixer(for: record)
                mixExportOptions
                transport(for: record)
            } else {
                Text("Completed song splits will appear here. The latest eight are kept after you close the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(12)
                    .borderedBox()
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
        .onAppear {
            if selectedRecordID == nil {
                select(history.exports.first)
            }
        }
        .onChange(of: history.exports) { _, exports in
            if selectedRecord == nil {
                select(exports.first)
            }
        }
        .onDisappear { preview.stop() }
    }

    private var selectedRecord: MixExportRecord? {
        history.exports.first(where: { $0.id == selectedRecordID })
    }

    private var exportHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST 8 EXPORTS")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(history.exports) { record in
                        Button {
                            select(record)
                        } label: {
                            HStack {
                                Text(record.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(availableCount(in: record))/\(record.stems.count) stems")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(
                                record.id == selectedRecordID
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                            .borderedBox()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: min(CGFloat(max(history.exports.count, 1)) * 36, 100))
        }
    }

    private func stemMixer(for record: MixExportRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(record.displayName.uppercased()) — SELECT STEMS AND SET LEVELS")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Select All") {
                    preview.stop()
                    selectedStems = Set(record.stems.compactMap { stemFile in
                        FileManager.default.fileExists(atPath: stemFile.url.path)
                            ? stemFile.stem
                            : nil
                    })
                }
                .buttonStyle(.bordered)

                Button("Unselect All") {
                    preview.stop()
                    selectedStems.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(selectedStems.isEmpty)
            }

            VStack(spacing: 4) {
                ForEach(record.stems, id: \.stem) { stemFile in
                    let exists = FileManager.default.fileExists(atPath: stemFile.url.path)
                    HStack(spacing: 8) {
                        Toggle("", isOn: selectionBinding(for: stemFile.stem))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(!exists)

                        Text(stemFile.stem.displayName)
                            .foregroundStyle(exists ? Color.primary : Color.red)
                            .frame(width: 62, alignment: .leading)

                        WaveformView(
                            samples: waveformCache.samplesByURL[stemFile.url] ?? [],
                            height: 22
                        )
                        .opacity(exists ? 1 : 0.45)

                        Slider(
                            value: levelBinding(for: stemFile.stem),
                            in: -60...12,
                            step: 1
                        )
                        .frame(width: 92)
                        .disabled(!exists || !selectedStems.contains(stemFile.stem))

                        Text(exists ? formattedLevel(for: stemFile.stem) : "Missing")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(exists ? Color.secondary : Color.red)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(4)
                    .borderedBox()
                }
            }
        }
        .padding(10)
        .borderedBox()
    }

    private var mixExportOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIX EXPORT")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Format:")
                Picker("", selection: $prefs.outputFormat) {
                    Text("WAV").tag(OutputFormat.wav)
                    Text("AIFF").tag(OutputFormat.aiff)
                    Text("MP3").tag(OutputFormat.mp3)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 105)

                if prefs.outputFormat != .mp3 {
                    Picker("", selection: $prefs.wavBitDepth) {
                        Text("16-bit").tag(WAVBitDepth.int16)
                        Text("24-bit").tag(WAVBitDepth.int24)
                        Text("32-bit float").tag(WAVBitDepth.float32)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                Spacer()
            }
            .padding(10)
            .borderedBox()

            HStack(spacing: 8) {
                Text("Export folder:")
                Text(abbreviatedPath(prefs.mixOutputFolderPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(prefs.mixOutputFolderPath)
                Spacer()
                Button("Change…") { chooseMixFolder() }
            }
            .padding(10)
            .borderedBox()
        }
    }

    private func transport(for record: MixExportRecord) -> some View {
        HStack(spacing: 8) {
            Button("Play") { play(record) }
                .disabled(selectedStems.isEmpty || preview.state == .playing || isExporting)

            Button("Pause") { preview.pause() }
                .disabled(preview.state != .playing)

            Button("Stop") { preview.stop() }
                .disabled(preview.state == .stopped)

            Button("Show in Finder") {
                if let lastExportURL {
                    NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
                }
            }
            .disabled(lastExportURL == nil)

            Spacer()

            Button(isExporting ? "Exporting…" : "Export Mix") {
                exportMix(record)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedStems.isEmpty || isExporting)
        }
        .padding(10)
        .borderedBox()
    }

    private func select(_ record: MixExportRecord?) {
        preview.stop()
        selectedRecordID = record?.id
        guard let record else {
            selectedStems = []
            levels = [:]
            return
        }

        selectedStems = []
        levels = Dictionary(uniqueKeysWithValues: record.stems.map { ($0.stem, 0) })
        for stemFile in record.stems where FileManager.default.fileExists(atPath: stemFile.url.path) {
            waveformCache.load(stemFile.url)
        }
        statusMessage = nil
        lastExportURL = nil
    }

    private func availableCount(in record: MixExportRecord) -> Int {
        record.stems.filter { FileManager.default.fileExists(atPath: $0.url.path) }.count
    }

    private func selectionBinding(for stem: StemType) -> Binding<Bool> {
        Binding(
            get: { selectedStems.contains(stem) },
            set: { isSelected in
                preview.stop()
                if isSelected {
                    selectedStems.insert(stem)
                } else {
                    selectedStems.remove(stem)
                }
            }
        )
    }

    private func levelBinding(for stem: StemType) -> Binding<Double> {
        Binding(
            get: { levels[stem] ?? 0 },
            set: { newValue in
                levels[stem] = newValue
                preview.setLevel(newValue, for: stem)
            }
        )
    }

    private func formattedLevel(for stem: StemType) -> String {
        let value = levels[stem] ?? 0
        return value == 0 ? "0 dB" : String(format: "%+.0f dB", value)
    }

    private func play(_ record: MixExportRecord) {
        statusMessage = nil
        let filePairs: [(StemType, URL)] = record.stems.compactMap { stemFile in
            guard selectedStems.contains(stemFile.stem),
                  FileManager.default.fileExists(atPath: stemFile.url.path)
            else {
                return nil
            }
            return (stemFile.stem, stemFile.url)
        }
        let files = Dictionary(uniqueKeysWithValues: filePairs)

        do {
            try preview.play(files: files, levels: levels)
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func exportMix(_ record: MixExportRecord) {
        preview.stop()
        isExporting = true
        statusMessage = nil

        Task {
            do {
                let destination = try await MixExporter.export(
                    record: record,
                    selectedStems: selectedStems,
                    levels: levels,
                    prefs: prefs
                )
                statusMessage = "Exported \(destination.lastPathComponent)"
                statusIsError = false
                lastExportURL = destination
                if prefs.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            isExporting = false
        }
    }

    private func chooseMixFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.mixOutputFolderPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            prefs.mixOutputFolderPath = url.path
        }
    }
}
