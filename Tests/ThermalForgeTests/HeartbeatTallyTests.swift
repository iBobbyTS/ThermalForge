//
//  HeartbeatTallyTests.swift
//  ThermalForge
//
//  The load-test fix (2026-10-05): a starved-but-alive helper's timeout misses
//  must ride a longer fuse than a dead helper's connection misses, and the two
//  counters must not borrow from each other.
//
//  (record() is mutating, so its result goes through a local `tripped` — the
//  swift-testing #expect macro evaluates expressions on an immutable copy.)
//

import Testing

@testable import ThermalForgeCore

@Suite("Heartbeat miss tally")
struct HeartbeatTallyTests {

    // MARK: - Thresholds

    @Test("two hard misses trip — dead helper keeps the fast recovery")
    func hardTripsAtTwo() {
        var tally = HeartbeatTally()
        var tripped = tally.record(.hard)
        #expect(!tripped)
        tripped = tally.record(.hard)
        #expect(tripped)
        #expect(tally.hardMisses == 2)
    }

    @Test("a single hard miss does not trip")
    func singleHardDoesNotTrip() {
        var tally = HeartbeatTally()
        let tripped = tally.record(.hard)
        #expect(!tripped)
    }

    @Test("soft misses need four beats — a starved helper is not restarted fast")
    func softTripsAtFour() {
        var tally = HeartbeatTally()
        var tripped = false
        for _ in 0..<3 {
            tripped = tally.record(.soft) || tripped
        }
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(tripped)
        #expect(tally.softMisses == 4)
    }

    @Test("the 2026-10-05 shape — one soft miss, then a success — never escalates")
    func isolatedSoftMissAbsorbed() {
        var tally = HeartbeatTally()
        for _ in 0..<20 {
            var tripped = tally.record(.soft)
            #expect(!tripped)
            tally.reset()
        }
        #expect(tally.softMisses == 0)
        // The fuse is full-length again after each reset.
        let tripped = tally.record(.soft)
        #expect(!tripped)
    }

    // MARK: - Counter independence

    @Test("hard misses do not borrow the soft fuse, and vice versa")
    func countersAreIndependent() {
        var tally = HeartbeatTally()
        // 1 hard + 3 soft: neither threshold reached.
        var tripped = tally.record(.hard)
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(!tripped)
        // The second hard miss trips on the hard counter alone.
        tripped = tally.record(.hard)
        #expect(tripped)
    }

    @Test("soft streak trips without any hard miss")
    func softOnlyStreak() {
        var tally = HeartbeatTally(hardThreshold: 2, softThreshold: 3)
        var tripped = tally.record(.soft)
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(!tripped)
        tripped = tally.record(.soft)
        #expect(tripped)
    }

    @Test("a success clears both counters")
    func resetClearsBoth() {
        var tally = HeartbeatTally()
        _ = tally.record(.hard)
        _ = tally.record(.soft)
        _ = tally.record(.soft)
        tally.reset()
        #expect(tally.hardMisses == 0 && tally.softMisses == 0)
        // And the fuse is full-length again afterwards.
        let tripped = tally.record(.soft)
        #expect(!tripped)
    }

    // MARK: - Error classification

    @Test("timeout frame errors are soft; everything else is hard")
    func classification() {
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.readTimeout) == .soft)
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.writeTimeout) == .soft)
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.closed) == .hard)
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.readFailed(35)) == .hard)
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.writeFailed(32)) == .hard)
        #expect(HeartbeatMissKind.classify(DaemonProtocol.FrameError.legacyPeer) == .hard)
        #expect(HeartbeatMissKind.classify(DaemonError.notRunning) == .hard)
        // Unrecognized errors stay hard — the conservative default keeps the
        // old fast recovery for anything the classifier doesn't know.
        struct MysteryError: Error {}
        #expect(HeartbeatMissKind.classify(MysteryError()) == .hard)
    }
}
