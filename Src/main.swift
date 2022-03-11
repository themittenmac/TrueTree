//
//  main.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/22/19.
//  2020 TheMittenMac
//

import Foundation

let version = 0.2

// Go through command line arguments and set accordingly
let argManager = ArgManager(suppliedArgs:CommandLine.arguments)

// Must be root to gather all pid information
if (NSUserName() != "root") {
    print("This tool must be run as root in order to view all pid information")
    print("Exiting...")
    exit(1)
}

// Build nodes
let nodePidDict = createNodeDictionary()

// Declare a variable for the root node
let treeRootNode: Node<Any>

// Run in Standard Tree or TrueTree Mode
if argManager.standardMode {
    treeRootNode = buildStandardTree(nodePidDict)
} else {
    treeRootNode = buildTrueTree(nodePidDict)
}

// Print the tree to file or to Terminal
treeRootNode.printTree(argManager.color, argManager.timestamps, argManager.treeMode, argManager.toFile)
