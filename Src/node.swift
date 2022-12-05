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
    private(set) var children: [Node]
    
    init(_ pid: Int, path: String, timestamp: String, source: String) {
        self.pid = pid
        self.path = path
        self.timestamp = timestamp
        self.source = source
        children = []
    }
    
    func add(child: Node) {
        children.append(child)
    }
}

// Extension for printing the tree. Great approach. Currently uses global vars from argmanager
//https://stackoverflow.com/questions/46371513/printing-a-tree-with-indents-swift
extension Node {
    func treeLines(_ nodeIndent:String="", _ childIndent:String="") -> [String] {
        var text = ""
        if path.hasSuffix(".plist") {
            if argManager.color { text = "\(path.blue)" } else { text = "\(path)" }
        } else {
            if argManager.color {
                text = "\(path)    \(String(pid).magenta)"
                if argManager.timestamps { text += "    \(timestamp.cyan)"}
                if argManager.sources { text += "    Aquired parent from -> \(source)".red }
            } else {
                text = "\(path)    \(String(pid))"
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

