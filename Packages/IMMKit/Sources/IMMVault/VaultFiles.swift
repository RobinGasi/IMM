import Darwin
import Foundation

/// `vault.json` reading and atomic writing.
enum VaultFiles {
    static let headerName = "vault.json"
    static let databaseName = "data.sqlite"

    static func headerURL(_ package: URL) -> URL { package.appendingPathComponent(headerName, isDirectory: false) }
    static func databaseURL(_ package: URL) -> URL { package.appendingPathComponent(databaseName, isDirectory: false) }

    private struct FormatProbe: Decodable { let format: Int }

    static func readHeader(at package: URL) throws -> VaultHeader {
        let data: Data
        do {
            data = try Data(contentsOf: headerURL(package))
        } catch {
            throw VaultError.notAVault
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let probe = try? decoder.decode(FormatProbe.self, from: data) else { throw VaultError.notAVault }
        guard probe.format == VaultHeader.currentFormat else { throw VaultError.unsupportedFormat(probe.format) }
        guard let header = try? decoder.decode(VaultHeader.self, from: data) else { throw VaultError.notAVault }
        try header.validate()
        return header
    }

    static func writeHeader(_ header: VaultHeader, to package: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(header) } catch { throw VaultError.io("Could not encode vault.json: \(error)") }
        try atomicWrite(data, to: headerURL(package))
    }

    /// Temp file in the same directory, `F_FULLFSYNC`, `rename(2)` over the target, then fsync the directory.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw VaultError.io("Could not create temporary file: \(posixMessage())") }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }

        do {
            defer { Darwin.close(descriptor) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw VaultError.io("Could not write vault.json: \(posixMessage())")
                    }
                    offset += written
                }
            }
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
                throw VaultError.io("Could not flush vault.json: \(posixMessage())")
            }
        }

        guard rename(temporary.path, url.path) == 0 else {
            throw VaultError.io("Could not replace vault.json: \(posixMessage())")
        }
        renamed = true

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
