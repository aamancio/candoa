import Foundation

/// Stages a web extension the person picked — an unpacked folder, or a
/// `.zip`/`.crx`/`.xpi` archive — into Candoa's own container, and finds the
/// directory holding `manifest.json` inside it. Chrome and Firefox archives
/// are both zip files of the same WebExtensions layout; CRX just prepends a
/// signing header that has to be stripped before unzipping.
enum WebExtensionInstaller {
    enum InstallError: LocalizedError {
        case unreadableSource
        case unpackFailed
        case manifestNotFound

        var errorDescription: String? {
            switch self {
            case .unreadableSource:
                return String(localized: "The file couldn't be read.")
            case .unpackFailed:
                return String(localized: "The archive couldn't be unpacked.")
            case .manifestNotFound:
                return String(
                    localized: "No manifest.json found — this doesn't look like a web extension."
                )
            }
        }
    }

    /// Copies or unpacks `sourceURL` into `destination` (created here; removed
    /// again on failure) and returns the extension's manifest root inside it.
    /// Blocking file work — call it off the main actor.
    nonisolated static func stage(_ sourceURL: URL, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw InstallError.unreadableSource
            }

            if isDirectory.boolValue {
                let unpackedRoot = destination.appendingPathComponent("extension", isDirectory: true)
                try fileManager.copyItem(at: sourceURL, to: unpackedRoot)
            } else {
                // Read in-process: the open-panel grant covers this process,
                // but not necessarily helpers it spawns. ditto then only ever
                // touches Candoa's own container.
                guard let data = try? Data(contentsOf: sourceURL) else {
                    throw InstallError.unreadableSource
                }
                let archiveURL = destination.appendingPathComponent("archive.zip")
                try zipPayload(of: data).write(to: archiveURL)
                try unzip(archiveURL, into: destination.appendingPathComponent("extension", isDirectory: true))
                try fileManager.removeItem(at: archiveURL)
            }

            guard let manifestRoot = manifestRoot(in: destination) else {
                throw InstallError.manifestNotFound
            }
            return manifestRoot
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// CRX files are zip archives behind a signing header: magic "Cr24", a
    /// format version, then version-specific header fields. Zip and XPI data
    /// passes through unchanged.
    private nonisolated static func zipPayload(of data: Data) throws -> Data {
        let crxMagic: [UInt8] = [0x43, 0x72, 0x32, 0x34] // "Cr24"
        guard data.count > 16, Array(data.prefix(4)) == crxMagic else { return data }

        func littleEndianWord(at offset: Int) -> Int {
            Int(data[offset])
                | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 24
        }

        let payloadStart: Int
        switch littleEndianWord(at: 4) {
        case 2:
            // CRX2: public-key length + signature length follow.
            payloadStart = 16 + littleEndianWord(at: 8) + littleEndianWord(at: 12)
        case 3:
            // CRX3: one protobuf header, length at offset 8.
            payloadStart = 12 + littleEndianWord(at: 8)
        default:
            throw InstallError.unpackFailed
        }
        guard payloadStart > 0, payloadStart < data.count else {
            throw InstallError.unpackFailed
        }
        return data.subdata(in: payloadStart..<data.count)
    }

    private nonisolated static func unzip(_ archiveURL: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.unpackFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpackFailed
        }
    }

    /// The directory `manifest.json` lives in: the staged root itself, or a
    /// solitary directory inside it (archives often wrap the extension in one
    /// top-level folder).
    nonisolated static func manifestRoot(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent("extension", isDirectory: true)
        if !fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
        }

        for _ in 0..<3 {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
            let children = (try? fileManager.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            guard
                children.count == 1,
                let child = children.first,
                (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else {
                return nil
            }
            candidate = child
        }
        return nil
    }
}

/// One installed extension, as recorded between launches. The unpacked bundle
/// lives in Application Support under the installation's ID; everything else
/// worth remembering fits here.
struct WebExtensionInstallation: Codable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var version: String
    var isEnabled: Bool
    /// Whether the person granted this extension access to private windows.
    /// Off by default: extensions observe browsing, so private access is an
    /// explicit per-extension choice, as in Safari and Chrome.
    var allowsPrivateBrowsing: Bool
    let installedAt: Date

    init(
        id: UUID,
        displayName: String,
        version: String,
        isEnabled: Bool,
        allowsPrivateBrowsing: Bool = false,
        installedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.isEnabled = isEnabled
        self.allowsPrivateBrowsing = allowsPrivateBrowsing
        self.installedAt = installedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        version = try container.decode(String.self, forKey: .version)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // Records written before the private-browsing toggle existed.
        allowsPrivateBrowsing = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsPrivateBrowsing
        ) ?? false
        installedAt = try container.decode(Date.self, forKey: .installedAt)
    }
}

/// The installed-extensions list, stored like Site Info's permission
/// overrides: one UserDefaults key holding a JSON blob. UI test runs share
/// the real container, so persistence is disabled there and every run starts
/// with no extensions.
enum WebExtensionRecords {
    static let storageKey = "Candoa.WebExtensions.Installed"

    nonisolated static var baseDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Candoa", isDirectory: true)
            .appendingPathComponent("WebExtensions", isDirectory: true)
    }

    nonisolated static func directoryURL(for installationID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent(installationID.uuidString, isDirectory: true)
    }

    @MainActor
    static func load() -> [WebExtensionInstallation] {
        guard !BrowserStore.isUITesting else { return [] }
        guard
            let value = UserDefaults.standard.string(forKey: storageKey),
            let data = value.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([WebExtensionInstallation].self, from: data)
        else {
            return []
        }
        return decoded
    }

    @MainActor
    static func save(_ installations: [WebExtensionInstallation]) {
        guard !BrowserStore.isUITesting else { return }
        guard
            let data = try? JSONEncoder().encode(installations),
            let value = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(value, forKey: storageKey)
    }
}
