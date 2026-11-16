import Foundation
import Darwin

public enum LANIPv4 {
    public static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
    public static func interfaces() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }; defer { freeifaddrs(list) }
        var current = list, result: [String] = []
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String in
                var value = pointer.pointee.sin_addr; var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)); return String(cString: buffer)
            }
            if !result.contains(ip) { result.append(ip) }
        }
        return result
    }
    public static func route(to peer: String) throws -> (local: String, peer: String) {
        guard isLocal(peer) else { throw TVError.message("DLNA 需要电视的局域网 IPv4 地址。请将 Mac 和电视连接到同一网络。") }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw TVError.message("无法建立电视连接。") }; defer { Darwin.close(fd) }
        var remote = sockaddr_in(); remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET); remote.sin_port = UInt16(1900).bigEndian
        guard inet_pton(AF_INET, peer, &remote.sin_addr) == 1 else { throw TVError.message("电视地址无效。") }
        let connected = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw TVError.message("无法连接电视，请检查是否处于同一局域网。") }
        var local = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var address = local.sin_addr, buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard status == 0, inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { throw TVError.message("无法获取连接电视所用的网络地址。") }
        return (String(cString: buffer), peer)
    }
}

public struct SSDPResponse: Sendable {
    public var location: URL
    public static func parse(_ data: Data, sender: String) -> SSDPResponse? {
        guard data.count <= 16_384, LANIPv4.isLocal(sender), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first?.uppercased().hasPrefix("HTTP/1.1 200") == true else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let value = fields["location"], let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host == sender,
              url.user == nil, url.password == nil else { return nil }
        return SSDPResponse(location: url)
    }
}

/// IPv4 SSDP discovery. The socket and all file-descriptor access stay on queue.
public final class DLNADiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TVBox.DLNA.discovery")
    private var source: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var generation = UUID()
    private var seen = Set<URL>()
    public init() {}
    public func search(onLocation: @escaping @Sendable (URL) -> Void, onFinish: @escaping @Sendable () -> Void) {
        queue.async {
            self.stopOnQueue()
            let token = UUID(); self.generation = token; self.seen.removeAll()
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { onFinish(); return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
            let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0 else { Darwin.close(fd); onFinish(); return }
            self.socketFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                guard let self, self.generation == token else { return }
                while true {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    var remote = sockaddr_in(); var count = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let size = withUnsafeMutablePointer(to: &remote) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &count) }
                    }
                    guard size > 0 else { break }
                    var ip = remote.sin_addr, value = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &ip, &value, socklen_t(value.count))
                    if self.seen.count < 64, let response = SSDPResponse.parse(Data(buffer.prefix(size)), sender: String(cString: value)), self.seen.insert(response.location).inserted {
                        onLocation(response.location)
                    }
                }
            }
            source.setCancelHandler { Darwin.close(fd) }; self.source = source; source.resume()
            for delay in [0.0, 2.0, 4.0] {
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == token else { return }
                    var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(1900).bigEndian
                    inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
                    let interfaces = LANIPv4.interfaces()
                    for ip in interfaces.isEmpty ? ["0.0.0.0"] : interfaces {
                        var address = in_addr(); inet_pton(AF_INET, ip, &address)
                        _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size))
                        for type in ["urn:schemas-upnp-org:device:MediaRenderer:1", "ssdp:all"] {
                            let packet = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(type)\r\n\r\n".utf8)
                            packet.withUnsafeBytes { bytes in
                                withUnsafePointer(to: &target) { pointer in
                                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                                }
                            }
                        }
                    }
                }
            }
            self.queue.asyncAfter(deadline: .now() + 7) { [weak self] in
                guard let self, self.generation == token else { return }; self.stopOnQueue(); onFinish()
            }
        }
    }
    public func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() { generation = UUID(); source?.cancel(); source = nil; socketFD = -1 }
    deinit { source?.cancel() }
}
