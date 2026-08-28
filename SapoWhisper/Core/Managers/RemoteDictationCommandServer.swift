import Darwin
import Foundation
import Security

nonisolated enum RemoteDictationControlContract {
    static let socketFileName = "remote-dictation-control.socket"
    static let trustedClientBundleIdentifier = "com.stevenacz.mirador.host"
    static let toggleCommand = "toggle"
    static let recordingStateCommand = "recording-state"

    static func socketURL(in applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent("SapoWhisper", isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
    }

    static func trustedClientRequirement(teamIdentifier: String) -> String? {
        guard teamIdentifier.utf8.count == 10,
            teamIdentifier.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte)
            })
        else { return nil }

        return
            "anchor apple generic and identifier \"\(trustedClientBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func acceptsUser(_ userIdentifier: uid_t, currentUserIdentifier: uid_t) -> Bool {
        userIdentifier == currentUserIdentifier
    }

    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let values = information as? [String: Any]
        else { return nil }

        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

nonisolated private enum RemoteDictationCommandServerError: Error {
    case applicationSupportUnavailable
    case signingIdentityUnavailable
    case invalidSocketPath
    case socketCreationFailed
    case socketBindingFailed
    case socketListeningFailed
}

nonisolated private final class RemoteDictationPeerValidator: @unchecked Sendable {
    private let requirement: SecRequirement

    init(requirement: String) throws {
        var requirementReference: SecRequirement?
        let result = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &requirementReference
        )
        guard result == errSecSuccess, let requirementReference else {
            throw RemoteDictationCommandServerError.signingIdentityUnavailable
        }
        self.requirement = requirementReference
    }

    func accepts(socket: Int32) -> Bool {
        var userIdentifier: uid_t = 0
        var groupIdentifier: gid_t = 0
        guard getpeereid(socket, &userIdentifier, &groupIdentifier) == 0,
            RemoteDictationControlContract.acceptsUser(
                userIdentifier,
                currentUserIdentifier: geteuid()
            )
        else { return false }

        var auditToken = audit_token_t()
        var auditTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard
            getsockopt(
                socket,
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                &auditToken,
                &auditTokenSize
            ) == 0,
            auditTokenSize == MemoryLayout<audit_token_t>.size
        else { return false }

        let tokenData = Data(
            bytes: &auditToken,
            count: MemoryLayout<audit_token_t>.size
        )
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var peerCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode) == errSecSuccess,
            let peerCode
        else { return false }

        return SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess
    }
}

@MainActor
final class RemoteDictationCommandServer {
    private let fileManager: FileManager
    private let applicationSupportURL: URL?
    private let teamIdentifierProvider: () -> String?
    private let queue = DispatchQueue(label: "oli.SapoWhisper.remote-dictation-control")
    private var source: DispatchSourceRead?
    private var socketURL: URL?

    init(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        teamIdentifierProvider: @escaping () -> String? = {
            RemoteDictationControlContract.currentTeamIdentifier()
        }
    ) {
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
        self.teamIdentifierProvider = teamIdentifierProvider
    }

    func start(
        onToggle: @escaping @MainActor @Sendable () -> Void,
        isRecording: @escaping @MainActor @Sendable () -> Bool
    ) throws {
        guard source == nil else { return }
        guard
            let applicationSupportURL = applicationSupportURL
                ?? fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
        else {
            throw RemoteDictationCommandServerError.applicationSupportUnavailable
        }
        guard let teamIdentifier = teamIdentifierProvider(),
            let requirement = RemoteDictationControlContract.trustedClientRequirement(
                teamIdentifier: teamIdentifier
            )
        else {
            throw RemoteDictationCommandServerError.signingIdentityUnavailable
        }

        let validator = try RemoteDictationPeerValidator(requirement: requirement)
        let socketURL = RemoteDictationControlContract.socketURL(in: applicationSupportURL)
        try fileManager.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = try Self.makeListeningSocket(at: socketURL)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            Self.acceptPendingConnections(
                from: descriptor,
                validator: validator,
                onToggle: onToggle,
                isRecording: isRecording
            )
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
            Darwin.unlink(socketURL.path)
        }
        source.activate()

        self.source = source
        self.socketURL = socketURL
    }

    func stop() {
        source?.cancel()
        source = nil
        socketURL = nil
    }

    private nonisolated static func makeListeningSocket(at url: URL) throws -> Int32 {
        let pathBytes = Array(url.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw RemoteDictationCommandServerError.invalidSocketPath
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RemoteDictationCommandServerError.socketCreationFailed
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            pathBytes.withUnsafeBytes { source in
                memcpy(destination, source.baseAddress, pathBytes.count)
            }
        }

        Darwin.unlink(url.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw RemoteDictationCommandServerError.socketBindingFailed
        }
        guard Darwin.chmod(url.path, S_IRUSR | S_IWUSR) == 0,
            Darwin.listen(descriptor, 4) == 0
        else {
            Darwin.close(descriptor)
            Darwin.unlink(url.path)
            throw RemoteDictationCommandServerError.socketListeningFailed
        }

        let existingFlags = fcntl(descriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }
        return descriptor
    }

    private nonisolated static func acceptPendingConnections(
        from listener: Int32,
        validator: RemoteDictationPeerValidator,
        onToggle: @escaping @MainActor @Sendable () -> Void,
        isRecording: @escaping @MainActor @Sendable () -> Bool
    ) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            handle(
                client: client,
                validator: validator,
                onToggle: onToggle,
                isRecording: isRecording
            )
        }
    }

    private nonisolated static func handle(
        client: Int32,
        validator: RemoteDictationPeerValidator,
        onToggle: @escaping @MainActor @Sendable () -> Void,
        isRecording: @escaping @MainActor @Sendable () -> Bool
    ) {
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard validator.accepts(socket: client) else {
            Darwin.close(client)
            return
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard let command = readCommand(from: client) else {
            Darwin.close(client)
            return
        }

        switch command {
        case RemoteDictationControlContract.toggleCommand:
            Task { @MainActor in
                onToggle()
                respond("ok\n", to: client)
            }
        case RemoteDictationControlContract.recordingStateCommand:
            Task { @MainActor in
                respond(isRecording() ? "recording\n" : "idle\n", to: client)
            }
        default:
            Darwin.close(client)
        }
    }

    private nonisolated static func readCommand(from client: Int32) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while bytes.count < 64 {
            var byte: UInt8 = 0
            let count = recv(client, &byte, 1, 0)
            guard count == 1 else { return nil }
            if byte == 0x0A {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(byte)
        }
        return nil
    }

    private nonisolated static func respond(_ response: String, to client: Int32) {
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(
                    client,
                    baseAddress.advanced(by: sent),
                    buffer.count - sent
                )
                guard count > 0 else { break }
                sent += count
            }
        }
        Darwin.close(client)
    }
}
