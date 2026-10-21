//
//  responsibility.swift
//  TrueTree
//
//  Private API wrappers used to find responsible pids, plus the sysctl process table snapshot.
//  Kept free of other TrueTree dependencies so TrueTreeTests can compile it directly and
//  detect if Apple changes these private interfaces between macOS releases.
//

import Darwin

/// Snapshot of the kernel process table via sysctl(KERN_PROC_ALL). Works without root.
enum ProcessTable {
    static func snapshot() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        
        // The process table can grow between the size query and the fetch, so retry on ENOMEM
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            
            // Pad the buffer to leave room for processes spawned in between calls
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = procs.count * stride
            
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return Array(procs.prefix(size / stride))
            }
            if errno != ENOMEM { break }
        }
        
        return []
    }
    
    // p_starttime is a C macro for p_un.__p_starttime and isn't imported into Swift
    static func startSeconds(_ k: kinfo_proc) -> Int {
        return Int(k.kp_proc.p_un.__p_starttime.tv_sec)
    }
    
    static func startMicroseconds(_ k: kinfo_proc) -> Int64 {
        let t = k.kp_proc.p_un.__p_starttime
        return Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec)
    }
}

/// Wrapper for the private PROC_PIDCOALITIONINFO proc_pidinfo flavor.
/// It is not in the public SDK headers, so the layout of struct proc_pidcoalitioninfo is defined here.
/// Verified on macOS 26.1: uint64_t coalition_id[COALITION_NUM_TYPES] (resource, jetsam)
/// followed by three reserved uint64_t fields, 40 bytes total.
enum Coalition {
    static let pidInfoFlavor: Int32 = 20
    static let fieldCount = 5
    static let expectedSize = fieldCount * MemoryLayout<UInt64>.stride
    static let resourceIndex = 0
    static let jetsamIndex = 1
    static let reservedRange = 2..<5
    
    struct Info {
        let resourceID: UInt64
        let jetsamID: UInt64
        let reserved: [UInt64]
    }
    
    /// Calls proc_pidinfo with a caller-chosen buffer size so tests can probe the kernel's struct size.
    /// Returns the byte count proc_pidinfo reported and the buffer contents as UInt64 words.
    static func raw(pid: Int32, bufferWords: Int, fill: UInt64 = 0) -> (bytesReturned: Int32, words: [UInt64]) {
        var words = [UInt64](repeating: fill, count: bufferWords)
        let size = Int32(bufferWords * MemoryLayout<UInt64>.stride)
        let result = words.withUnsafeMutableBytes {
            proc_pidinfo(pid, pidInfoFlavor, 0, $0.baseAddress, size)
        }
        return (result, words)
    }
    
    /// Returns nil if the call fails or the kernel returns a size other than the expected layout
    static func info(for pid: Int) -> Info? {
        let (bytesReturned, words) = raw(pid: Int32(pid), bufferWords: fieldCount)
        guard bytesReturned == Int32(expectedSize) else { return nil }
        
        return Info(resourceID: words[resourceIndex],
                    jetsamID: words[jetsamIndex],
                    reserved: Array(words[reservedRange]))
    }
    
    static func resourceID(for pid: Int) -> UInt64? {
        guard let id = info(for: pid)?.resourceID, id != 0 else { return nil }
        return id
    }
}

enum Responsibility {
    typealias ResponsibleFunc = @convention(c) (CInt) -> CInt
    static let libquarantineSymbol = "responsibility_get_pid_responsible_for_pid"
    
    // Looked up once. nil if the private symbol no longer exists.
    static let libquarantineFunc: ResponsibleFunc? = {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(RTLD_DEFAULT, libquarantineSymbol) else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFunc.self)
    }()
    
    /// The original approach. Requires root for processes owned by other users.
    /// Returns nil if the symbol is missing or the call fails.
    static func viaLibquarantine(_ pid: Int) -> Int? {
        guard let fn = libquarantineFunc else { return nil }
        let responsiblePid = fn(CInt(pid))
        return responsiblePid == -1 ? nil : Int(responsiblePid)
    }
    
    /// Estimate responsible pids without root. Processes in the same resource coalition share a
    /// responsible process: the earliest-started member of the coalition. In testing this matched
    /// responsibility_get_pid_responsible_for_pid for 404 of 405 processes. Known limitation: a process
    /// launched with responsibility disclaimed is responsible for itself but stays in its launcher's
    /// coalition, so it is attributed to the launcher. Seen with some XPC services (e.g. com.apple.dock.extra)
    static func viaCoalitions(_ kinfoProcs: [kinfo_proc]) -> [Int: Int] {
        var coalitionForPid = [Int: UInt64]()
        var earliestMember = [UInt64: (pid: Int, start: Int64)]()
        
        for k in kinfoProcs {
            let pid = Int(k.kp_proc.p_pid)
            guard pid != 0, let coalitionID = Coalition.resourceID(for: pid) else { continue }
            
            coalitionForPid[pid] = coalitionID
            let start = ProcessTable.startMicroseconds(k)
            if let current = earliestMember[coalitionID], current.start <= start { continue }
            earliestMember[coalitionID] = (pid, start)
        }
        
        return coalitionForPid.compactMapValues { earliestMember[$0]?.pid }
    }
}
