//
//  WebDAVClient.swift
//  Clipboard
//
//  轻量 WebDAV HTTP/1.1 通信客户端（基于原生 URLSession，支持 RFC 4918 扩展方法）
//

import Foundation

enum WebDAVError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case serverError(code: Int)
    case networkError(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "WebDAV 服务器地址无效"
        case .unauthorized:
            return "WebDAV 认证失败：用户名或密码错误"
        case .forbidden:
            return "WebDAV 访问被拒绝：权限不足"
        case .notFound:
            return "WebDAV 目标资源未找到"
        case let .serverError(code):
            return "WebDAV 服务器异常（HTTP \(code)）"
        case let .networkError(msg):
            return "网络连接失败：\(msg)"
        case .unexpectedResponse:
            return "服务器响应异常"
        }
    }
}

actor WebDAVClient {
    private let baseURL: URL
    private let authHeader: String?
    private let session: URLSession

    init(baseURL: URL, username: String? = nil, password: String? = nil) {
        var normalizedString = baseURL.absoluteString
        if !normalizedString.hasSuffix("/") {
            normalizedString += "/"
        }
        self.baseURL = URL(string: normalizedString) ?? baseURL

        if let username, !username.isEmpty, let password {
            let credential = "\(username):\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
            self.authHeader = "Basic \(credential)"
        } else {
            self.authHeader = nil
        }

        let config = URLSessionConfiguration.ephemeral
        // 针对海外/代理或高延迟网络（往返延迟数秒级别），放宽超时限制保障大文件/索引完整传输；
        // 离线时不长时间阻塞等待连接，快速感知网络状态
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// 探测服务器连通性并测量往返延迟（PROPFIND Depth: 0）
    func testConnection() async throws -> (reachable: Bool, latencyMs: Double) {
        let start = ContinuousClock.now
        var request = makeRequest(path: "", method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }

        if http.statusCode == 401 {
            throw WebDAVError.unauthorized
        }
        if (200...299).contains(http.statusCode) || http.statusCode == 207 {
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            return (true, ms)
        }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    /// 创建目录（MKCOL）
    func makeDirectory(path: String) async throws {
        let request = makeRequest(path: path, method: "MKCOL")
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if (200...299).contains(http.statusCode) || http.statusCode == 405 {
            return
        }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    /// 获取远端资源的 ETag / 修改指纹 (优先采用 HEAD 请求以获得通用 WebDAV 服务器响应头)
    func getETag(path: String) async throws -> String? {
        let request = makeRequest(path: path, method: "HEAD")

        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }

        if let etag = http.value(forHTTPHeaderField: "ETag") {
            return etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let lastMod = http.value(forHTTPHeaderField: "Last-Modified") {
            return lastMod
        }
        return nil
    }

    /// 上传数据 (PUT)
    func upload(data: Data, to path: String) async throws {
        var request = makeRequest(path: path, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        var attempts = 0
        while true {
            try Task.checkCancellation()
            attempts += 1
            do {
                let (_, response) = try await session.upload(for: request, from: data)
                guard let http = response as? HTTPURLResponse else {
                    throw WebDAVError.unexpectedResponse
                }
                if (200...299).contains(http.statusCode) { return }
                // 遇到 409 Conflict 或 404 Not Found 时，自愈创建父级分片目录并重试
                if (http.statusCode == 409 || http.statusCode == 404) && attempts < 3 {
                    let parent = (path as NSString).deletingLastPathComponent
                    if !parent.isEmpty && parent != "/" && parent != "." {
                        try? await makeDirectory(path: parent)
                        continue
                    }
                }
                if http.statusCode == 401 { throw WebDAVError.unauthorized }
                if http.statusCode == 403 { throw WebDAVError.forbidden }
                throw WebDAVError.serverError(code: http.statusCode)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as URLError where err.code == .cancelled {
                throw CancellationError()
            } catch let err as WebDAVError {
                if case .unauthorized = err { throw err }
                if case .forbidden = err { throw err }
                if attempts < 3 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw err
            } catch {
                if attempts < 3 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw error
            }
        }
    }

    /// 下载数据 (GET)
    func download(from path: String) async throws -> Data {
        let request = makeRequest(path: path, method: "GET")

        var attempts = 0
        while true {
            try Task.checkCancellation()
            attempts += 1
            do {
                let (data, response) = try await perform(request)
                guard let http = response as? HTTPURLResponse else {
                    throw WebDAVError.unexpectedResponse
                }
                if http.statusCode == 200 { return data }
                if http.statusCode == 404 { throw WebDAVError.notFound }
                if http.statusCode == 401 { throw WebDAVError.unauthorized }
                if http.statusCode == 403 { throw WebDAVError.forbidden }
                throw WebDAVError.serverError(code: http.statusCode)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as URLError where err.code == .cancelled {
                throw CancellationError()
            } catch let err as WebDAVError {
                switch err {
                case .notFound, .unauthorized, .forbidden, .invalidURL:
                    // 确定性错误立即抛出，避免多余重试
                    throw err
                default:
                    if attempts < 3 {
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    }
                    throw err
                }
            } catch {
                if attempts < 3 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw error
            }
        }
    }

    /// 物理删除资源 (DELETE)
    func delete(path: String) async throws {
        let request = makeRequest(path: path, method: "DELETE")
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if (200...299).contains(http.statusCode) || http.statusCode == 404 {
            return
        }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    // MARK: - 请求辅助

    private func makeRequest(path: String, method: String) -> URLRequest {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullURL = cleanPath.isEmpty ? baseURL : baseURL.appending(path: cleanPath)
        var req = URLRequest(url: fullURL)
        req.httpMethod = method
        if let authHeader {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        req.setValue("Clipboard-Sync/1.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as NSError {
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            if err.domain == NSURLErrorDomain {
                throw WebDAVError.networkError(err.localizedDescription)
            }
            throw err
        }
    }
}
