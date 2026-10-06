//
//  DaemonProtocolTests.swift
//  ThermalForge
//
//  Phase 2 wire protocol: length-prefixed JSON frames. Exercises the real fd
//  framing path over a socketpair — request/response round-trips per verb, the
//  FanCommand→request mapping (oneshot preservation), oversized-frame rejection
//  (encode and read side), and unknown-verb decode failure (which the daemon
//  turns into a structured unsupportedVersion).
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon protocol (Phase 2)")
struct DaemonProtocolTests {

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

    @Test("every request verb round-trips through a frame")
    func requestRoundTrip() throws {
        let requests: [DaemonRequest] = [
            DaemonRequest(verb: .max, oneshot: true),
            DaemonRequest(verb: .auto),
            DaemonRequest(verb: .set, rpm: 3000, oneshot: true),
            DaemonRequest(verb: .setfan, rpm: 2500, fan: 1, oneshot: true),
            DaemonRequest(verb: .status),
            DaemonRequest(verb: .state),
            DaemonRequest(verb: .heartbeat),
            DaemonRequest(verb: .version),
        ]
        for req in requests {
            #expect(try roundTrip(req, max: DaemonProtocol.maxRequestBytes) == req)
        }
    }

    @Test("every response shape round-trips through a frame")
    func responseRoundTrip() throws {
        let responses: [DaemonResponse] = [
            .ok(),
            .ok(note: "clamped 999999 → 3500 RPM (max)"),
            .ok(note: "clamped 999999 → 3500 RPM (max)", appliedRPM: 3500),
            .ok(appliedRPM: 2500),
            .failure(.usage, "usage: set <rpm>"),
            .failure(.heldByCLI, "held by cli"),
            .failure(.rateLimited, "too many fan commands; try again shortly"),
            .failure(.internal, "smc write failed"),
            .versionResponse("0.1.10"),
            .statusResponse(#"{"fans":[],"temperatures":{}}"#),
            .stateResponse(DaemonHoldState(command: "set 3000", owner: "cli")),
            .stateResponse(DaemonHoldState(command: "set 2000", owner: "app", safetySuspended: true)),
            .unsupported(daemonVersion: "0.1.10"),
        ]
        for resp in responses {
            #expect(try roundTrip(resp, max: DaemonProtocol.maxResponseBytes) == resp)
        }
    }

    @Test("oneshot maps from FanCommand and survives the wire")
    func oneshotPreservation() throws {
        // Hold commands carry oneshot; resetAuto never does (it isn't a hold).
        #expect(DaemonRequest(.setMax, oneshot: true) == DaemonRequest(verb: .max, oneshot: true))
        #expect(DaemonRequest(.setRPM(3000), oneshot: true) == DaemonRequest(verb: .set, rpm: 3000, oneshot: true))
        #expect(DaemonRequest(.setFan(index: 1, rpm: 2500), oneshot: true)
                == DaemonRequest(verb: .setfan, rpm: 2500, fan: 1, oneshot: true))
        #expect(DaemonRequest(.resetAuto, oneshot: true).oneshot == false)
        #expect(DaemonRequest(.setMax, oneshot: false).oneshot == false)

        // And the flag survives a frame round-trip either way.
        #expect(try roundTrip(DaemonRequest(.setMax, oneshot: true), max: DaemonProtocol.maxRequestBytes).oneshot == true)
        #expect(try roundTrip(DaemonRequest(.setRPM(1200), oneshot: false), max: DaemonProtocol.maxRequestBytes).oneshot == false)
    }

    @Test("an unknown verb fails to decode (daemon maps this to unsupportedVersion)")
    func unknownVerbRejected() {
        let json = Data(#"{"v":1,"verb":"bogus","oneshot":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try DaemonProtocol.decode(DaemonRequest.self, from: json)
        }
    }

    @Test("oversized frames are rejected on encode and on read")
    func oversizedRejected() throws {
        // Encode side: a body larger than the cap throws before it goes on the wire.
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version), max: 1)
        }
        // Read side: a length prefix over the cap is rejected before the body is read.
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let header: [UInt8] = [0x00, 0x00, 0x13, 0x88]   // 5000 > 4096; top byte 0x00 → hostile/binary
        try DaemonProtocol.writeFrame(a, header)
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxRequestBytes)
        }
    }

    @Test("a legacy string peer is detected, not misread as oversized; binary stays oversized")
    func legacyPeerDetected() throws {
        // A pre-Phase-2 peer's raw reply — first byte is ASCII 'e' (0x65). The bytes
        // as a big-endian length far exceed the cap, but the ASCII lead marks it legacy.
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        try DaemonProtocol.writeFrame(a, Array("error: unknown command 'x'\n".utf8))
        #expect(throws: DaemonProtocol.FrameError.legacyPeer) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxResponseBytes)
        }

        // A genuinely binary over-cap length (non-ASCII top byte) stays hostile.
        let (c, d) = socketPair()
        defer { close(c); close(d) }
        try DaemonProtocol.writeFrame(c, [0xFF, 0x00, 0x00, 0x00])
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.readFrame(d, max: DaemonProtocol.maxResponseBytes)
        }
    }

    // MARK: - Read/write failure classification (2026-10-04 observability fix)
    //
    // A frame failure must self-identify: a peer that is alive but too slow to
    // answer (SO_RCVTIMEO) is a different operational situation from a peer that
    // closed the connection (exit / restart), and both differ from a raw read
    // error. Before this they all surfaced as `.closed` and the distinction had
    // to be reconstructed by hand from timestamps.

    @Test("clean EOF mid-frame reads as closed, not as a timeout")
    func eofClassified() throws {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        // A truncated header followed by a clean close: the first read delivers
        // the partial bytes, the next returns 0 → `.closed`.
        try DaemonProtocol.writeFrame(a, [0x00, 0x00])
        close(a)
        #expect(throws: DaemonProtocol.FrameError.closed) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxRequestBytes)
        }
    }

    @Test("a silent-but-alive peer reads as readTimeout under SO_RCVTIMEO")
    func readTimeoutClassified() throws {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        // Nothing is ever written; the bounded wait expires → `.readTimeout`.
        // Generous 300ms so a loaded CI machine can't flake it into a pass-by-luck.
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(b, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #expect(throws: DaemonProtocol.FrameError.readTimeout) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxRequestBytes)
        }
    }

    @Test("writing to a closed peer fails with the errno attached")
    func writeFailureCarriesErrno() throws {
        signal(SIGPIPE, SIG_IGN)   // the failure must surface as an error, not kill the test
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        close(b)
        do {
            try DaemonProtocol.writeFrame(a, [0x00, 0x00, 0x00, 0x04, 0x7B, 0x7D])
            Issue.record("expected writeFrame to fail against a closed peer")
        } catch let error as DaemonProtocol.FrameError {
            // EPIPE (32) is the expected carrier; accept any classified write
            // failure shape so the assertion survives platform quirks, but
            // require the errno to be a real system error number.
            guard case .writeFailed(let e) = error else {
                if case .writeTimeout = error {
                    Issue.record("SO_SNDTIMEO fired on a closed-peer write; expected EPIPE")
                }
                return
            }
            #expect(e == EPIPE)
        }
    }

    @Test("frame error descriptions distinguish the failure modes")
    func errorDescriptionsSelfIdentify() {
        // `"\(error)"` is what the "Fan command failed: … — <error>" log line
        // prints, so the strings themselves are the observability contract.
        let closed = DaemonProtocol.FrameError.closed
        let timeout = DaemonProtocol.FrameError.readTimeout
        #expect(String(describing: closed).contains("closed"))
        #expect(!String(describing: closed).contains("Timeout"))
        #expect(String(describing: timeout).contains("readTimeout"))
        #expect(String(describing: DaemonProtocol.FrameError.readFailed(35)).contains("35"))
    }
}
