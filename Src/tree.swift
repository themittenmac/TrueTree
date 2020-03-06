//
//  tree.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/2/19.
//  2020 TheMittenMac
//
// Inspired by https://www.journaldev.com/21383/swift-tree-binary-tree-data-structure


import Foundation
import LaunchdXPC


class Node<T> {
    var pid: T
    var ppid: UInt32
    weak var parent: Node?
    var procPath: String
    var responsiblePid: CInt
    var timestamp: Date
    var submittedByPlist: String?
    var submittedByPid: Int?
    var submittedByName: String?
    var launchdProgramPath: String?
    var children: [Node] = []
    
    init(_ pid: T, ppid: UInt32, procPath: String, responsiblePid: CInt, timestamp: Date) {
        self.pid = pid
        self.ppid = ppid
        self.procPath = procPath
        self.responsiblePid = responsiblePid
        self.timestamp = timestamp
    }
    
    func printNodeData(_ coloring: Bool, _ timestamps: Bool, _ treeMode: Bool) -> [String] {
        var val: String
        
        if coloring {
            if self.procPath.hasSuffix(".plist") {
                val = "\u{001B}[0;34m\(self.procPath)\u{001B}[0;0m"
            } else if self.procPath.hasSuffix("Terminated)") {
                val = "\u{001B}[0;31m\(self.procPath)\u{001B}[0;0m"
            } else if self.procPath.hasSuffix("(Exec'ed into below process)") {
                val = "\u{001B}[0;33m\(self.procPath)   \(self.pid)\u{001B}[0;0m"
            } else {
                val = "\(self.procPath)   \u{001B}[0;35m\(self.pid)\u{001B}[0;0m"
                if argManager.timestamps {
                    val += "   \u{001B}[0;36m\(self.timestamp)\u{001B}[0;0m"
                }
            }
        } else {
            if self.procPath.hasSuffix(".plist") || self.procPath.hasSuffix("Terminated)") {
                val = self.procPath
            } else {
                val = "\(self.procPath)   \(self.pid)"
                val += "   \(self.timestamp)"
            }
        }
        
        if argManager.treeMode == false {
            return [val] + self.children.flatMap{$0.printNodeData(coloring, timestamps, treeMode)}.map{$0}
        } else {
            return [val] + self.children.flatMap{$0.printNodeData(coloring, timestamps, treeMode)}.map{"    "+$0}
        }
        
    }
    
    func printTree(_ coloring:Bool, _ timestamps: Bool, _ treeMode: Bool, _ toFile: String?) {
        let text = printNodeData(coloring, timestamps, treeMode).joined(separator: "\n")
        if let toFile = toFile {
            let fileUrl = URL(fileURLWithPath: toFile)
            do {
                try text.write(to: fileUrl, atomically: true, encoding: String.Encoding.utf8)
            } catch {
                print("Could not write TrueTree output to specified file")
            }
        } else {
            let text = printNodeData(coloring, timestamps, treeMode).joined(separator: "\n")
            print(text)
        }
    }
}


func buildStandardTree(_ nodePidDict:[Int:Node<Any>]) -> Node<Any> {
    // Builds a tree using standard unix pids and ppids
    for (_, node) in nodePidDict {
        let ppid = Int(node.ppid)
        if let parentNode = nodePidDict[ppid] {
            parentNode.children.append(node)
        }
    }
    
    guard let rootNode = nodePidDict[1] else {
        exit(1)
    }
    
    return rootNode
}


func buildTrueTree(_ nodePidDict:[Int:Node<Any>]) -> Node<Any> {
    // Empty dictionary to hold plist items
    var nodePlistDict = [String:Node<Any>]()
    
    // Builds a tree based on the TrueTree concept and returns the root node
    for (pid, node) in nodePidDict {
        if pid == 1 {
            continue
        }
        // If a plist was responsible for the creation of a process add the plist as a node entry
        // Pids don't matter as we will only reference the procPath
        if let submittedByPlist = node.submittedByPlist {
            if nodePlistDict[submittedByPlist] == nil {
                let plistNode = Node<Any>(-1, ppid:1, procPath:submittedByPlist, responsiblePid:-1, timestamp: Date())
                nodePlistDict[submittedByPlist] = plistNode
                
                // Assign this plist as a child node to launchd
                nodePidDict[1]?.children.append(plistNode)
            }
        }
        
        
        // This is another forensic artifact implying a possible exec occured on a responsible pid!
        // If this occurs the a new parent should be created. That parent should have a parent of the TrueTree Model
        // Current pid <- exec'ed pid <- trueTree Model Pid
        var execOldNode: Node<Any>?
        if let launchdProgramPath = node.launchdProgramPath {
            // an exec'ed parent is really only interesting if the file names are different. Otherwise it was likely just a framework exec
            let fileName1 = (launchdProgramPath as NSString).lastPathComponent
            let fileName2 = (node.procPath as NSString).lastPathComponent
            if fileName1.caseInsensitiveCompare(fileName2) != .orderedSame {
                let execOldProgramName = launchdProgramPath + " (Exec'ed into below process)"
                let newNode = Node<Any>(node.pid, ppid:node.ppid, procPath: execOldProgramName, responsiblePid: node.responsiblePid, timestamp: node.timestamp)
                
                newNode.children.append(node)
                execOldNode = newNode
            }
        }
        
        var trueParentPid:Int?
        var trueParentPlist:String?
        trueParentPlist = nil
        
        // Find the pid (or plist) we should use as the parent
        if let submittedByPid = node.submittedByPid {
            if nodePidDict.keys.contains(submittedByPid){
                trueParentPid = submittedByPid
            } else {
                if let submittedByName = node.submittedByName {
                    node.procPath += " (TrueParent:\(submittedByPid) \"\(submittedByName)\" has Terminated)"
                }
                trueParentPid = Int(node.ppid)
            }
        }else if let submittedByPlist = node.submittedByPlist {
            trueParentPlist = submittedByPlist
        } else if node.responsiblePid != pid{
            trueParentPid = Int(node.responsiblePid)
        } else {
            trueParentPid = Int(node.ppid)
        }
        

        var parentNode: Node<Any>?
        // Grab the parent of this node and assign this node as a child to it
        if let trueParentPid = trueParentPid {
            parentNode = nodePidDict[trueParentPid]
        } else if let trueParentPlist = trueParentPlist {
            parentNode = nodePlistDict[trueParentPlist]
        }
        
        // If this process was exec'ed we need assign the ppid to the launchdProgramPath
        // and then assign the ppid of the current pid to the launchdProgramPath
        if let execOldNode = execOldNode {
            parentNode?.children.append(execOldNode)
        } else {
            parentNode?.children.append(node)
        }
    }
    
    guard let rootNode = nodePidDict[1] else {
        exit(1)
    }
    
    return rootNode
}


func createNodeDictionary() -> [Int:Node<Any>] {
    var nodePidDict = [Int:Node<Any>]()
    
    // Go through each pid and create an initial tree node for it with all of the pid info we can find
    for pid in getActivePids() {
        // Skip kernel pid as we won't be able to collect info on it
        if pid == 0 {
           continue
        }

        // Create the tree node
        guard let ppid = getPPID(pid) else {
            print("Issue collecting pid information for \(pid). Skipping...")
            continue
        }
        
        let responsiblePid = getResponsiblePid(pid)
        let path = getPidPath(pid)
        let ts = getTimestamp(pid)
        
        let node = Node<Any>(pid as Any, ppid:ppid, procPath:path, responsiblePid: responsiblePid, timestamp: ts)

        if let launchdXPCInfo = getProcessInfo(UInt(pid)) {
            node.submittedByPid = getSubmittedByPid(pid, launchdXPCInfo)
            node.submittedByName =  getSubmittedByName(pid, launchdXPCInfo)
            node.submittedByPlist = getPlistPath(pid, launchdXPCInfo)
            node.launchdProgramPath = getLaunchdProgramPath(pid, launchdXPCInfo)
        }
        
        nodePidDict[pid] = node
    }
    
    return nodePidDict
}
