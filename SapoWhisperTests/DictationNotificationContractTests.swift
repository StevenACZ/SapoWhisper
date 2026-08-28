import Darwin
import Foundation
import Testing

@testable import SapoWhisper

@Suite("Dictation companion contract")
struct DictationNotificationContractTests {
    @Test("Lifecycle notifications and authenticated control stay stable")
    func stableNames() {
        #expect(
            DictationStateBroadcaster.recordingBeganNotification.rawValue
                == "oli.SapoWhisper.dictation.began"
        )
        #expect(
            DictationStateBroadcaster.recordingEndedNotification.rawValue
                == "oli.SapoWhisper.dictation.ended"
        )
        #expect(DictationStateBroadcaster.remoteInputDeviceUID == "MiradorMicrophone_UID")
        #expect(
            RemoteDictationControlContract.trustedClientBundleIdentifier
                == "com.stevenacz.mirador.host"
        )
        #expect(
            RemoteDictationControlContract.socketFileName
                == "remote-dictation-control.socket"
        )
        #expect(RemoteDictationControlContract.toggleCommand == "toggle")
        #expect(RemoteDictationControlContract.recordingStateCommand == "recording-state")
    }

    @Test("The peer requirement fixes both bundle and signing team")
    func trustedPeerRequirement() throws {
        let requirement = try #require(
            RemoteDictationControlContract.trustedClientRequirement(
                teamIdentifier: "ABCDEFGHIJ"
            )
        )
        #expect(requirement.contains("identifier \"com.stevenacz.mirador.host\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
        #expect(
            RemoteDictationControlContract.trustedClientRequirement(
                teamIdentifier: "invalid-team"
            ) == nil
        )
    }

    @Test("The socket stays inside SapoWhisper Application Support")
    func socketLocation() {
        let root = URL(fileURLWithPath: "/ApplicationSupport", isDirectory: true)
        let socket = RemoteDictationControlContract.socketURL(in: root)
        #expect(socket.path == "/ApplicationSupport/SapoWhisper/remote-dictation-control.socket")
    }

    @Test("Only the current user can reach the authenticated listener")
    func currentUserOnly() {
        #expect(
            RemoteDictationControlContract.acceptsUser(
                501,
                currentUserIdentifier: 501
            )
        )
        #expect(
            !RemoteDictationControlContract.acceptsUser(
                502,
                currentUserIdentifier: 501
            )
        )
    }

    @MainActor
    @Test("The socket is permissioned, rejects an unsigned peer, and is removed")
    func socketLifecycle() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "sapowhisper-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let server = RemoteDictationCommandServer(
            fileManager: fileManager,
            applicationSupportURL: root,
            teamIdentifierProvider: { "ABCDEFGHIJ" }
        )
        try server.start(onToggle: {}, isRecording: { false })

        let socketURL = RemoteDictationControlContract.socketURL(in: root)
        let attributes = try fileManager.attributesOfItem(atPath: socketURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)

        let response = try send(
            RemoteDictationControlContract.recordingStateCommand,
            to: socketURL
        )
        #expect(response.isEmpty)

        server.stop()
        for _ in 0..<100 where fileManager.fileExists(atPath: socketURL.path) {
            usleep(10_000)
        }
        #expect(!fileManager.fileExists(atPath: socketURL.path))
    }

    @Test("The unauthenticated toggle observer cannot return")
    func noDistributedToggleObserver() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegate = try String(
            contentsOf: repository.appendingPathComponent("SapoWhisper/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let broadcaster = try String(
            contentsOf: repository.appendingPathComponent(
                "SapoWhisper/Core/Managers/DictationStateBroadcaster.swift"
            ),
            encoding: .utf8
        )
        #expect(!appDelegate.contains("DistributedNotificationCenter.default().addObserver"))
        #expect(!appDelegate.contains("oli.SapoWhisper.dictation.toggle"))
        #expect(!broadcaster.contains("oli.SapoWhisper.dictation.toggle"))
    }

    private func send(_ command: String, to socketURL: URL) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let pathBytes = Array(socketURL.path.utf8CString)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            pathBytes.withUnsafeBytes { source in
                memcpy(destination, source.baseAddress, pathBytes.count)
            }
        }
        let connectionResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        #expect(connectionResult == 0)

        let request = "\(command)\n"
        request.withCString { bytes in
            _ = Darwin.write(descriptor, bytes, strlen(bytes))
        }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return Data() }
        return Data(buffer.prefix(Int(count)))
    }
}
