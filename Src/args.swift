//
//  args.swift
//  TrueTree
//
//  Created by Jaron Bradley on 2/20/20.
//  2020 TheMittenMac
//

import Foundation


class ArgManager {
    
    var color = true
    var timestamps = false
    var standardMode = false
    var sources = false
    var timelineMode = true
    var network = true
    var toFile: String?
    let availableArgs = ["--nocolor", "--timeline", "--timestamps", "-o", "--standard", "--version", "--sources", "--nonetwork"]
    
    init(suppliedArgs: [String]) {
        setArgs(suppliedArgs)
    }
    
    func setArgs(_ args:[String]) {
        for (x,arg) in (args).enumerated() {
            if x == 0 || !arg.starts(with: "-") {
                continue
            } else if arg == "-h" || arg == "--help" {
                self.printHelp()
            } else if arg == "--nocolor" {
                color.toggle()
            } else if arg == "--timestamps" {
                timestamps.toggle()
            } else if arg == "--standard" {
                standardMode.toggle()
            } else if arg == "--sources" {
                sources.toggle()
            } else if arg == "--timeline" {
                timelineMode.toggle()
            } else if arg == "--nonetwork" {
                network.toggle()
            } else if arg == "--version" {
                print(version)
                exit(1)
            } else if arg == "-o" {
                if args.count > x+1 && !availableArgs.contains(args[x+1]) {
                    toFile = args[x+1]
                } else {
                    toFile = "tree_output.txt"
                }
            } else {
                print("Unidentified argument " + arg)
                exit(1)
            }
        }
    }
    
    func printHelp() {
        print("--nocolor -> Do not color code items in output")
        print("--timeline  -> Sort and print all processes by their creation timestamp (Non-Tree Mode)")
        print("--timestamps -> Include process timestamps")
        print("--standard -> Print the standard Unix tree instead of TrueTree")
        print("--sources -> Print the source of where each processes parent came from")
        print("--nonetwork -> Do not print network connection")
        print("--version -> Print the TrueTree version number")
        print("-o <filename> -> output to file")
        exit(1)
    }
}
