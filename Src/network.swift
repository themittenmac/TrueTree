//
//  Network.swift
//  TrueTree
//
//  Created by Jaron Bradley on 1/11/23.
//  Copyright © 2023 TheMittenMac. All rights reserved.
//

import Foundation
import ProcLib
// Handy reference -> https://stackoverflow.com/questions/29294491/swift-obtaining-ip-address-from-socket-returns-weird-value

struct NetworkConnection {
    let type: String?
    let pid: Int
    let family: String
    let source: String
    let sourcePort: UInt16
    let destination: String
    let destinationPort: UInt16
    let status: String
}

class NetworkConnections {
    private let PROC_PIDLISTFD_SIZE = Int32(MemoryLayout<proc_fdinfo>.stride)
    private let PROC_PIDFDSOCKETINFO_SIZE = Int32(MemoryLayout<socket_fdinfo>.stride)
    var connections = [NetworkConnection]()
    let pid: Int32
    
    init(pid: Int32) {
        self.pid = pid
        
        // get the size of the number of open files
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil , 0)
        
        // Returns 0 when access is denied (e.g. another user's process when not root)
        guard size > 0 else { return }

        //get list of open file descriptors
        let fdCapacity = Int(size / PROC_PIDLISTFD_SIZE)
        guard fdCapacity > 0 else { return }
        let fdInfo = UnsafeMutablePointer<proc_fdinfo>.allocate(capacity: fdCapacity)
        defer { fdInfo.deallocate() }
        
        // Pass the size of the buffer actually allocated, not the size the kernel reported,
        // so proc_pidinfo can never write past the end of fdInfo
        buildConnections(fdInfo, Int32(fdCapacity) * PROC_PIDLISTFD_SIZE)
    }
    
    private func getSocketFamily(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String? {
        switch socketInfoBuffer.pointee.psi.soi_family {
        
        case AF_INET:
            return "IPv4"
        
        case AF_INET6:
            return "IPv6"
        
        default:
            return nil
        }
    }
    
    private func getType(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String? {
        switch Int(socketInfoBuffer.pointee.psi.soi_kind) {
        case SOCKINFO_IN:
            return "UDP"
            
        case SOCKINFO_TCP:
            return "TCP"
            
        default:
            return nil
        }
    }
    
    private func getLocalPort(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>, socketType: String) -> UInt16 {
        var port = UInt16(0)
        
        if socketType == "UDP" {
            port = UInt16(socketInfoBuffer.pointee.psi.soi_proto.pri_in.insi_lport)
        }
        
        if socketType == "TCP" {
            port = UInt16(socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
        }
        
        return port.byteSwapped
    }
    
    private func getRemotePort(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>, socketType: String) -> UInt16 {
        if socketType == "UDP" {
            return 0
        }
        
        let port = UInt16(socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport)
        return port.byteSwapped
    }
    
    private func getIP4DestinationAddress(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String {
        var result = [CChar].init(repeating: 0, count: 16)
        inet_ntop(AF_INET, &socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4, &result, 16)
        let ipAddr = String(cString: result)
        
        return ipAddr
    }
    
    private func getIP6DestinationAddress(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String {
        var result = [CChar].init(repeating: 0, count: 128)
        inet_ntop(AF_INET6, &(socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_6), &result, 128);
        let ipAddr = String(cString: result)
        
        return ipAddr
    }
    
    private func getIP4SourceAddress(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String {
        var result = [CChar].init(repeating: 0, count: 16)
        inet_ntop(AF_INET, &socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4, &result, 16)
        let ipAddr = String(cString: result)
        
        return ipAddr
    }
    
    private func getIP6SourceAddress(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String {
        var result = [CChar].init(repeating: 0, count: 128)
        inet_ntop(AF_INET6, &(socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_6), &result, 128);
        let ipAddr = String(cString: result)
        
        return ipAddr
    }
    
    private func getStatus(socketInfoBuffer: UnsafeMutablePointer<socket_fdinfo>) -> String {
        var status = ""
        switch socketInfoBuffer.pointee.psi.soi_proto.pri_tcp.tcpsi_state {
        case TSI_S_CLOSED:
            status = "CLOSED"
        case TSI_S_LISTEN:
            status = "LISTENING"
        case TSI_S_SYN_SENT:
            status = "SYN SENT (active, have sent syn)"
        case TSI_S_SYN_RECEIVED:
            status = "SYN RECEIVED (have send and received syn)"
        case TSI_S_ESTABLISHED:
            status = "ESTABLISHED"
        case TSI_S__CLOSE_WAIT:
            status = "CLOSE WAIT (received fin, waiting for close) "
        case TSI_S_FIN_WAIT_1:
            status = "FIN WAIT1 (have closed, sent fin)"
        case TSI_S_CLOSING:
            status = "CLOSING (closed xchd FIN; await FIN ACK)"
        case TSI_S_LAST_ACK:
            status = "LAST ACK (had fin and close; await FIN ACK)"
        case TSI_S_FIN_WAIT_2:
            status = "FIN WAIT2 (have closed, fin is acked)"
        case TSI_S_TIME_WAIT:
            status = "TIME WAIT (in 2*msl quiet wait after close)"
        case TSI_S_RESERVED:
            status = "RESERVED"
        default:
            status = "Unknown"
        }
        
        return status
    }
    
    private func buildConnections(_ fdInfo: UnsafeMutablePointer<proc_fdinfo>, _ size: Int32) {
        // Use the byte count actually returned; fds can close between the size query and this call
        let bytesReturned = proc_pidinfo(self.pid, PROC_PIDLISTFDS, 0, fdInfo, size)
        guard bytesReturned > 0 else { return }
        
        // Go through each open file descriptor
        for x in 0..<Int(bytesReturned/PROC_PIDLISTFD_SIZE) {
            var localPort = UInt16(0)
            var destinationPort = UInt16(0)
            var destination = ""
            var source = ""
            
            // Skip if file descriptor is not a socket
            if PROX_FDTYPE_SOCKET != fdInfo[x].proc_fdtype { continue }
            
            // Get the socket info, skipping if an error occurs
            let socketInfo = UnsafeMutablePointer<socket_fdinfo>.allocate(capacity: 1)
            defer { socketInfo.deallocate() }
            
            if PROC_PIDFDSOCKETINFO_SIZE != proc_pidfdinfo(self.pid, fdInfo[x].proc_fd, PROC_PIDFDSOCKETINFO, socketInfo, PROC_PIDFDSOCKETINFO_SIZE) {
                continue
            }
            
            // Get IPv4 or IPV6. Skip other socket families (e.g. Unix domain sockets) but keep checking the remaining fds
            guard let family = getSocketFamily(socketInfoBuffer: socketInfo) else { continue }
            
            // Get UDP or TCP. Skip other socket kinds but keep checking the remaining fds
            guard let type = getType(socketInfoBuffer: socketInfo) else { continue }
            
            // If this is a UDP connection
            if type == "UDP" {
                localPort = getLocalPort(socketInfoBuffer: socketInfo, socketType: type)
                
            } else if type == "TCP" {
                // Far more details can be collected from TCP connections
                localPort = getLocalPort(socketInfoBuffer: socketInfo, socketType: type)
                destinationPort = UInt16(socketInfo.pointee.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport).byteSwapped
                
                // If this is a IPv4 address get the local and remote connections
                if family == "IPv4" {
                    destination = getIP4DestinationAddress(socketInfoBuffer: socketInfo)
                    source = getIP4SourceAddress(socketInfoBuffer: socketInfo)
                    
                } else if family == "IPv6" {
                    destination = getIP6DestinationAddress(socketInfoBuffer: socketInfo)
                    source = getIP6SourceAddress(socketInfoBuffer: socketInfo)
                }
            }
            
            // TCP state only exists for TCP sockets. For UDP this part of the union holds unrelated data.
            let status = type == "TCP" ? getStatus(socketInfoBuffer: socketInfo) : ""
            
            let n = NetworkConnection(type: type,
                                      pid: Int(pid),
                                      family: family,
                                      source: source,
                                      sourcePort: localPort,
                                      destination: destination,
                                      destinationPort: destinationPort,
                                      status: status)
            
            connections.append(n)
        }
    }
}
