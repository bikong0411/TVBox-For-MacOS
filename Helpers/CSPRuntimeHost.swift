// A private process supervisor. EOF from TVBox also handles application crashes:
// shut down Android, then reap both QEMU and its private network helper.
import Foundation
import CryptoKit
import Darwin

enum HostFailure: String, Error {
    case invalidRequest = "BAD_REQUEST", missingAssets = "ASSETS_MISSING"
    case invalidAssets = "ASSETS_INVALID", inUse = "RUNTIME_IN_USE"
    case storage = "STORAGE_FAILED", network = "NETWORK_FAILED", launch = "LAUNCH_FAILED"
}
struct Manifest: Decodable {
    let version: Int
    let files: [String: String]
}
struct Request: Decodable { let assets: String; let storage: String }
let files = FileManager.default
var children: [Process] = []
var serial: Pipe?
var privateDirectory: URL?
var lockFD: Int32 = -1
var shutdownRequested: sig_atomic_t = 0

func emit(_ value: [String: Any]) {
    if let bytes = try? JSONSerialization.data(withJSONObject: value) {
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
}
func digest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HostFailure.network }; defer { close(fd) }
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw HostFailure.network }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { throw HostFailure.network }
    return UInt16(bigEndian: address.sin_port)
}
func forward(socketPath: String, port: UInt16) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HostFailure.network }; defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HostFailure.network }
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in path.withUnsafeBytes { bytes.copyBytes(from: $0) } }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw HostFailure.network }
    let body = try JSONSerialization.data(withJSONObject: ["local": "127.0.0.1:\(port)", "remote": "192.168.127.2:18793"])
    let request = Data("POST /services/forwarder/expose HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    try request.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset, 0)
            guard count > 0 else { throw HostFailure.network }; offset += count
        }
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0, String(decoding: buffer.prefix(count), as: UTF8.self).hasPrefix("HTTP/1.1 200") else { throw HostFailure.network }
}
func start(_ executable: URL, _ arguments: [String], work: URL, input: Pipe? = nil, diagnostic: URL? = nil) throws -> Process {
    let process = Process(); process.executableURL = executable; process.arguments = arguments
    process.currentDirectoryURL = work
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": work.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    if let diagnostic {
        files.createFile(atPath: diagnostic.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: diagnostic)
        process.standardOutput = log; process.standardError = log
    }
    process.standardInput = input ?? FileHandle.nullDevice
    try process.run(); children.append(process); return process
}
func cleanUp() {
    if let vm = children.last, children.count == 2, vm.isRunning, let serial {
        try? serial.fileHandleForWriting.write(contentsOf: Data("reboot -p\n".utf8))
        let deadline = Date().addingTimeInterval(8)
        while vm.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }
    for child in children.reversed() {
        if child.isRunning { child.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }
    if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    if let privateDirectory { try? files.removeItem(at: privateDirectory) }
}

func run() throws {
    guard let line = readLine(), line.utf8.count < 8192,
          let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data),
          request.assets.hasPrefix("/"), request.storage.hasPrefix("/") else { throw HostFailure.invalidRequest }
    let assets = URL(fileURLWithPath: request.assets, isDirectory: true)
    guard let bytes = try? Data(contentsOf: assets.appendingPathComponent("manifest.json")), bytes.count < 65536,
          let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes), manifest.version == 1 else { throw HostFailure.missingAssets }
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif
    let executable = "\(architecture)/bin/qemu-system-aarch64"
    let needed = [executable, "\(architecture)/lib/libglib-2.0.0.dylib", "gvproxy", "kernel", "bootstrap.cpio.gz", "system.qcow2", "data-template.qcow2"]
    for name in needed {
        guard let expected = manifest.files[name], expected.count == 64,
              (try? digest(assets.appendingPathComponent(name))) == expected else { throw HostFailure.invalidAssets }
    }
    let storage = URL(fileURLWithPath: request.storage, isDirectory: true)
    try files.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    lockFD = open(storage.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw HostFailure.inUse }
    let disk = storage.appendingPathComponent("data-v1.qcow2")
    if !files.fileExists(atPath: disk.path) {
        do { try files.copyItem(at: assets.appendingPathComponent("data-template.qcow2"), to: disk); try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disk.path) }
        catch { throw HostFailure.storage }
    }
    // A short Unix socket path is required on macOS. The directory is private,
    // randomly named and contains no host-folder shares or user documents.
    let work = URL(fileURLWithPath: "/private/tmp/tvbox-csp-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); privateDirectory = work
    let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    let networkToken = work.appendingPathComponent("network-token")
    try Data(UUID().uuidString.utf8).write(to: networkToken, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: networkToken.path)
    let socketURL = work.appendingPathComponent("network.sock")
    let networkPort = try freePort(), workerPort = try freePort()
    let network = try start(assets.appendingPathComponent("gvproxy"), ["-listen", "unix://" + socketURL.path, "-listen-qemu", "tcp://127.0.0.1:\(networkPort)", "-ssh-port", "-1", "-api-token-file", networkToken.path], work: work)
    let deadline = Date().addingTimeInterval(8)
    while !files.fileExists(atPath: socketURL.path) && network.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    guard network.isRunning, files.fileExists(atPath: socketURL.path) else { throw HostFailure.network }
    try forward(socketPath: socketURL.path, port: workerPort)
    serial = Pipe()
    let kernelArguments = "console=ttyAMA0 loglevel=1 security=selinux enforcing=0 androidboot.hardware=redroid androidboot.selinux=permissive androidboot.tvbox_csp_token=\(token)"
    func drivePath(_ url: URL) -> String { url.path.replacingOccurrences(of: ",", with: ",,") }
    var arguments = ["-M", "virt", "-m", "2048M", "-smp", "2", "-kernel", assets.appendingPathComponent("kernel").path, "-initrd", assets.appendingPathComponent("bootstrap.cpio.gz").path, "-append", kernelArguments, "-display", "none", "-monitor", "none", "-serial", "stdio", "-no-reboot", "-drive", "if=none,id=system,file=\(drivePath(assets.appendingPathComponent("system.qcow2"))),format=qcow2,snapshot=on", "-device", "virtio-blk-device,drive=system", "-drive", "if=none,id=data,file=\(drivePath(disk)),format=qcow2", "-device", "virtio-blk-device,drive=data", "-netdev", "socket,id=net0,connect=127.0.0.1:\(networkPort)", "-device", "virtio-net-device,netdev=net0,mac=5a:94:ef:e4:0c:ee", "-object", "rng-random,id=rng0,filename=/dev/urandom", "-device", "virtio-rng-device,rng=rng0"]
    #if arch(arm64)
    if CommandLine.arguments.contains("--emulate") {
        arguments[arguments.firstIndex(of: "-smp")!+1] = "1"
        arguments += ["-accel", "tcg,thread=single", "-cpu", "cortex-a72"]
    } else {
        arguments += ["-accel", "hvf", "-cpu", "host"]
    }
    #else
    arguments[arguments.firstIndex(of: "-smp")!+1] = "2"
    arguments += ["-accel", "tcg,thread=multi", "-cpu", "max"]
    #endif
    if CommandLine.arguments.contains("--diagnostics"), let index = arguments.firstIndex(of: "-append") {
        arguments[index+1] = arguments[index+1].replacingOccurrences(of: "loglevel=1", with: "loglevel=6 printk.devkmsg=on")
    }
    let diagnostic = CommandLine.arguments.contains("--diagnostics") ? storage.appendingPathComponent("test-console-private.log") : nil
    _ = try start(assets.appendingPathComponent(executable), arguments, work: work, input: serial, diagnostic: diagnostic)
    emit(["endpoint": "http://127.0.0.1:\(workerPort)", "token": token])
    // readLine blocks only this helper. Parent exit closes the pipe even when
    // TVBox cannot run its normal termination handlers.
    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    var nextDiagnostic = Date().addingTimeInterval(15)
    while shutdownRequested == 0 && children.allSatisfy({ $0.isRunning }) {
        let result = poll(&input, 1, 250)
        if result > 0 { break }
        if result < 0 && errno != EINTR { break }
        if diagnostic != nil && Date() > nextDiagnostic {
            try? serial?.fileHandleForWriting.write(contentsOf: Data("getprop sys.boot_completed; logcat -b crash -d -t 60; logcat -d -t 100; ps -A -o PID,NAME\n".utf8))
            nextDiagnostic = Date().addingTimeInterval(30)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in shutdownRequested = 1 }
signal(SIGINT) { _ in shutdownRequested = 1 }
defer { cleanUp() }
do { try run() }
catch { emit(["error": (error as? HostFailure)?.rawValue ?? "LAUNCH_FAILED"]) }
