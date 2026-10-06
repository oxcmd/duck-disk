import Foundation
import Darwin

public struct ListeningPort: Identifiable, Hashable, Sendable {
    public var id: String { "\(proto)|\(address)|\(port)|\(pid)" }
    public let port: UInt16
    public let proto: String
    public let address: String
    public let pid: Int32
    public let process: String
}

/// Lists TCP sockets in LISTEN state and bound UDP sockets, via libproc per-process file descriptors.
/// Processes owned by other users (root daemons) are only visible with elevated rights and are skipped.
public enum PortScanner {
    public static func listening() -> [ListeningPort] {
        var out = Set<ListeningPort>()
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in SystemMonitor.allPIDs() {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdInfoSize + 8)
            let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else { continue }
            var name: String?
            for fd in fds.prefix(Int(got) / fdInfoSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                       Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
                let si = info.psi
                guard si.soi_family == AF_INET || si.soi_family == AF_INET6 else { continue }
                let entry: (UInt16, String, in_sockinfo)?
                if si.soi_kind == SOCKINFO_TCP {
                    let tcp = si.soi_proto.pri_tcp
                    entry = tcp.tcpsi_state == TSI_S_LISTEN
                        ? (UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)), "TCP", tcp.tcpsi_ini) : nil
                } else if si.soi_kind == SOCKINFO_IN && si.soi_protocol == IPPROTO_UDP {
                    let inInfo = si.soi_proto.pri_in
                    entry = (UInt16(bigEndian: UInt16(truncatingIfNeeded: inInfo.insi_lport)), "UDP", inInfo)
                } else {
                    entry = nil
                }
                guard let (port, proto, sock) = entry, port != 0 else { continue }
                if name == nil {
                    let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                    name = SystemMonitor.displayName(pid: pid, path: len > 0 ? String(cString: pathBuf) : "")
                }
                out.insert(ListeningPort(port: port, proto: proto, address: address(sock, family: si.soi_family),
                                         pid: pid, process: name ?? "\(pid)"))
            }
        }
        return out.sorted { ($0.port, $0.proto, $0.pid) < ($1.port, $1.proto, $1.pid) }
    }

    static func address(_ s: in_sockinfo, family: Int32) -> String {
        var addr = s.insi_laddr
        if family == AF_INET {
            var v4 = addr.ina_46.i46a_addr4
            if v4.s_addr == 0 { return "*" }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &v4, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let isAny = withUnsafeBytes(of: &addr.ina_6) { $0.allSatisfy { $0 == 0 } }
        if isAny { return "*" }
        inet_ntop(AF_INET6, &addr.ina_6, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }
}
