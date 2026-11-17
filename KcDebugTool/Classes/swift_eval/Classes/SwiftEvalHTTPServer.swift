import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 真机调试用的极简 HTTP 入口（仅建议 DEBUG 包启用）。
///
/// 流程：start() 绑定端口并启动 accept 线程 → 每连接单请求、同步求值、写完即关。
///   GET  /                -> eval.html 调试页
///   GET  /api/eval?expr=     -> eval 结果 JSON
///   POST /api/eval           -> body 为纯表达式或 {"expr":"..."}，结果 JSON
///   GET  /api/catalog        -> 已发现类型 / 成员清单
///   GET  /api/describe?target= -> 类 / 对象的属性与方法清单（含父类、Swift + ObjC）
///   POST /api/describe       -> body 为 {"target":"..."} 或纯 target 字符串
///
/// 求值本身可能耗时（堆扫描等），服务端是单线程串行处理，页面会禁用运行按钮避免排队。
public final class SwiftEvalHTTPServer {

    /// 进程级 HTTP 服务实例；共享同一个监听 socket，重复 `start` 不会创建第二个服务。
    public static let shared = SwiftEvalHTTPServer()

    private var port: UInt16 = 16817
    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private let stateLock = NSLock()
    /// 受锁保护的运行标记；仅供本文件协调启动/停止，外部通过 `boundPort` 判断可访问状态。
    private(set) var isRunning = false

    /// 指定端口被占用时，包含原端口在内最多尝试的端口数量。
    private static let maximumPortAttempts = 32

    private enum SocketBindingResult {
        case success((fd: Int32, port: UInt16))
        case failure(Int32)
    }

    /// 限制为共享单例，避免多个服务竞争同一调试端口和全局解释器配置。
    private init() {}

    /// 当前实际监听端口；未启动为 0。传入 `start(port: 0)` 时此值是系统分配的端口。
    public private(set) var boundPort: UInt16 = 0

    /// 在后台 accept 线程开始监听。指定端口被占用时仅连续尝试后续端口；`port == 0` 交给系统分配。
    /// 每条连接只读取一个请求并同步处理，避免共享解释器状态的并发竞态，但耗时求值会阻塞后续连接。
    public func start(port: UInt16 = 16817) {
        stateLock.lock()
        if isRunning {
            let runningPort = boundPort
            stateLock.unlock()
            NSLog("SwiftEvalHTTPServer 已在端口 \(runningPort) 运行")
            return
        }
        stateLock.unlock()

        guard let binding = bindAvailablePort(startingAt: port) else {
            // 端口全部占用或不可绑定，放弃启动。
            return
        }

        stateLock.lock()
        if isRunning {
            // 竞态：启动检查后又有别处启动成功，关闭本次 fd 直接退出。
            stateLock.unlock()
            close(binding.fd)
            return
        }
        serverFD = binding.fd
        isRunning = true
        self.port = binding.port
        boundPort = binding.port
        stateLock.unlock()

        // 拉起后台 accept 线程处理连接；256KB 栈足够处理单次 HTTP 请求。
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "SwiftEvalHTTPServer"
        thread.stackSize = 256 * 1024
        acceptThread = thread
        thread.start()

        // 枚举局域网地址用于日志提示，方便从同一网段访问调试页。
        let addresses = Self.deviceLANAddresses().map { "http://\($0):\(binding.port)" }
        NSLog("SwiftEval 已启动：\(addresses.joined(separator: " 或 "))")
    }

    /// 关闭监听 socket 以唤醒 `accept` 循环，并清空运行状态；已开始处理的请求会自然执行到结束。
    public func stop() {
        stateLock.lock()
        guard isRunning, serverFD >= 0 else {
            stateLock.unlock()
            return
        }
        close(serverFD)
        serverFD = -1
        isRunning = false
        boundPort = 0
        stateLock.unlock()
        NSLog("SwiftEvalHTTPServer 已停止")
    }

    /// 只在端口占用时尝试后续端口；其余 socket/bind/listen 错误立即停止并保留真实 errno。
    private func bindAvailablePort(startingAt requestedPort: UInt16) -> (fd: Int32, port: UInt16)? {
        let attempts = requestedPort == 0 ? 1 : Self.maximumPortAttempts
        for offset in 0..<attempts {
            let candidate = requestedPort == 0
                ? UInt16(0)
                : UInt16((Int(requestedPort) - 1 + offset) % Int(UInt16.max) + 1)
            switch bindAndListen(port: candidate) {
            case .success(let binding):
                if candidate != requestedPort {
                    NSLog("SwiftEvalHTTPServer 端口 \(requestedPort) 被占用，改用端口 \(binding.port)")
                }
                return binding
            case .failure(let errorCode):
                guard errorCode == EADDRINUSE, offset + 1 < attempts else {
                    NSLog("SwiftEvalHTTPServer 绑定端口 \(candidate) 失败 errno: \(errorCode)")
                    return nil
                }
            }
        }
        return nil
    }

    /// 创建 IPv4 TCP socket、启用地址复用并完成 bind/listen；任一步失败都会关闭本次 fd 并返回原始 errno。
    private func bindAndListen(port: UInt16) -> SocketBindingResult {
        // 创建 IPv4 TCP socket；失败返回原始 errno。
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(errno) }
        // 开启地址复用，避免上一轮 TIME_WAIT 端口无法立即重用。
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 绑定到所有网卡的指定端口（大端序），监听队列长度 8。
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let errorCode = errno
            close(fd)
            return .failure(errorCode)
        }
        guard listen(fd, 8) == 0 else {
            let errorCode = errno
            close(fd)
            return .failure(errorCode)
        }
        // 端口 0 时由内核分配，读取实际绑定端口返回。
        guard let actualPort = Self.socketPort(fd: fd) else {
            let errorCode = errno
            close(fd)
            return .failure(errorCode)
        }
        return .success((fd, actualPort))
    }

    /// 通过 getsockname 读取实际绑定端口，支持内核为端口 0 自动挑选端口的场景。
    private static func socketPort(fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }

    // MARK: - 连接处理

    /// 后台串行 accept 循环。stop 关闭 serverFD 后会得到 EBADF/EINVAL 并自然退出，不需要额外条件变量。
    private func acceptLoop() {
        while true {
            // 每次循环重新读取 serverFD，stop 关闭后读到 -1 即退出。
            stateLock.lock()
            let fd = serverFD
            stateLock.unlock()
            guard fd >= 0 else { return }
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(fd, &clientAddress, &length)
            guard clientFD >= 0 else {
                // 监听 socket 被关闭，自然退出循环。
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            // 单连接单请求：处理完即关闭，保持串行语义避免解释器状态竞争。
            handle(clientFD: clientFD)
            close(clientFD)
        }
    }

    private struct Request {
        let method: String
        let target: String
        let body: String
    }

    /// 读取单个请求的头和 body，完成最小 HTTP 解析后路由；畸形或超长之外的数据直接断开以保持实现边界。
    private func handle(clientFD: Int32) {
        // 一次性读取请求（含 head + body），缓冲上限 16KB，超出部分直接断开以保持实现边界。
        var buffer = [UInt8](repeating: 0, count: 16384)
        let received = recv(clientFD, &buffer, buffer.count, 0)
        guard received > 0 else { return }
        let data = Data(buffer.prefix(Int(received)))
        guard let text = String(data: data, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n") else { return }
        // 以空行分隔 header 与 body，再取首行「方法 + 路径」作为最小 HTTP 解析。
        let head = String(text.prefix(upTo: separator.lowerBound))
        guard let requestLine = head.components(separatedBy: "\r\n").first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let request = Request(method: parts[0], target: parts[1],
                              body: String(text[separator.upperBound...]))
        // 路由到对应端点并直接写出响应。
        write(route(request), to: clientFD)
    }

    private struct Response {
        let status: String
        let contentType: String
        let body: Data
    }

    /// 将已解析请求映射到静态页、目录、求值或类型描述端点；所有 JSON 响应使用同一 UTF-8 编码策略。
    private func route(_ request: Request) -> Response {
        let components = URLComponents(string: request.target)
        let path = components?.path ?? "/"
        switch path {
        case "/", "/index.html", "/eval.html":
            // 静态调试页：优先读 bundle 资源，缺失时退到内置最简页面。
            let html = Self.loadPageHTML() ?? Data(Self.fallbackHTML.utf8)
            return Response(status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
        case "/api/catalog":
            // types（自动发现）、roots（根变量）、methods（手动注册方法）三段目录，序列化为 JSON 响应。
            let data = (try? JSONSerialization.data(withJSONObject: SwiftEval.catalog(),
                                                    options: [.prettyPrinted, .sortedKeys]))
                ?? Data("{}".utf8)
            return Response(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
        case "/api/eval":
            let evaluation = evaluationRequest(from: request, components: components)
            // 语法 / 调用错误也算一次成功的求值响应，具体状态在 JSON 的 ok 字段里
            let result = SwiftEval.evaluate(evaluation.expression, maxDepth: evaluation.maxDepth)
            return Response(status: "200 OK", contentType: "application/json; charset=utf-8",
                            body: result.jsonData())
        case "/api/describe":
            let description = descriptionRequest(from: request, components: components)
            // 按 target 与开关生成类型/对象成员清单，再序列化为 JSON 响应。
            let result = EvalTypeDescription.describe(
                target: description.target, includeSwift: description.includeSwift,
                includeSuperclasses: description.includeSuperclasses,
                includeIvars: description.includeIvars)
            let data = (try? JSONSerialization.data(withJSONObject: result.dictionary,
                                                    options: [.sortedKeys]))
                ?? Data("{\"ok\":false,\"error\":\"成员清单无法序列化\"}".utf8)
            return Response(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
        default:
            return Response(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                            body: Data("Not Found".utf8))
        }
    }

    private struct EvaluationRequest {
        let expression: String
        let maxDepth: Int?
    }

    /// 从 POST JSON/纯文本或 GET query 提取表达式和展示深度；body 形式优先于 query，便于提交长表达式。
    private func evaluationRequest(from request: Request,
                                   components: URLComponents?) -> EvaluationRequest {
        if request.method == "POST" {
            let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{"), let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["expr"] as? String {
                return EvaluationRequest(expression: text,
                                         maxDepth: (json["maxDepth"] as? NSNumber)?.intValue)
            }
            if let range = body.range(of: "expr=") {
                let raw = String(body[range.upperBound...]).split(separator: "&").first.map(String.init) ?? ""
                return EvaluationRequest(expression: raw.removingPercentEncoding ?? raw,
                                         maxDepth: nil)
            }
            return EvaluationRequest(expression: body, maxDepth: nil)
        }
        let expression = components?.queryItems?.first(where: { $0.name == "expr" })?.value ?? ""
        let depthText = components?.queryItems?.first(where: { $0.name == "maxDepth" })?.value
        let maxDepth = depthText.flatMap { Int($0) }
        return EvaluationRequest(expression: expression, maxDepth: maxDepth)
    }

    private struct DescriptionRequest {
        let target: String
        let includeSwift: Bool
        let includeSuperclasses: Bool
        let includeIvars: Bool
    }

    /// 开关默认全开；query 与 POST JSON 都可传，便于 curl 直接试。
    /// 解析 describe 的 target 与三个布尔开关；JSON body 优先，query 是无页面客户端的回退入口。
    private func descriptionRequest(from request: Request,
                                    components: URLComponents?) -> DescriptionRequest {
        func query(_ name: String) -> String? {
            components?.queryItems?.first(where: { $0.name == name })?.value
        }
        let body = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var json: [String: Any] = [:]
        if request.method == "POST", body.hasPrefix("{"),
           let data = body.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }
        let target = (json["target"] as? String) ?? query("target")
            ?? (request.method == "POST" && !body.hasPrefix("{") ? body : "")
        /// 按 JSON 布尔、NSNumber、再到 query 文本的顺序解析开关；缺省为 true 以保持 describe 默认完整。
        func enabled(_ name: String) -> Bool {
            if let value = json[name] as? Bool { return value }
            if let value = json[name] as? NSNumber { return value.boolValue }
            guard let text = query(name)?.lowercased() else { return true }
            return !["0", "false", "no", "off"].contains(text)
        }
        return DescriptionRequest(target: target, includeSwift: enabled("includeSwift"),
                                  includeSuperclasses: enabled("includeSuper"),
                                  includeIvars: enabled("includeIvars"))
    }

    /// 生成带 Content-Length 的 HTTP/1.1 响应，并循环 send 直至全部字节写完或连接出错。
    private func write(_ response: Response, to clientFD: Int32) {
        // 拼出带 Content-Length 的 HTTP/1.1 响应头（禁止缓存、允许跨域、写完即关）。
        var header = "HTTP/1.1 \(response.status)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        // 循环 send 直到全部字节写完或连接出错；send 返回负即停止。
        payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let sent = send(clientFD, base.advanced(by: offset), buffer.count - offset, 0)
                guard sent > 0 else { break }
                offset += sent
            }
        }
    }

    // MARK: - 资源与地址

    /// 依次在资源 bundle、当前 bundle 和主 bundle 查找 eval.html，兼容 CocoaPods 资源打包差异。
    private static func loadPageHTML() -> Data? {
        // CocoaPods resource_bundles 会把页面放进同名 bundle；也兼容直接拖进主 target。
        let bundle = Bundle(for: SwiftEvalHTTPServer.self)
        let resourceBundle = bundle.url(forResource: "SwiftEvalResources", withExtension: "bundle")
            .flatMap { Bundle(url: $0) }
        let candidates = [
            resourceBundle?.url(forResource: "eval", withExtension: "html"),
            bundle.url(forResource: "SwiftEvalResources.bundle/eval", withExtension: "html"),
            Bundle.main.url(forResource: "SwiftEvalResources.bundle/eval", withExtension: "html"),
            bundle.url(forResource: "eval", withExtension: "html"),
            Bundle.main.url(forResource: "eval", withExtension: "html")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    /// 枚举活动非回环 IPv4 接口，用于日志输出可从同一局域网访问的候选地址。
    /// 地址仅用于提示，不代表防火墙、VPN 或网络隔离策略一定允许连接。
    static func deviceLANAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            // 只收集 IPv4 接口。
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            // 只取以 en 开头的物理/无线接口地址（跳过回环 lo）。
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if status == 0, let ip = String(cString: host, encoding: .utf8) { result.append(ip) }
        }
        return result
    }

    /// bundle 资源缺失时的最小可用页面，保证服务永远能打开。
    private static let fallbackHTML = """
    <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>Swift Eval</title></head>
    <body><h3>Swift Eval</h3><p>eval.html 未打进 Bundle，可直接调用
    <code>/api/eval?expr=...</code>。</p>
    <form action="/api/eval" method="GET"><input name="expr" size="80" autofocus>
    <button>运行</button></form></body></html>
    """
}

extension NSObject {
    /// App 调试入口：仅 DEBUG 构建生效。以 ObjC 可见类方法暴露，方便调试菜单或 LLDB 调用。
    @objc public class func startEvalIfDebug() {
        SwiftEvalHTTPServer.shared.start(port: 16817)
    }
}
