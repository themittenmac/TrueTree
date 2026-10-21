//
//  json.swift
//  TrueTree
//
//  JSON export for the TrueTree, standard tree, and timeline views.
//

import Foundation

// MARK: - Output model

struct JSONNetworkConnection: Encodable {
    let `protocol`: String
    let family: String
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String?
    let remotePort: UInt16?
    let state: String?
    
    init(_ c: NetworkConnection) {
        let isTCP = c.type == "TCP"
        self.protocol = c.type ?? "Unknown"
        family = c.family
        localAddress = c.source
        localPort = c.sourcePort
        // Only TCP has a peer and a state
        remoteAddress = isTCP ? c.destination : nil
        remotePort = isTCP ? c.destinationPort : nil
        state = isTCP ? c.status : nil
    }
    
    enum CodingKeys: String, CodingKey {
        case `protocol`, family, localAddress, localPort, remoteAddress, remotePort, state
    }
    
    // Always emit every key (null when missing) so consumers see a stable shape
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.protocol, forKey: .protocol)
        try c.encode(family, forKey: .family)
        try c.encode(localAddress, forKey: .localAddress)
        try c.encode(localPort, forKey: .localPort)
        try c.encode(remoteAddress, forKey: .remoteAddress)
        try c.encode(remotePort, forKey: .remotePort)
        try c.encode(state, forKey: .state)
    }
}

struct JSONProcess: Encodable {
    let pid: Int
    let ppid: Int
    let name: String
    let path: String
    let startTime: String
    let trueParentPid: Int
    let parentSource: String
    let responsiblePid: Int?
    let submittedByPid: Int?
    let submittedByPlist: String?
    let networkConnections: [JSONNetworkConnection]?
    /// nil for the flat timeline, where there is no hierarchy
    let children: [JSONEntry]?
    
    enum CodingKeys: String, CodingKey {
        case type, pid, ppid, name, path, startTime, trueParentPid, parentSource
        case responsiblePid, submittedByPid, submittedByPlist, networkConnections, children
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("process", forKey: .type)
        try c.encode(pid, forKey: .pid)
        try c.encode(ppid, forKey: .ppid)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(trueParentPid, forKey: .trueParentPid)
        try c.encode(parentSource, forKey: .parentSource)
        try c.encode(responsiblePid, forKey: .responsiblePid)
        try c.encode(submittedByPid, forKey: .submittedByPid)
        try c.encode(submittedByPlist, forKey: .submittedByPlist)
        try c.encodeIfPresent(networkConnections, forKey: .networkConnections)
        try c.encodeIfPresent(children, forKey: .children)
    }
}

struct JSONPlist: Encodable {
    let path: String
    let children: [JSONEntry]
    
    enum CodingKeys: String, CodingKey { case type, path, children }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("plist", forKey: .type)
        try c.encode(path, forKey: .path)
        try c.encode(children, forKey: .children)
    }
}

indirect enum JSONEntry: Encodable {
    case process(JSONProcess)
    case plist(JSONPlist)
    
    func encode(to encoder: Encoder) throws {
        switch self {
        case .process(let p): try p.encode(to: encoder)
        case .plist(let p): try p.encode(to: encoder)
        }
    }
}

struct JSONDocument: Encodable {
    let truetreeVersion: String
    let mode: String
    let collectedAt: String
    let hostname: String
    let responsiblePidMethod: String?
    /// Tree views only: everything reachable from launchd
    let tree: JSONEntry?
    /// Tree views only: processes whose parent could not be found, so they are not in `tree`
    let unattachedProcesses: [JSONEntry]?
    /// Timeline view only: every process sorted by start time
    let processes: [JSONEntry]?
    
    enum CodingKeys: String, CodingKey {
        case truetreeVersion, mode, collectedAt, hostname, responsiblePidMethod, tree, unattachedProcesses, processes
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(truetreeVersion, forKey: .truetreeVersion)
        try c.encode(mode, forKey: .mode)
        try c.encode(collectedAt, forKey: .collectedAt)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(responsiblePidMethod, forKey: .responsiblePidMethod)
        try c.encodeIfPresent(tree, forKey: .tree)
        try c.encodeIfPresent(unattachedProcesses, forKey: .unattachedProcesses)
        try c.encodeIfPresent(processes, forKey: .processes)
    }
}

// MARK: - Exporter

struct JSONExporter {
    enum Mode: String {
        case truetree, standard, timeline
    }
    
    let collector: ProcessCollector
    let mode: Mode
    let includeNetwork: Bool
    let responsibleViaLibquarantine: Bool
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()
    
    /// Converts a process to its JSON form. Pass nil children for the flat timeline.
    private func entry(for p: Process, children: [JSONEntry]?) -> JSONProcess {
        // Standard mode never collects these, so report them as unknown rather than guessing
        let full = mode != .standard
        let submitted = (p.submittedByPid ?? 0) > 1 ? p.submittedByPid : nil
        return JSONProcess(
            pid: p.pid,
            ppid: p.ppid,
            name: URL(fileURLWithPath: p.path).lastPathComponent,
            path: p.path,
            startTime: Self.isoFormatter.string(from: p.startDate),
            trueParentPid: p.trueParentPid,
            parentSource: p.source,
            responsiblePid: full ? p.responsiblePid : nil,
            submittedByPid: full ? submitted : nil,
            submittedByPlist: full ? p.submittedByPlist : nil,
            networkConnections: (full && includeNetwork) ? p.network.filter { $0.type != nil }.map(JSONNetworkConnection.init) : nil,
            children: children
        )
    }
    
    /// Walks the Node tree built in main.swift so the JSON hierarchy matches the printed tree exactly
    private func entry(for node: Node, lookup: [Int: Process], visited: inout Set<Int>) -> JSONEntry? {
        // Network connections are emitted as structured data on the process instead of as child nodes
        if node.source == "Network" { return nil }
        
        var children = [JSONEntry]()
        for child in node.children {
            if let e = entry(for: child, lookup: lookup, visited: &visited) { children.append(e) }
        }
        
        if node.pid == -1 {
            return .plist(JSONPlist(path: node.path, children: children))
        }
        
        guard let p = lookup[node.pid] else { return nil }
        visited.insert(p.pid)
        return .process(entry(for: p, children: children))
    }
    
    private func document(tree: JSONEntry?, unattached: [JSONEntry]?, processes: [JSONEntry]?) -> JSONDocument {
        var hostBuffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
        let hostname = gethostname(&hostBuffer, hostBuffer.count) == 0 ? String(cString: hostBuffer) : ""
        
        return JSONDocument(truetreeVersion: String(version),
                            mode: mode.rawValue,
                            collectedAt: Self.isoFormatter.string(from: Date()),
                            hostname: hostname,
                            responsiblePidMethod: mode == .standard ? nil : (responsibleViaLibquarantine ? "libquarantine" : "coalition"),
                            tree: tree,
                            unattachedProcesses: unattached,
                            processes: processes)
    }
    
    /// TrueTree and standard views: nested from launchd down
    func treeDocument(root: Node) -> JSONDocument {
        let lookup = Dictionary(collector.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<Int>()
        let tree = entry(for: root, lookup: lookup, visited: &visited)
        
        // Anything not reached from launchd silently vanishes from the text tree. Keep it here.
        let unattached = collector.processes
            .filter { !visited.contains($0.pid) }
            .map { JSONEntry.process(entry(for: $0, children: nil)) }
        
        return document(tree: tree, unattached: unattached, processes: nil)
    }
    
    /// Timeline view: flat, sorted by start time
    func timelineDocument() -> JSONDocument {
        let procs = collector.processes.map { JSONEntry.process(entry(for: $0, children: nil)) }
        return document(tree: nil, unattached: nil, processes: procs)
    }
    
    /// Encodes and either prints the JSON or writes it to outputFile
    static func write(_ doc: JSONDocument, to outputFile: String?) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if #available(macOS 10.15, *) {
            encoder.outputFormatting.insert(.withoutEscapingSlashes)
        }
        
        let data: Data
        do {
            data = try encoder.encode(doc)
        } catch {
            print("Could not encode TrueTree output as JSON: \(error)")
            exit(1)
        }
        
        if let outputFile = outputFile {
            do {
                try data.write(to: URL(fileURLWithPath: outputFile), options: .atomic)
            } catch {
                print("Could not write TrueTree output to specified file")
            }
        } else if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
