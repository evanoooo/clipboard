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
        self.baseURL = baseURL

        if let username, !username.isEmpty, let password {
            let credential = "\(username):\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
            self.authHeader = "Basic \(credential)"
        } else {
            self.authHeader = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
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
        // 201 Created 或 405 Method Not Allowed (目录已存在) 均为合规状态
        if (200...299).contains(http.statusCode) || http.statusCode == 405 {
            return
        }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    /// 获取远端资源的 ETag / 修改摘要 (PROPFIND Depth: 0)
    func getETag(path: String) async throws -> String? {
        var request = makeRequest(path: path, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        return http.value(forHTTPHeaderField: "ETag")
    }

    /// 上传数据 (PUT)
    func upload(data: Data, to path: String) async throws {
        var request = makeRequest(path: path, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if (200...299).contains(http.statusCode) { return }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    /// 下载数据 (GET)
    func download(from path: String) async throws -> Data {
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        if http.statusCode == 200 { return data }
        if http.statusCode == 404 { throw WebDAVError.notFound }
        if http.statusCode == 401 { throw WebDAVError.unauthorized }
        throw WebDAVError.serverError(code: http.statusCode)
    }

    /// 物理删除资源 (DELETE)
    func delete(path: String) async throws {
        let request = makeRequest(path: path, method: "DELETE")
        let (_, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.unexpectedResponse
        }
        // 200/204/404 均视为删除完成
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
        } catch let err as NSError {
            if err.domain == NSURLErrorDomain {
                throw WebDAVError.networkError(err.localizedDescription)
            }
            throw err
        }
    }
}
