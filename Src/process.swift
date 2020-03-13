//
//  process.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/1/19.
//  2020 TheMittenMac
//

import Foundation
import ProcLib
import Darwin


typealias rpidFunc = @convention(c) (CInt) -> CInt
let MaxPathLen = Int(4 * MAXPATHLEN)
let InfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)


func getPPID(_ pidOfInterest:Int, pidInfo:UnsafeMutablePointer<proc_bsdinfo>) -> UInt32? {
    // Call proc_pidinfo and return nil on error
    guard InfoSize == proc_pidinfo(Int32(pidOfInterest), PROC_PIDTBSDINFO, 0, pidInfo, InfoSize) else { return nil }
    
    return pidInfo.pointee.pbi_ppid
}


func getTimestamp(_ pidOfInterest:Int, pidInfo:UnsafeMutablePointer<proc_bsdinfo>) -> Date {
    // Call proc_pidinfo and return nil on error
    guard InfoSize == proc_pidinfo(Int32(pidOfInterest), PROC_PIDTBSDINFO, 0, pidInfo, InfoSize) else { return Date() }
    let ts = Date(timeIntervalSince1970: TimeInterval(pidInfo.pointee.pbi_start_tvsec))
    
    return ts
}


func getPidPath(_ pidOfInterest:Int) -> String {
    // Get the path for the pid
    let pathBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: MaxPathLen)
    defer { pathBuffer.deallocate() }
    pathBuffer.initialize(repeating: 0, count: MaxPathLen)

    var path: String
    if proc_pidpath(Int32(pidOfInterest), pathBuffer, UInt32(MemoryLayout<Int8>.stride * MaxPathLen)) > 0 {
        path = String(cString: pathBuffer)
    } else {
        path = "unknown"
    }
    
    return path
}


func getResponsiblePid(_ pidOfInterest:Int) -> CInt {
    // Get responsible pid using private Apple API
    let rpidSym:UnsafeMutableRawPointer! = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
    let pidCheck = unsafeBitCast(rpidSym, to: rpidFunc.self)(CInt(pidOfInterest))
    
    var responsiblePid: CInt
    if (pidCheck == -1) {
        print("Error getting responsible pid for process " + String(pidOfInterest))
        print("Defaulting to self")
        responsiblePid = CInt(pidOfInterest)
    } else {
        responsiblePid = pidCheck
    }
    
    return responsiblePid
}


func getSubmittedByPid(_ pidOfInterest: Int, _ launchdXPCInfo: [AnyHashable : Any]) -> Int? {
    var submittedPid: Int?
    if let path = launchdXPCInfo["path"] as? String {
        if (path.contains("submitted by")) {
            var submittedNameTmp = ""
            for x in path.split(separator: " ")[2...] {
                submittedNameTmp += x + " "
            }
            let submittedName = String(submittedNameTmp.split(separator: ".").first!)
            let submittedPidTmp = String(submittedNameTmp.split(separator: ".").last!.dropLast().dropLast())

            if submittedPidTmp.count != 0 && submittedName.count > 0 {
                submittedPid = Int(submittedPidTmp)
           }
       }
   }
    
    return submittedPid
}


func getSubmittedByName(_ pidOfInterest: Int, _ launchdXPCInfo: [AnyHashable : Any]) -> String? {
    var submittedByName: String?
    if let path = launchdXPCInfo["path"] as? String {
        if (path.contains("submitted by")) {
            var submittedNameTmp = ""
            for x in path.split(separator: " ")[2...] {
                submittedNameTmp += x + " "
            }
            
            submittedByName = String(submittedNameTmp.split(separator: ".").first!)
       }
   }
    
    return submittedByName
}


func getLaunchdProgramPath(_ pidOfInterest: Int, _ launchdXPCInfo: [AnyHashable : Any]) -> String? {
    var plistPath: String?
    if let programPath = launchdXPCInfo["program"] {
         plistPath = programPath as? String
    }
    
    return plistPath
}


func getPlistPath(_ pidOfInterest: Int, _ launchdXPCInfo: [AnyHashable : Any]) -> String? {
    var plistPath: String?
    
    if let path = launchdXPCInfo["path"] as? String {
        if (path.contains(".plist")) {
            let responsiblePath = String(path.split(separator: "=").last!).trimmingCharacters(in: .whitespacesAndNewlines)
            plistPath = responsiblePath
        }
    }

    return plistPath
}


func getActivePids() -> [Int] {
    // Inspired by https://gist.github.com/kainjow/0e7650cc797a52261e0f4ba851477c2f
    
    // Call proc_listallpids once with nil/0 args to get the current number of pids
    var pids = [Int]()
    let initialNumPids = proc_listallpids(nil, 0)

    // Allocate a buffer of these number of pids.
    // Make sure to deallocate it as this class does not manage memory for us.
    let buffer = UnsafeMutablePointer<pid_t>.allocate(capacity: Int(initialNumPids))
    defer {
        buffer.deallocate()
    }

    // Calculate the buffer's total length in bytes
    let bufferLength = initialNumPids * Int32(MemoryLayout<pid_t>.size)

    // Call the function again with our inputs now ready
    let numPids = proc_listallpids(buffer, bufferLength)

    // Loop through each pid
    for i in 0..<numPids {
        let pid = buffer[Int(i)]
        pids.append(Int(pid))
    }
    
    return pids
}
