import Foundation
import Network

/// 127.0.0.1 のみで待ち受ける極小HTTPサーバー。
/// hooksスクリプトから POST /event でJSONイベントを受け取る。
final class EventServer {
    private static let headerSeparator = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 8 * 1024 * 1024
    private static let maxRequestBytes = maxHeaderBytes + maxBodyBytes
    private static let allowedDecisions: Set<String> = ["allow", "allow_always", "deny", "defer"]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ainotch.server")
    var onEvent: (([String: Any]) -> Void)?
    var sessionsProvider: (() -> Data)?
    var debugProvider: (() -> Data)?
    var eventsProvider: (() -> Data)?
    /// PermissionRequest hookがポーリングする決定の取得（"pending"/"allow"/"allow_always"/"deny"/"defer"）
    var decisionProvider: ((String) -> String)?
    /// 外部からの決定の書き込み（テスト・自動化用）
    var decisionSetter: ((String, String) -> Void)?
    /// listenerの状態変化。NWListener.start は失敗しても例外を投げず、
    /// ポートが塞がっている等の失敗はすべてここに来る。見ていないと
    /// 「アプリは生きているのにイベントを受け取れない」状態に黙って入る。
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil {
                conn.cancel()
                return
            }
            if buf.count > Self.maxRequestBytes {
                self.send(self.httpResponse(413, "{\"ok\":false,\"error\":\"request too large\"}"), to: conn)
                return
            }
            if let response = self.tryHandle(buf) {
                self.send(response, to: conn)
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// リクエストが完成していれば処理してレスポンスを返す。未完成なら nil。
    private func tryHandle(_ buf: Data) -> Data? {
        guard let headerEnd = buf.range(of: Self.headerSeparator) else {
            return buf.count > Self.maxHeaderBytes
                ? httpResponse(413, "{\"ok\":false,\"error\":\"headers too large\"}")
                : nil
        }
        guard headerEnd.lowerBound <= Self.maxHeaderBytes else {
            return httpResponse(413, "{\"ok\":false,\"error\":\"headers too large\"}")
        }
        let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            return httpResponse(400, "bad request")
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return httpResponse(400, "bad request") }
        let method = requestLine[0]
        let fullPath = requestLine[1]
        let pathParts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts.first ?? "")
        var query: [String: String] = [:]
        if pathParts.count == 2 {
            for pair in pathParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                guard let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      parsed >= 0 else {
                    return httpResponse(400, "{\"ok\":false,\"error\":\"invalid content length\"}")
                }
                guard parsed <= Self.maxBodyBytes else {
                    return httpResponse(413, "{\"ok\":false,\"error\":\"body too large\"}")
                }
                contentLength = parsed
            }
        }
        let availableBodyBytes = buf.distance(from: headerEnd.upperBound, to: buf.endIndex)
        if availableBodyBytes < contentLength { return nil }

        // 完成前の本文を毎回コピーすると大きいWriteイベントで二乗コストになるため、完成後に一度だけ切り出す。
        let bodyEnd = buf.index(headerEnd.upperBound, offsetBy: contentLength)
        let body = buf.subdata(in: headerEnd.upperBound..<bodyEnd)

        switch (method, path) {
        case ("POST", "/event"):
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                onEvent?(json)
                return httpResponse(200, "{\"ok\":true}")
            }
            return httpResponse(400, "{\"ok\":false,\"error\":\"invalid json\"}")
        case ("GET", "/sessions"):
            let data = sessionsProvider?() ?? Data("[]".utf8)
            return httpResponse(200, data: data)
        case ("GET", "/health"):
            return httpResponse(200, "{\"ok\":true}")
        case ("GET", "/debug"):
            let data = debugProvider?() ?? Data("{}".utf8)
            return httpResponse(200, data: data)
        case ("GET", "/events"):
            let data = eventsProvider?() ?? Data("[]".utf8)
            return httpResponse(200, data: data)
        case ("GET", "/decision"):
            let sid = query["session"] ?? ""
            let prompt = query["prompt"] ?? ""
            let key = prompt.isEmpty ? sid : "\(sid):\(prompt)"
            let providedDecision = sid.isEmpty ? "pending" : (decisionProvider?(key) ?? "pending")
            let decision = Self.allowedDecisions.contains(providedDecision) ? providedDecision : "pending"
            return httpResponse(200, "{\"decision\":\"\(decision)\"}")
        case ("POST", "/decision"):
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let sid = json["session_id"] as? String,
               let decision = json["decision"] as? String,
               Self.allowedDecisions.contains(decision) {
                decisionSetter?(sid, decision)
                return httpResponse(200, "{\"ok\":true}")
            }
            return httpResponse(400, "{\"ok\":false}")
        default:
            return httpResponse(404, "not found")
        }
    }

    private func httpResponse(_ status: Int, _ body: String) -> Data {
        httpResponse(status, data: Data(body.utf8))
    }

    private func httpResponse(_ status: Int, data: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 413: statusText = "Content Too Large"
        default: statusText = "Bad Request"
        }
        var res = Data("HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        res.append(data)
        return res
    }

    private func send(_ response: Data, to conn: NWConnection) {
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
