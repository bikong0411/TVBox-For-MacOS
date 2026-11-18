import Foundation

/// Owns a supervisor through an anonymous pipe. Closing it requests graceful
/// Android shutdown; EOF also reaches the supervisor if the application crashes.
private final class CSPHostProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var answer: Result<CSPWorkerConnection, Error>?
    private var stopped = false
    var running: Bool { process.isRunning }
    var result: Result<CSPWorkerConnection, Error>? { lock.lock(); defer { lock.unlock() }; return answer }
    init(executable: URL, assets: URL, storage: URL) throws {
        process.executableURL = executable
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        do {
            try process.run()
            let request = try JSONSerialization.data(withJSONObject: ["assets": assets.path, "storage": storage.path])
            try input.fileHandleForWriting.write(contentsOf: request + Data([10]))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            throw error
        }
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard answer == nil else { return }
        buffer.append(data)
        if buffer.count > 8192 || data.isEmpty {
            answer = .failure(TVError.message("内置爬虫运行时启动中断，请重试。")); return
        }
        guard let end = buffer.firstIndex(of: 10) else { return }
        do {
            guard let object = try JSONSerialization.jsonObject(with: buffer.prefix(upTo: end)) as? [String: String] else { throw TVError.message("运行时启动响应无效。") }
            if let code = object["error"] {
                let message: String
                switch code {
                case "RUNTIME_IN_USE": message = "另一个 TVBox 正在使用爬虫运行时，请关闭另一个实例后重试。"
                case "ASSETS_MISSING", "ASSETS_INVALID": message = "内置爬虫运行时文件缺失或校验失败，请重新安装完整版本。"
                case "STORAGE_FAILED": message = "无法创建爬虫运行时数据，请检查磁盘空间与写入权限。"
                case "NETWORK_FAILED": message = "无法建立本机爬虫连接，请重试。"
                default: message = "内置爬虫运行时未能启动，请重试。"
                }
                throw TVError.message(message)
            }
            guard let text = object["endpoint"], let endpoint = URL(string: text), let token = object["token"] else { throw TVError.message("运行时启动响应无效。") }
            answer = .success(try CSPWorkerConnection(endpoint: endpoint, token: token))
        } catch { answer = .failure(error) }
        buffer.removeAll()
    }
    func stop() {
        lock.lock(); let shouldStop = !stopped; stopped = true; lock.unlock()
        if shouldStop { try? input.fileHandleForWriting.close() }
    }
    deinit { stop(); output.fileHandleForReading.readabilityHandler = nil }
}

private final class CSPHostOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var host: CSPHostProcess?
    func set(_ value: CSPHostProcess?) { lock.lock(); host = value; lock.unlock() }
    func stop() { lock.lock(); let value = host; lock.unlock(); value?.stop() }
}

public actor CSPBundledRuntime: CSPRuntimeProvider {
    private let assets: URL
    private let storage: URL
    private let deadline: TimeInterval
    private var host: CSPHostProcess?
    private var hash: String?
    private var active: CSPWorkerConnection?
    private var pending: (id: UUID, task: Task<CSPWorkerConnection, Error>)?
    private var diagnosticCount = 0
    private let session: URLSession
    private nonisolated let owner = CSPHostOwner()
    public nonisolated let available: Bool
    public init(assets: URL, storage: URL, startupTimeout: TimeInterval? = nil) {
        self.assets = assets; self.storage = storage
        #if arch(x86_64)
        deadline = startupTimeout ?? 900
        #else
        deadline = startupTimeout ?? 180
        #endif
        available = FileManager.default.isExecutableFile(atPath: assets.appendingPathComponent("CSPRuntimeHost").path) && FileManager.default.fileExists(atPath: assets.appendingPathComponent("manifest.json").path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 1; configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration, delegate: CSPNoRedirect(), delegateQueue: nil)
    }
    public func connection(componentHash: String) async throws -> CSPWorkerConnection {
        guard componentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw TVError.message("爬虫组件标识无效。") }
        guard available else { throw TVError.message("这个安装包没有包含爬虫运行时，请安装带 CSP 组件的完整版本。") }
        if let pending {
            do { _ = try await pending.task.value }
            catch { if self.pending?.id == pending.id { self.pending = nil }; throw error }
            if self.pending?.id == pending.id { self.pending = nil }
            try Task.checkCancellation()
            return try await connection(componentHash: componentHash)
        }
        if hash == componentHash, let active, host?.running == true {
            for _ in 0..<2 {
                if await healthy(active) { return active }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let task = Task { try await self.launch(componentHash) }
        let identifier = UUID(); pending = (identifier, task)
        do {
            let result = try await task.value
            if pending?.id == identifier { pending = nil }
            try Task.checkCancellation(); return result
        } catch { if pending?.id == identifier { pending = nil }; throw error }
    }
    private func healthy(_ connection: CSPWorkerConnection) async -> Bool {
        var request = URLRequest(url: connection.endpoint.appendingPathComponent("health"), timeoutInterval: 1)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TVBOX_CSP_TEST_ASSETS"] != nil && diagnosticCount < 4 {
                diagnosticCount += 1; let failure = error as NSError
                print("CSP test local health:", failure.domain, failure.code)
            }
            #endif
            return false
        }
        let (data, response) = result
        #if DEBUG
        if ProcessInfo.processInfo.environment["TVBOX_CSP_TEST_ASSETS"] != nil && diagnosticCount < 4 {
            diagnosticCount += 1; print("CSP test local status:", (response as? HTTPURLResponse)?.statusCode ?? -1, "bytes:", data.count)
        }
        #endif
        guard
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["protocol"] as? Int == 1 && object["runtime"] as? String == "android-art"
    }
    private func launch(_ componentHash: String) async throws -> CSPWorkerConnection {
        diagnosticCount = 0
        let old = host; active = nil; hash = nil; old?.stop()
        // The previous supervisor releases the data-disk lock after shutdown.
        let stoppedBy = Date().addingTimeInterval(14)
        while old?.running == true && Date() < stoppedBy { try await Task.sleep(nanoseconds: 100_000_000) }
        guard old?.running != true else { throw TVError.message("爬虫运行时正在结束上一次连接，请稍后重试。") }
        try Task.checkCancellation()
        let next = try CSPHostProcess(executable: assets.appendingPathComponent("CSPRuntimeHost"), assets: assets, storage: storage)
        host = next; owner.set(next)
        do {
            let timeout = Date().addingTimeInterval(deadline)
            while Date() < timeout {
                try Task.checkCancellation()
                if let result = next.result {
                    let connection = try result.get()
                    if await healthy(connection) {
                        active = connection; hash = componentHash; return connection
                    }
                }
                guard next.running else { throw TVError.message("内置爬虫运行时已退出，请重试。") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw TVError.message("内置爬虫运行时启动超时。首次启动或 Intel 机型需要更长时间，请稍后重试。")
        } catch { next.stop(); throw error }
    }
    /// Synchronous so app termination never leaves the parent pipe open.
    /// The supervisor performs bounded graceful shutdown independently.
    public nonisolated func stop() { owner.stop() }
}
