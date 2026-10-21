//
//  PrivateAPITests.swift
//  TrueTreeTests
//
//  Guards the private interfaces TrueTree relies on to find responsible pids:
//    - proc_pidinfo flavor 20 (PROC_PIDCOALITIONINFO), not in the public SDK headers
//    - responsibility_get_pid_responsible_for_pid in libquarantine
//  If these fail after a macOS update, Apple likely changed one of them and
//  Src/responsibility.swift needs to be revisited.
//

import XCTest
import Darwin

// MARK: - Helpers

private let sentinel: UInt64 = 0xABAB_ABAB_ABAB_ABAB

/// Spawns /bin/sleep as a child of the test process and kills it when the test ends.
/// Kept short so teardown is quick even where kill() is not permitted (e.g. sandboxed runners).
func spawnChild(_ testCase: XCTestCase) throws -> pid_t {
    var pid: pid_t = 0
    let args = ["/bin/sleep", "5"]
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    
    let rc = posix_spawn(&pid, args[0], nil, nil, &argv, environ)
    guard rc == 0 else { throw XCTSkip("posix_spawn failed: \(String(cString: strerror(rc)))") }
    
    testCase.addTeardownBlock {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
    return pid
}

// MARK: - PROC_PIDCOALITIONINFO layout

final class CoalitionLayoutTests: XCTestCase {
    let selfPid = getpid()
    
    func testKernelStructIsExactlyExpectedSize() {
        // Offer far more room than needed. The kernel copies out and reports its real struct size.
        let (bytes, words) = Coalition.raw(pid: selfPid, bufferWords: 32, fill: sentinel)
        
        XCTAssertEqual(Int(bytes), Coalition.expectedSize,
                       "Kernel's struct proc_pidcoalitioninfo is \(bytes) bytes, expected \(Coalition.expectedSize). Update Coalition in responsibility.swift.")
        XCTAssertTrue(words[Coalition.fieldCount...].allSatisfy { $0 == sentinel },
                      "Kernel wrote past the expected \(Coalition.expectedSize) bytes")
    }
    
    func testKernelRejectsBufferSmallerThanExpected() {
        // If the struct shrank, a smaller buffer would start succeeding
        let (bytes, words) = Coalition.raw(pid: selfPid, bufferWords: Coalition.fieldCount - 1, fill: sentinel)
        
        XCTAssertEqual(bytes, 0, "Kernel accepted a \((Coalition.fieldCount - 1) * 8)-byte buffer and returned \(bytes) bytes; expected the struct to need \(Coalition.expectedSize)")
        XCTAssertTrue(words.allSatisfy { $0 == sentinel })
    }
    
    func testCoalitionIDsArePopulatedAndReservedFieldsAreZero() throws {
        let info = try XCTUnwrap(Coalition.info(for: Int(selfPid)))
        
        XCTAssertNotEqual(info.resourceID, 0, "Resource coalition ID missing; field order may have changed")
        XCTAssertNotEqual(info.jetsamID, 0, "Jetsam coalition ID missing; field order may have changed")
        XCTAssertNotEqual(info.resourceID, info.jetsamID, "Resource and jetsam coalitions should be distinct")
        XCTAssertEqual(info.reserved, [0, 0, 0],
                       "Reserved fields are now populated; Apple may have repurposed them")
    }
    
    func testReadableForOtherUsersProcessesWithoutRoot() throws {
        // The whole point of the coalition approach: launchd is root-owned, but this must work as any user
        let info = try XCTUnwrap(Coalition.info(for: 1), "Could not read coalition info for launchd")
        XCTAssertNotEqual(info.resourceID, 0)
    }
    
    func testDifferentProcessTreesHaveDifferentCoalitions() throws {
        // Guards against the flavor returning constants or unrelated data
        let launchd = try XCTUnwrap(Coalition.resourceID(for: 1))
        let me = try XCTUnwrap(Coalition.resourceID(for: Int(selfPid)))
        XCTAssertNotEqual(launchd, me)
    }
    
    func testSpawnedChildInheritsResourceCoalition() throws {
        let child = try spawnChild(self)
        
        let parentInfo = try XCTUnwrap(Coalition.info(for: Int(selfPid)))
        let childInfo = try XCTUnwrap(Coalition.info(for: Int(child)))
        XCTAssertEqual(childInfo.resourceID, parentInfo.resourceID)
        XCTAssertEqual(childInfo.jetsamID, parentInfo.jetsamID)
    }
    
    func testInvalidPidFails() {
        XCTAssertNil(Coalition.info(for: Int(Int32.max)))
    }
}

// MARK: - libquarantine responsibility API

final class LibquarantineResponsibilityTests: XCTestCase {
    let selfPid = Int(getpid())
    
    func testSymbolStillExists() {
        XCTAssertNotNil(Responsibility.libquarantineFunc,
                        "\(Responsibility.libquarantineSymbol) is gone; responsible pids will not work as root unless --acquire-responsible-via-coalition is passed")
    }
    
    func testWorksForOwnProcess() throws {
        try XCTSkipIf(Responsibility.libquarantineFunc == nil, "Symbol missing")
        let responsible = try XCTUnwrap(Responsibility.viaLibquarantine(selfPid))
        XCTAssertGreaterThan(responsible, 0)
    }
    
    func testSpawnedChildSharesResponsiblePid() throws {
        try XCTSkipIf(Responsibility.libquarantineFunc == nil, "Symbol missing")
        let child = try spawnChild(self)
        
        let parentResponsible = try XCTUnwrap(Responsibility.viaLibquarantine(selfPid))
        let childResponsible = try XCTUnwrap(Responsibility.viaLibquarantine(Int(child)))
        XCTAssertEqual(childResponsible, parentResponsible)
    }
    
    func testStillRequiresRootForOtherUsersProcesses() throws {
        try XCTSkipIf(getuid() == 0, "Running as root")
        try XCTSkipIf(Responsibility.libquarantineFunc == nil, "Symbol missing")
        
        // If this starts failing, Apple relaxed the restriction and the coalition fallback may no longer be needed
        XCTAssertNil(Responsibility.viaLibquarantine(1),
                     "libquarantine now returns responsible pids for other users' processes without root")
    }
}

// MARK: - Coalition estimate vs libquarantine

final class CoalitionResponsibilityTests: XCTestCase {
    
    func testEstimateMatchesLibquarantineForSpawnedChild() throws {
        try XCTSkipIf(Responsibility.libquarantineFunc == nil, "Symbol missing")
        let child = try spawnChild(self)
        
        let selfPid = Int(getpid())
        let expected = try XCTUnwrap(Responsibility.viaLibquarantine(Int(child)))
        let selfExpected = try XCTUnwrap(Responsibility.viaLibquarantine(selfPid))
        let estimates = Responsibility.viaCoalitions(ProcessTable.snapshot())
        let estimate = try XCTUnwrap(estimates[Int(child)], "No coalition estimate for spawned child")
        let selfEstimate = try XCTUnwrap(estimates[selfPid], "No coalition estimate for test process")
        
        // A child inherits both its parent's coalition and responsible pid, so each method must
        // give the child the same answer it gives the test process
        XCTAssertEqual(estimate, selfEstimate)
        XCTAssertEqual(expected, selfExpected)
        
        // Xcode launches the test runner with responsibility disclaimed: the runner is responsible for
        // itself but stays in Xcode's resource coalition. The coalition estimate can't detect that, so
        // only compare the two methods when they already agree on the test process itself.
        try XCTSkipIf(selfEstimate != selfExpected,
                      "libquarantine says the test process (pid \(selfPid)) is the responsibility of pid \(selfExpected), but the earliest process in its coalition is pid \(selfEstimate). It was likely launched with responsibility disclaimed, e.g. by Xcode.")
        
        XCTAssertEqual(estimate, expected)
    }
    
    func testEstimateMatchesLibquarantineForAccessibleProcesses() throws {
        try XCTSkipIf(Responsibility.libquarantineFunc == nil, "Symbol missing")
        
        let procs = ProcessTable.snapshot()
        XCTAssertFalse(procs.isEmpty, "sysctl(KERN_PROC_ALL) returned no processes")
        let estimates = Responsibility.viaCoalitions(procs)
        
        // Compare every process libquarantine can answer for (own processes, or all when root)
        var compared = 0
        var mismatches: [String] = []
        for k in procs {
            let pid = Int(k.kp_proc.p_pid)
            guard pid != 0,
                  let expected = Responsibility.viaLibquarantine(pid),
                  let estimate = estimates[pid] else { continue }
            compared += 1
            if estimate != expected { mismatches.append("pid \(pid): coalition \(estimate), libquarantine \(expected)") }
        }
        
        try XCTSkipIf(compared < 10, "Only \(compared) processes to compare")
        
        // A few known exceptions exist (e.g. com.apple.dock.extra), so require a high match rate rather than 100%
        let matchRate = Double(compared - mismatches.count) / Double(compared)
        XCTAssertGreaterThanOrEqual(matchRate, 0.95,
                                    "Coalition estimate matched \(compared - mismatches.count)/\(compared). Mismatches: \(mismatches.prefix(10))")
    }
}
