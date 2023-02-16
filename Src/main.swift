//
//  main.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/22/19.
//  2020 TheMittenMac
//

import Foundation

let version = 0.6

// Go through command line arguments and set accordingly
let argManager = ArgManager(suppliedArgs:CommandLine.arguments)


// Must be root to gather all pid information
if (NSUserName() != "root" && setuid(0) != 0) {
    print("This tool must be run as root in order to view all pid information")
    print("Exiting...")
    exit(1)
}


// Build all process objects
let pc = ProcessCollector()

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
    rootNode?.printTree()
    exit(1)
}


// If timeline mode is active
if argManager.timelineMode == false {
    pc.printTimeline(outputFile: argManager.toFile)
    exit(1)
}

// Create a TrueTree
for proc in pc.processes {
    
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
    
    // Create an on the fly node for any network connections this pid has and add them to itself
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
}

// print the launchd pid and all of it's children
rootNode?.printTree()

