//
//  StandaloneHelperTests.swift
//  ThermalForge
//
//  S01.A standalone-helper invariants: the `.restart` wire verb, the old-daemon
//  decode-failure fallback shape, the SMAppService bundle LaunchDaemon plist, and
//  the socket permission math. All pure — no root, SMC, live socket, or
//  DaemonServer construction.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Standalone helper (S01.A)")
struct StandaloneHelperTests {

    /// A connected pair of Unix stream fds, for the real writeFrame/readFrame path.
    private func socketPair() -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #expect(rc == 0)
        return (fds[0], fds[1])
    }

    /// Round-trip a value: encode → writeFrame(a) → readFrame(b) → decode.
    private func roundTrip<T: Codable & Equatable>(_ value: T, max: Int) throws -> T {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let frame = try DaemonProtocol.encodeFrame(value, max: max)
        try DaemonProtocol.writeFrame(a, frame)
        let body = try DaemonProtocol.readFrame(b, max: max)
        return try DaemonProtocol.decode(T.self, from: body)
    }

    @Test(".restart request and ok response round-trip through a frame")
    func restartRoundTrip() throws {
        let request = DaemonRequest(verb: .restart, oneshot: false)
        #expect(request.v == 1)
        #expect(request.verb == .restart)
        #expect(try roundTrip(request, max: DaemonProtocol.maxRequestBytes) == request)

        // The daemon's acknowledgement is a plain ok with v:1 — the client only
        // needs to know the restart was accepted before the socket dies.
        let response = DaemonResponse.ok()
        #expect(response.v == 1)
        #expect(try roundTrip(response, max: DaemonProtocol.maxResponseBytes) == response)
    }

    @Test("an old daemon decoding restart fails like any unknown verb — the unsupported fallback")
    func oldDaemonRestartFallback() {
        // A daemon built before `.restart` has no such Verb case, so decoding this
        // exact frame throws — identical to any other unknown verb string. The daemon
        // maps that throw to `.unsupported(daemonVersion:)`, and the caller falls
        // back to a kickstart. This is the compatibility contract for the new verb.
        let restartFrame = Data(#"{"v":1,"verb":"restart","oneshot":false}"#.utf8)
        // Current build: decodes cleanly (that's why a plain "does it throw" check
        // can't demonstrate the old behavior).
        #expect((try? DaemonProtocol.decode(DaemonRequest.self, from: restartFrame))?.verb == .restart)

        // Old daemon / genuinely unknown verb: decode throws.
        let unknown = Data(#"{"v":1,"verb":"unknownLegacyVerb","oneshot":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try DaemonProtocol.decode(DaemonRequest.self, from: unknown)
        }

        // And the fallback shape the throw produces.
        let fallback = DaemonResponse.unsupported(daemonVersion: ThermalForgeVersion.current)
        #expect(fallback.ok == false)
        #expect(fallback.error == .unsupportedVersion)
        #expect(fallback.version == ThermalForgeVersion.current)
    }

    @Test("bundle LaunchDaemon plist has exactly the SMAppService keys")
    func bundlePlistContents() throws {
        let xml = DaemonBundlePlist.contents()
        #expect(DaemonBundlePlist.filename == "com.thermalforge.daemon.plist")

        let data = Data(xml.utf8)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let dict = try #require(parsed as? [String: Any])

        #expect(dict["Label"] as? String == "com.thermalforge.daemon")
        // Bundle-root-relative (man 5 launchd.plist), never an absolute path.
        #expect(dict["BundleProgram"] as? String == "Contents/MacOS/thermalforge-helper")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] as? Bool == true)

        // No argument vector and no absolute Program path: SMAppService bundle
        // daemons use BundleProgram only.
        #expect(dict["ProgramArguments"] == nil)
        #expect(dict["Program"] == nil)
        #expect(!xml.contains("ProgramArguments"))
        #expect(!xml.contains("/usr/"))
    }

    @Test("restart race guard classifies mutating vs read-only verbs")
    func restartRejectionClassification() {
        // Mutating verbs are refused once a restart shutdown is armed, so no writer
        // can slip a manual RPM in between resetAuto and exit(0).
        let mutating: [DaemonRequest.Verb] = [.max, .set, .setfan, .heartbeat]
        for verb in mutating {
            #expect(verb.isFanMutatingDuringRestart, "\(verb) must be rejected while restarting")
        }
        // Read-only verbs, the safe reset (`auto`), and `restart` itself stay
        // answerable — clients must still be able to observe and retry.
        let answerable: [DaemonRequest.Verb] = [.auto, .status, .state, .version, .restart]
        for verb in answerable {
            #expect(!verb.isFanMutatingDuringRestart, "\(verb) must still be answered while restarting")
        }
    }

    @Test("socket umask yields exactly rw-rw---- (0660)")
    func socketModeMath() {
        // Socket files are created 0777 & ~umask. 0117 gives 0660 — the
        // root:admin group-writable mode the helper relies on.
        #expect(ThermalForgeDaemon.socketUmask == 0o117)
        #expect(0o777 & ~ThermalForgeDaemon.socketUmask == 0o660)
        #expect(ThermalForgeDaemon.socketMode == 0o660)

        // Semantics, bit by bit: owner rw, group rw, no access for others.
        #expect(ThermalForgeDaemon.socketMode & 0o700 == 0o600)
        #expect(ThermalForgeDaemon.socketMode & 0o070 == 0o060)
        #expect(ThermalForgeDaemon.socketMode & 0o007 == 0o000)
    }
}
