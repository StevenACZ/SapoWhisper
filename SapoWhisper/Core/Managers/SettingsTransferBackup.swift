import Foundation

struct SettingsTransferBackup {
    static func write(_ data: Data, directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let filename = "BeforeImport-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
        let destination = directory.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}
