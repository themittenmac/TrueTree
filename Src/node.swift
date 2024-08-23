//
//  tree.swift
//  TrueTree
//
//  Created by Jaron Bradley on 11/2/19.
//  2020 TheMittenMac
//


import Foundation


final class Node {
    let pid: Int
    let path: String
    let timestamp: String
    let source: String
    let displayString: String
    private(set) var children: [Node]
    
    var fileName: String {
        if let fileName = path.components(separatedBy: "/").last {
            return fileName
        }
        
        return path
    }
    
    init(_ pid: Int, path: String, timestamp: String, source: String, displayString: String) {
        self.pid = pid
        self.path = path
        self.timestamp = timestamp
        self.source = source
        self.displayString = displayString
        children = []
    }
    
    func add(child: Node) {
        children.append(child)
    }
    
    func searchPlist(value: String) -> Node? {
        if value == self.path {
            return self
        }
        
        for child in children {
            if let found = child.searchPlist(value: value) {
                return found
            }
        }
        return nil
    }
}


// Extension for printing the tree. Great approach. Currently uses global vars from argmanager
//https://stackoverflow.com/questions/46371513/printing-a-tree-with-indents-swift
extension Node {
    func treeLines(_ nodeIndent:String="", _ childIndent:String="") -> [String] {
        var text = ""
        if path.hasSuffix(".plist") {
            if argManager.color { text = "\(displayString.blue)" } else { text = "\(displayString)" }
            
        } else if displayString.hasPrefix("UDP") || displayString.hasPrefix("TCP") {
            if argManager.color { text = "\(displayString.yellow)" } else { text = "\(displayString)" }
            
        } else {
            if argManager.color {
                if argManager.showpath {
                    text = "\(displayString)"
                } else {
                    text = "\(fileName)"
                }
                if argManager.showpid { text += "    \(String(pid).magenta)"}
                if argManager.timestamps { text += "    \(timestamp.cyan)"}
                if argManager.sources { text += "    Aquired parent from -> \(source)".red }
            } else {
                text = "\(displayString)    \(String(pid))"
                if argManager.timestamps { text += "    \(timestamp)"}
                if argManager.sources { text += "    Aquired parent from -> \(source)" }
            }
            
        }
        
        return [ nodeIndent + text ]
           + children.enumerated().map{ ($0 < children.count-1, $1) }
            .flatMap{ $0 ? $1.treeLines("┣╸","┃ ") : $1.treeLines("┗╸","  ") }
             .map{ childIndent + $0 }
        
    }

    func printTree() {
        let tree = treeLines().joined(separator:"\n")
        
        if let toFile = argManager.toFile {
            let fileUrl = URL(fileURLWithPath: toFile)
            do {
                try tree.write(to: fileUrl, atomically: true, encoding: String.Encoding.utf8)
            } catch {
                print("Could not write TrueTree output to specified file")
            }
        } else {
            print(tree)
        }
    }
}

