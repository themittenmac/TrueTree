//
//  SubmittedPidTests.swift
//  TrueTreeTests
//
//  Guards the deprecated Carbon Process Manager calls behind getSubmittedPid() in
//  Src/launchdXPC/launchdXPC.m:
//    - GetProcessForPID                    pid -> ProcessSerialNumber
//    - ProcessInformationCopyDictionary    PSN -> info dictionary, read for the "ParentPSN" key
//    - GetProcessPID                       parent PSN -> submitting pid
//  All three have been deprecated since 10.9. When an app is launched through Launch Services
//  its BSD parent is launchd, and ParentPSN is the only place TrueTree learns who launched it
//  (the "application_services" source). If these tests fail after a macOS update, Apple has
//  likely stubbed, removed, or changed the Process Manager.
//
//  The tests are layered so a failure shows which piece broke:
//    1. The symbols still resolve.
//    2. Each call still behaves as getSubmittedPid() expects (round trips, dictionary keys, PSN encoding).
//    3. getSubmittedPid() gives sensible answers for processes that are already running.
//    4. End to end: an app launched by the test process reports the test process as its submitter.
//

import XCTest
import AppKit
import ApplicationServices
import Darwin
import LaunchdXPC

// MARK: - Process Manager access via dlsym

/// Calls the Process Manager through dlsym instead of the SDK headers. This avoids deprecation
/// warnings, lets a missing symbol be reported as a test failure, and keeps the tests independent of
/// how launchdXPC.m declares things.
private enum ProcessManager {
    typealias PSN = ProcessSerialNumber
    
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<PSN>) -> OSStatus
    typealias GetProcessPIDFn = @convention(c) (UnsafePointer<PSN>, UnsafeMutablePointer<pid_t>) -> OSStatus
    typealias CopyInfoFn = @convention(c) (UnsafePointer<PSN>, UInt32) -> Unmanaged<CFDictionary>?
    
    static let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    static let includeAllInformationMask: UInt32 = 0xFFFF_FFFF  // kProcessDictionaryIncludeAllInformationMask
    static let parentPSNKey = "ParentPSN"
    static let pidKey = "pid"
    
    static let handle = dlopen(frameworkPath, RTLD_LAZY)
    
    static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
    
    static let getProcessForPIDFn = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    static let getProcessPIDFn = symbol("GetProcessPID", as: GetProcessPIDFn.self)
    static let copyInfoFn = symbol("ProcessInformationCopyDictionary", as: CopyInfoFn.self)
    
    static var allSymbolsPresent: Bool {
        getProcessForPIDFn != nil && getProcessPIDFn != nil && copyInfoFn != nil
    }
    
    static func psn(for pid: pid_t) -> PSN? {
        guard let fn = getProcessForPIDFn else { return nil }
        var psn = PSN()
        return fn(pid, &psn) == noErr ? psn : nil
    }
    
    static func pid(for psn: PSN) -> pid_t? {
        guard let fn = getProcessPIDFn else { return nil }
        var psn = psn
        var pid: pid_t = 0
        return fn(&psn, &pid) == noErr ? pid : nil
    }
    
    static func info(for psn: PSN) -> [String: Any]? {
        guard let fn = copyInfoFn else { return nil }
        var psn = psn
        return fn(&psn, includeAllInformationMask)?.takeRetainedValue() as? [String: Any]
    }
    
    static func info(for pid: pid_t) -> [String: Any]? {
        psn(for: pid).flatMap { info(for: $0) }
    }
    
    /// Decodes ParentPSN exactly the way getSubmittedPid() does: high 32 bits, then low 32 bits
    static func decodeParentPSN(_ value: Any?) -> PSN? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.int64Value
        return PSN(highLongOfPSN: UInt32(truncatingIfNeeded: raw >> 32), lowLongOfPSN: UInt32(truncatingIfNeeded: raw))
    }
}

// MARK: - Helpers

extension ProcessSerialNumber: @retroactive Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.highLongOfPSN == b.highLongOfPSN && a.lowLongOfPSN == b.lowLongOfPSN
    }
}

private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func bsdParent(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// Pids of every process that has a Process Manager entry, i.e. everything getSubmittedPid() can answer for
private func processesWithPSN() -> [pid_t] {
    ProcessTable.snapshot()
        .map { $0.kp_proc.p_pid }
        .filter { $0 > 0 && ProcessManager.psn(for: $0) != nil }
}

// MARK: - 1. Symbols

final class SubmittedPidSymbolTests: XCTestCase {
    
    func testApplicationServicesStillLoads() {
        XCTAssertNotNil(ProcessManager.handle, "Could not dlopen \(ProcessManager.frameworkPath)")
    }
    
    func testProcessManagerSymbolsStillExist() {
        // launchdXPC.m links these directly, so if one disappears TrueTree will fail to launch at all,
        // not just lose submitted pids. This test names the missing symbol.
        XCTAssertNotNil(ProcessManager.getProcessForPIDFn, "GetProcessForPID is gone")
        XCTAssertNotNil(ProcessManager.getProcessPIDFn, "GetProcessPID is gone")
        XCTAssertNotNil(ProcessManager.copyInfoFn, "ProcessInformationCopyDictionary is gone")
    }
}

// MARK: - 2. Individual call behavior

final class SubmittedPidAPIBehaviorTests: XCTestCase {
    let selfPid = getpid()
    
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessManager.allSymbolsPresent, "Process Manager symbols missing")
    }
    
    func testPidToPSNToPidRoundTripForOwnProcess() throws {
        // A stub that returns noErr with garbage, or a constant PSN, would break this
        let psn = try XCTUnwrap(ProcessManager.psn(for: selfPid), "GetProcessForPID failed for the test process")
        XCTAssertNotEqual(psn, ProcessManager.PSN(), "GetProcessForPID returned an empty PSN")
        XCTAssertEqual(ProcessManager.pid(for: psn), selfPid, "GetProcessPID did not map the PSN back to the test process")
    }
    
    func testPidToPSNToPidRoundTripForOtherApps() throws {
        // Apps are usually owned by the same user, but this also covers processes TrueTree did not start
        let apps = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 > 0 }
        try XCTSkipIf(apps.isEmpty, "No running applications (headless session?)")
        
        var checked = 0
        for pid in apps {
            guard let psn = ProcessManager.psn(for: pid) else { continue }
            checked += 1
            XCTAssertEqual(ProcessManager.pid(for: psn), pid, "PSN round trip failed for pid \(pid)")
        }
        XCTAssertGreaterThan(checked, 0, "GetProcessForPID failed for every running application")
    }
    
    func testDistinctProcessesHaveDistinctPSNs() throws {
        let pids = processesWithPSN()
        try XCTSkipIf(pids.count < 2, "Fewer than two processes with a PSN")
        
        let psns = pids.compactMap { ProcessManager.psn(for: $0) }
        let unique = Set(psns.map { UInt64($0.highLongOfPSN) << 32 | UInt64($0.lowLongOfPSN) })
        XCTAssertEqual(unique.count, psns.count, "Different processes share a PSN")
    }
    
    func testInfoDictionaryStillHasPidKeyMatchingTheProcess() throws {
        // getSubmittedPid reads this dictionary by key name, so check the keys still mean what we think
        let info = try XCTUnwrap(ProcessManager.info(for: selfPid), "ProcessInformationCopyDictionary returned nil")
        let pid = try XCTUnwrap(info[ProcessManager.pidKey] as? NSNumber, "Info dictionary has no \"pid\" key. Keys: \(info.keys.sorted())")
        XCTAssertEqual(pid.int32Value, selfPid)
    }
    
    func testSomeRunningProcessStillHasParentPSNKey() throws {
        // On a normal desktop session, anything launched from the Dock, Finder, Spotlight, etc. has a ParentPSN.
        // If no process has the key at all, Apple has likely renamed or dropped it.
        let pids = processesWithPSN()
        try XCTSkipIf(pids.count < 10, "Only \(pids.count) processes with a PSN (headless session?)")
        
        let withKey = pids.filter { ProcessManager.info(for: $0)?[ProcessManager.parentPSNKey] != nil }
        XCTAssertFalse(withKey.isEmpty,
                       "None of \(pids.count) processes have a \"\(ProcessManager.parentPSNKey)\" key. Sample keys: \(ProcessManager.info(for: pids[0])?.keys.sorted() ?? [])")
    }
    
    func testParentPSNDecodesToARealProcess() throws {
        // getSubmittedPid splits ParentPSN into high/low 32-bit halves. If the encoding changes, the decoded
        // PSN will no longer resolve to a process with its own Process Manager entry.
        let pids = processesWithPSN()
        var checked = 0
        for pid in pids {
            guard let info = ProcessManager.info(for: pid),
                  let parent = ProcessManager.decodeParentPSN(info[ProcessManager.parentPSNKey]),
                  let parentPid = ProcessManager.pid(for: parent) else { continue }
            checked += 1
            
            XCTAssertGreaterThan(parentPid, 0, "pid \(pid): ParentPSN resolved to pid \(parentPid)")
            XCTAssertNotEqual(parentPid, pid, "pid \(pid) claims to be its own submitter")
            
            // The parent PSN should be the same PSN the Process Manager hands out for that pid
            XCTAssertEqual(ProcessManager.psn(for: parentPid), parent,
                           "pid \(pid): decoded ParentPSN does not match GetProcessForPID(\(parentPid))")
            let parentInfo = ProcessManager.info(for: parent)
            XCTAssertEqual((parentInfo?[ProcessManager.pidKey] as? NSNumber)?.int32Value, parentPid,
                           "pid \(pid): info for decoded ParentPSN describes a different process")
        }
        try XCTSkipIf(checked == 0, "No process with a live ParentPSN to check (headless session?)")
    }
}

// MARK: - 3. getSubmittedPid() on running processes

final class SubmittedPidExistingProcessTests: XCTestCase {
    
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessManager.allSymbolsPresent, "Process Manager symbols missing")
    }
    
    func testMatchesManualDecoding() throws {
        // getSubmittedPid and the step-by-step calls above must agree for every process
        let pids = processesWithPSN()
        try XCTSkipIf(pids.isEmpty, "No processes with a PSN")
        
        for pid in pids {
            let expected = ProcessManager.info(for: pid)
                .flatMap { ProcessManager.decodeParentPSN($0[ProcessManager.parentPSNKey]) }
                .flatMap { ProcessManager.pid(for: $0) } ?? 0
            let actual = getSubmittedPid(pid)
            // A process can exit between the two lookups, so only compare when both are still meaningful
            guard isAlive(pid), actual == 0 || isAlive(actual) else { continue }
            XCTAssertEqual(actual, expected, "getSubmittedPid(\(pid)) disagrees with manual decoding")
        }
    }
    
    func testDesktopSessionHasSubmittedPids() throws {
        // The core regression guard: if this hits zero on a normal desktop, TrueTree has silently lost
        // the application_services source even though nothing crashed.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        try XCTSkipIf(apps.count < 2, "Fewer than two regular apps running (headless session?)")
        
        let submitted = processesWithPSN().filter { getSubmittedPid($0) > 1 }
        XCTAssertFalse(submitted.isEmpty,
                       "No process has a submitted pid, even though \(apps.count) regular apps are running")
    }
    
    func testSubmittedPidsPointAtLiveProcessesWithPSNs() throws {
        // A submitter is always another Launch Services client, so it must be alive and have a PSN itself
        var checked = 0
        for pid in processesWithPSN() {
            let submitter = getSubmittedPid(pid)
            guard submitter > 1, isAlive(pid) else { continue }
            checked += 1
            XCTAssertNotEqual(submitter, pid, "pid \(pid) is its own submitter")
            XCTAssertTrue(isAlive(submitter), "pid \(pid): submitter \(submitter) does not exist")
            XCTAssertNotNil(ProcessManager.psn(for: submitter), "pid \(pid): submitter \(submitter) has no PSN")
        }
        try XCTSkipIf(checked == 0, "No submitted pids to check")
    }
    
    func testLaunchdStartedAgentsHaveNoSubmitter() throws {
        // The Dock is started by launchd at login, not by another app
        let dock = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
                                 "Dock is not running (headless session?)")
        XCTAssertEqual(getSubmittedPid(dock.processIdentifier), 0)
    }
    
    func testInvalidAndSystemPidsReturnZero() {
        // process.swift treats anything <= 1 as "no submitter", so these must not return garbage
        XCTAssertEqual(getSubmittedPid(Int32.max), 0)
        XCTAssertEqual(getSubmittedPid(-1), 0)
        XCTAssertEqual(getSubmittedPid(0), 0)
        XCTAssertLessThanOrEqual(getSubmittedPid(1), 1)
    }
    
    func testPlainChildProcessHasNoSubmitter() throws {
        // A posix_spawn'd tool never checks in with Launch Services, so it has no PSN and no submitter.
        // TrueTree relies on this to fall through to ppid / responsible pid for ordinary processes.
        let child = try spawnChild(self)
        XCTAssertEqual(getSubmittedPid(child), 0)
    }
}

// MARK: - 4. End to end

final class SubmittedPidLaunchTests: XCTestCase {
    
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessManager.allSymbolsPresent, "Process Manager symbols missing")
    }
    
    /// Minimal AppKit app. It has to be a real NSApplication: Launch Services only reports a launch as
    /// finished (and only fills in ParentPSN) once the new process checks in, which a plain sleeping
    /// executable never does. It quits on its own after 30 seconds in case teardown never runs.
    private static let probeSource = """
    #import <AppKit/AppKit.h>
    int main(void) {
        @autoreleasepool {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            [NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t) { exit(0); }];
            [NSApp run];
        }
        return 0;
    }
    """
    
    /// Compiles the probe once per test run and caches the binary
    private static var compiledProbe: Result<URL, Error> = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrueTreeTests-probe-\(getpid())")
        let src = dir.appendingPathComponent("probe.m")
        let bin = dir.appendingPathComponent("SubmittedPidProbe")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try probeSource.write(to: src, atomically: true, encoding: .utf8)
            
            let clang = Foundation.Process()
            clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            clang.arguments = ["clang", "-fobjc-arc", "-framework", "AppKit", src.path, "-o", bin.path]
            let errPipe = Pipe()
            clang.standardError = errPipe
            try clang.run()
            clang.waitUntilExit()
            guard clang.terminationStatus == 0 else {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw XCTSkip("Could not compile probe app: \(msg)")
            }
            return .success(bin)
        } catch {
            return .failure(error)
        }
    }()
    
    /// Builds a throwaway background-only .app around the compiled probe binary
    private func makeTestApp() throws -> (url: URL, bundleID: String) {
        let probe = try Self.compiledProbe.get()
        let bundleID = "truetree.tests.submitted.\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrueTreeTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("SubmittedPidProbe.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        
        try FileManager.default.copyItem(at: probe, to: macOS.appendingPathComponent("SubmittedPidProbe"))
        
        let plist: [String: Any] = [
            "CFBundleExecutable": "SubmittedPidProbe",
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "SubmittedPidProbe",
            "CFBundlePackageType": "APPL",
            "LSBackgroundOnly": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        
        // Ad-hoc sign the whole bundle so the Info.plist is sealed and Launch Services accepts it
        let codesign = Foundation.Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", app.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else { throw XCTSkip("Could not ad-hoc sign probe app") }
        return (app, bundleID)
    }
    
    private func launch(_ app: URL) throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        
        let done = expectation(description: "launch")
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: config) { a, e in
            launched = a
            launchError = e
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        
        if let launchError {
            // e.g. sandboxed runners without (allow lsopen), or no GUI session
            throw XCTSkip("Launch Services could not launch the probe app: \(launchError)")
        }
        let app = try XCTUnwrap(launched)
        addTeardownBlock {
            app.forceTerminate()
            var status: Int32 = 0
            waitpid(app.processIdentifier, &status, WNOHANG)
        }
        return app
    }
    
    /// Launch Services registers the new process asynchronously, so poll briefly
    private func submittedPid(of pid: pid_t) -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        var value: Int32 = 0
        repeat {
            value = getSubmittedPid(pid)
            if value != 0 { break }
            usleep(50_000)
        } while Date() < deadline
        return value
    }
    
    func testAppLaunchedByTestProcessReportsTestProcessAsSubmitter() throws {
        let (url, _) = try makeTestApp()
        let app = try launch(url)
        let pid = app.processIdentifier
        XCTAssertGreaterThan(pid, 0)
        
        // This is the situation TrueTree exists for: the BSD parent is launchd, so ppid tells us nothing
        if let ppid = bsdParent(of: pid) {
            XCTAssertEqual(ppid, 1, "Launched app's BSD parent is \(ppid), expected launchd")
        }
        
        XCTAssertEqual(submittedPid(of: pid), getpid(),
                       "getSubmittedPid did not report the test process as the launcher. ParentPSN may no longer be populated.")
    }
    
    func testSecondInstanceAlsoReportsTestProcess() throws {
        // Guards against ParentPSN being cached per bundle or only set for the first launch
        let (url, _) = try makeTestApp()
        let first = try launch(url)
        let second = try launch(url)
        XCTAssertNotEqual(first.processIdentifier, second.processIdentifier)
        XCTAssertEqual(submittedPid(of: first.processIdentifier), getpid())
        XCTAssertEqual(submittedPid(of: second.processIdentifier), getpid())
    }
}
