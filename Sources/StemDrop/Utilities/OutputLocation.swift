import Foundation

/// Resolves and creates the folder a job's stems get written into
/// (SPEC.md §13).
enum OutputLocation {
    /// Creates a fresh split folder. If the song was already split, the new
    /// folder is suffixed with "(2)", "(3)", and so on rather than mixing
    /// a new batch into the previous export.
    @MainActor
    static func newSplitFolder(
        for source: URL,
        prefs: AppPreferences,
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseDirectory: URL
        switch prefs.outputMode {
        case .sameFolder:
            baseDirectory = source.deletingLastPathComponent()
        case .root:
            let configuredRoot = URL(fileURLWithPath: prefs.outputRootPath, isDirectory: true)
            baseDirectory = fileManager.fileExists(atPath: configuredRoot.path)
                ? configuredRoot
                : source.deletingLastPathComponent()
        }

        let songName = source.deletingPathExtension().lastPathComponent
        let first = baseDirectory.appendingPathComponent("\(songName) STEM SPLIT", isDirectory: true)
        var destination = first
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = baseDirectory.appendingPathComponent(
                "\(songName) STEM SPLIT (\(counter))",
                isDirectory: true
            )
            counter += 1
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw StemDropError.outputNotWritable
        }
        return destination
    }

    /// `AppPreferences` is `@MainActor`-isolated, so this hops there to
    /// read `outputMode`/`outputRootPath` before touching the filesystem.
    /// `baseName`, when supplied, overrides the song name used in the
    /// "<baseName> STEM SPLIT" folder (root mode only); defaults to
    /// `source`'s own base name.
    @MainActor
    static func folder(
        for source: URL,
        prefs: AppPreferences,
        baseName: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory: URL

        switch prefs.outputMode {
        case .sameFolder:
            directory = source.deletingLastPathComponent()
        case .root:
            let root = URL(fileURLWithPath: prefs.outputRootPath, isDirectory: true)
            let baseRoot = fileManager.fileExists(atPath: root.path) ? root : source.deletingLastPathComponent()
            let baseName = baseName ?? source.deletingPathExtension().lastPathComponent
            directory = baseRoot.appendingPathComponent("\(baseName) STEM SPLIT", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StemDropError.outputNotWritable
        }

        return directory
    }

    /// Resolves the folder a Vocal Cleanup job's output gets written into.
    /// If the source stem was itself produced by a split (its parent folder
    /// is named "<song> STEM SPLIT"), the cleaned vocal is saved right next
    /// to it there. Otherwise falls back to the normal `folder(for:prefs:)`
    /// rules.
    @MainActor
    static func cleanupFolder(
        for source: URL,
        prefs: AppPreferences,
        fileManager: FileManager = .default
    ) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let parentName = parent.lastPathComponent
        let isSplitFolder = parentName.hasSuffix(" STEM SPLIT")
            || parentName.range(
                of: #" STEM SPLIT \([2-9][0-9]*\)$"#,
                options: .regularExpression
            ) != nil
        if isSplitFolder {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: parent.path)
            else {
                throw StemDropError.outputNotWritable
            }
            return parent
        }

        return try folder(
            for: source,
            prefs: prefs,
            baseName: FileNaming.songBaseName(fromStem: source),
            fileManager: fileManager
        )
    }
}
