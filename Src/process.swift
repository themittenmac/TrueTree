//
//  process.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/1/19.
//  2020 TheMittenMac
//

import Foundation
import ProcLib
import LaunchdXPC

struct Process {
    let pid: Int
    let ppid: Int
    let responsiblePid: Int
    let path: String
    let submittedByPid: Int?
    let submittedByPlist: String?
    let timestamp: String
    let startDate: Date
    let node: Node
    let trueParentPid: Int
    let source: String
    let network: [NetworkConnection]
}


class ProcessCollector {
    var processes = [Process]()
    let timestampFormat = DateFormatter()
    let InfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let MaxPathLen = Int(4 * MAXPATHLEN)
    
    // When true, only standard pid/ppid relationships are collected.
    // Responsible pids, submitted pids, launchd plists, and network connections are skipped.
    let standardMode: Bool
    
    // When true, responsible pids come from libquarantine (the default when running as root).
    // Otherwise they are estimated from resource coalitions, which works without root.
    let responsibleViaLibquarantine: Bool
    
    init(standardMode: Bool = false, responsibleViaLibquarantine: Bool = false) {
        self.standardMode = standardMode
        self.responsibleViaLibquarantine = responsibleViaLibquarantine
        timestampFormat.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.collect()
    }
    
    func collect() {
        if standardMode {
            collectStandard()
        } else {
            collectFull()
        }
        
        // Sort the processes by time
        processes = processes.sorted { $0.timestamp < $1.timestamp }
    }
    
    // Standard mode: build pid/ppid relationships from a single sysctl(KERN_PROC_ALL) snapshot.
    // Unlike proc_pidinfo(PROC_PIDTBSDINFO), this returns ppid and start time for processes
    // owned by other users, so it works without root.
    func collectStandard() {
        for k in getAllKinfoProcs() {
            let pid = Int(k.kp_proc.p_pid)
            
            // Skip for kernel process
            guard pid != 0 else { continue }
            
            let ppid = Int(k.kp_eproc.e_ppid)
            let path = getPath(pid)
            
            let startDate = getStartDate(k)
            let ts = timestampFormat.string(from: startDate)
            
            let node = Node(pid, path: path, timestamp: ts, source: "parent_process", displayString: path)
            let p = Process(pid: pid,
                            ppid: ppid,
                            responsiblePid: pid,
                            path: path,
                            submittedByPid: nil,
                            submittedByPlist: nil,
                            timestamp: ts,
                            startDate: startDate,
                            node: node,
                            trueParentPid: ppid,
                            source: "parent_process",
                            network: []
            )
            processes.append(p)
        }
    }
    
    func getAllKinfoProcs() -> [kinfo_proc] {
        let procs = ProcessTable.snapshot()
        if procs.isEmpty { print("Could not read the process table via sysctl") }
        return procs
    }
    
    // Full TrueTree mode: collect every pid source for correlation.
    // Parents and start times come from sysctl, so they are correct for every process without root.
    func collectFull() {
        let kinfoProcs = getAllKinfoProcs()
        
        // Estimate responsible pids from coalitions up front unless libquarantine was requested
        let coalitionResponsiblePids = responsibleViaLibquarantine ? [:] : Responsibility.viaCoalitions(kinfoProcs)
        
        // Loop through each process and build a process struct
        for k in kinfoProcs {
            // Set the source string for when we locate a true parent
            var source: String = "Unknown"
            
            // Get Pid
            let pid = Int(k.kp_proc.p_pid)
            
            // Skip for kernel process
            guard pid != 0 else { continue }
            
            // Get Parent
            let ppid = Int(k.kp_eproc.e_ppid)
            
            // Get Process Path
            let path = getPath(pid)
            
            // Get Process Timestamp
            let startDate = getStartDate(k)
            let ts = timestampFormat.string(from: startDate)
            
            // Get ResponsiblePid
            let responsiblePid: Int
            let responsibleSource: String
            if responsibleViaLibquarantine {
                responsiblePid = getResponsiblePid(pid)
                responsibleSource = "responsible_pid"
            } else {
                responsiblePid = coalitionResponsiblePids[pid] ?? pid
                responsibleSource = "responsible_pid (coalition)"
            }
            
            // Get SubmittedPid
            let submittedPid = Int(getSubmittedPid(Int32(pid)))
            
            // Get true parent. Plist parents will be handled elsewhere
            let trueParent: Int
            if ppid != 1 {
                trueParent = ppid
                source = "parent_process"
            } else if submittedPid > 1 {
                trueParent = submittedPid
                source = "application_services"
            } else if responsiblePid != pid {
                trueParent = responsiblePid
                source = responsibleSource
            } else {
                trueParent = ppid
                source = "parent_process"
            }
            
            // Collect a plist if it caused this program to run
            var plistNode: String?
            if let launchctlPlist = getSubmittedByPlist(UInt(pid)) {
                if launchctlPlist.hasSuffix(".plist") {
                    plistNode = launchctlPlist
                    source = "launchd_xpc"
                }
            }
            
            // Collect network connections
            let n = NetworkConnections(pid: Int32(pid))
            let networkConnections = n.connections
            
            // Create the tree node
            let node = Node(pid, path: path, timestamp: ts, source: source, displayString: path)
            
            // Create the process entry
            let p = Process(pid: pid,
                            ppid: ppid,
                            responsiblePid: responsiblePid,
                            path: path,
                            submittedByPid: submittedPid,
                            submittedByPlist: plistNode ?? nil,
                            timestamp: ts,
                            startDate: startDate,
                            node: node,
                            trueParentPid: trueParent,
                            source: source,
                            network: networkConnections
            )
            
            // Add the process to the array of captured processes
            processes.append(p)
            
        }
    }
    
    func getStartDate(_ k: kinfo_proc) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(ProcessTable.startSeconds(k)))
    }
    
    func getResponsiblePid(_ pidOfInterest:Int) -> Int {
        // Get responsible pid using private Apple API
        guard let responsiblePid = Responsibility.viaLibquarantine(pidOfInterest) else {
            print("Error getting responsible pid for process \(pidOfInterest). Setting to responsible pid to itself")
            return pidOfInterest
        }
        
        return responsiblePid
    }
    
    func getPath(_ pidOfInterest: Int) -> String {
        let pathBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: MaxPathLen)
        defer { pathBuffer.deallocate() }
        pathBuffer.initialize(repeating: 0, count: MaxPathLen)

        if proc_pidpath(Int32(pidOfInterest), pathBuffer, UInt32(MemoryLayout<Int8>.stride * MaxPathLen)) == 0 {
            return "unknown"
        }
        
        return String(cString: pathBuffer)
    }
    
    func getNodeForPid(_ pidOfInterest: Int) -> Node? {
        for proc in processes {
            if proc.pid == pidOfInterest {
                return proc.node
            }
        }
        
        return nil
    }
}

extension ProcessCollector {
    func printTimeline(outputFile:String?) {
        var lines = [String]()
        for proc in processes {
            let text = "\(proc.timestamp)   \(proc.path)   \(proc.pid)"
            lines.append(text)
            print(text)
        }
        
        // Write the whole timeline once. Writing inside the loop overwrote the file each time,
        // leaving only the last process in it.
        if let outputFile = outputFile {
            let fileUrl = URL(fileURLWithPath: outputFile)
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: fileUrl, atomically: true, encoding: String.Encoding.utf8)
            } catch {
                print("Could not write TrueTree output to specified file")
            }
        }
    }
}
