import Foundation
import Darwin
import TVBoxCore

/// Bonjour resolves the receiver's advertised endpoint; no hard-coded TV IPs.
@MainActor final class AirPlayVideoDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var timeout: Task<Void, Never>?
    private var found: ((DLNADevice) -> Void)?
    private var finished: (() -> Void)?
    private var running = false
    func search(found: @escaping (DLNADevice) -> Void, finished: @escaping () -> Void) {
        stop(); self.found = found; self.finished = finished; running = true
        let browser = NetServiceBrowser(); self.browser = browser
        browser.delegate = self; browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
            guard let self else { return }; let done = self.finished; self.stop(); done?()
        }
    }
    func stop() {
        running = false; timeout?.cancel(); timeout = nil; browser?.stop(); browser?.delegate = nil; browser = nil
        services.values.forEach { $0.delegate = nil; $0.stop() }; services.removeAll(); found = nil; finished = nil
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.browser === browser, self.services.count < 64 else { return }
            let key = service.domain + service.name
            guard self.services[key] == nil else { return }
            self.services[key] = service; service.delegate = self; service.resolve(withTimeout: 4)
        }
    }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            guard let self, self.running, self.services[sender.domain + sender.name] === sender,
                  let txt = sender.txtRecordData() else { return }
            let fields = NetService.dictionary(fromTXTRecord: txt)
            func value(_ key: String) -> String { fields[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
            let status = UInt64(value("flags").replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            let password = ["true", "1"].contains(value("pw").lowercased()) || status & 0x288 != 0
            for data in sender.addresses ?? [] {
                guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
                let ip: String? = data.withUnsafeBytes { bytes in
                    guard let raw = bytes.baseAddress, raw.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == UInt8(AF_INET) else { return nil }
                    var address = raw.loadUnaligned(as: sockaddr_in.self).sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    return inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
                }
                if let ip, let device = try? AirPlayVideoProtocol.device(name: sender.name, id: sender.domain + sender.name,
                            address: ip, port: sender.port, features: value("features"), passwordRequired: password) {
                    self.found?(device); break
                }
            }
        }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor [weak self] in guard let self, self.running, self.browser === browser else { return }; let done = self.finished; self.stop(); done?() }
    }
}
