//
//  main.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/22/19.
//  2020 TheMittenMac
//

import Foundation

let version = 0.9

// Go through command line arguments and set accordingly
let argManager = ArgManager(suppliedArgs:CommandLine.arguments)

// libquarantine can only return responsible pids for other users' processes when running as root.
// As root it is the default; otherwise, or when --acquire-responsible-via-coalition is passed,
// responsible pids are estimated from process coalitions.
let responsibleViaLibquarantine = geteuid() == 0 && !argManager.responsibleViaCoalition

// Build all process objects. In standard mode only pid/ppid data is collected.
let pc = ProcessCollector(standardMode: argManager.standardMode,
                          responsibleViaLibquarantine: responsibleViaLibquarantine)

// Get the launchd pid for future reference
let rootNode = pc.getNodeForPid(1)
guard rootNode != nil else {
    print("Could not find the launchd process. Aborting...")
    exit(1)
}


// If standard tree mode is active
if argManager.standardMode {
    for proc in pc.processes {
        // Get the parent of the process
        let parentNode = pc.getNodeForPid(proc.ppid)

        // Assign this process as a child
        parentNode?.add(child: proc.node)
    }
    if argManager.json {
        let exporter = JSONExporter(collector: pc, mode: .standard, includeNetwork: false, responsibleViaLibquarantine: false)
        JSONExporter.write(exporter.treeDocument(root: rootNode!), to: argManager.toFile)
    } else {
        rootNode?.printTree()
    }
    exit(0)
}


// If timeline mode is active
if argManager.timelineMode == false {
    if argManager.json {
        let exporter = JSONExporter(collector: pc, mode: .timeline, includeNetwork: argManager.network,
                                    responsibleViaLibquarantine: responsibleViaLibquarantine)
        JSONExporter.write(exporter.timelineDocument(), to: argManager.toFile)
    } else {
        pc.printTimeline(outputFile: argManager.toFile)
    }
    exit(0)
}

// Create a TrueTree
for proc in pc.processes {
    
    // Create an on the fly node for any network connections this pid has and add them to itself.
    // Done first so processes placed under a plist below also keep their connections.
    if argManager.network {
        for x in proc.network {
            if let type = x.type {
                var displayString = ""
                if type == "TCP" {
                    displayString = "\(type) - \(x.source):\(x.sourcePort) -> \(x.destination):\(x.destinationPort) - \(x.status)"
                } else {
                    displayString = "\(type) - Local Port: \(x.sourcePort)"
                }
                
                let networkNode = Node(-1, path: "none", timestamp: "00:00:00", source: "Network", displayString: displayString)
                proc.node.add(child: networkNode)
            }
        }
    }
    
    // Create an on the fly node for a plist if one exists
    if let plist = proc.submittedByPlist {
        // Check if this plist is already in the tree
        if let existingPlistNode = rootNode?.searchPlist(value: plist) {
            existingPlistNode.add(child: proc.node)
            continue
        }
        
        let plistNode = Node(-1, path: plist, timestamp: "00:00:00", source: "launchd_xpc", displayString: plist)
        rootNode?.add(child: plistNode)
        plistNode.add(child: proc.node)
        continue
    }
    
    // Otherwise add the process as a child to its true parent
    let parentNode = pc.getNodeForPid(proc.trueParentPid)
    parentNode?.add(child: proc.node)
}

// print the launchd pid and all of it's children
if argManager.json {
    let exporter = JSONExporter(collector: pc, mode: .truetree, includeNetwork: argManager.network,
                                responsibleViaLibquarantine: responsibleViaLibquarantine)
    JSONExporter.write(exporter.treeDocument(root: rootNode!), to: argManager.toFile)
} else {
    rootNode?.printTree()
}

