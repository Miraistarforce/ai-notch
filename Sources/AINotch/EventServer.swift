import Foundation
import Network

/// 127.0.0.1 のみで待ち受ける極小HTTPサーバー。
/// hooksスクリプトから POST /event でJSONイベントを受け取る。
final class EventServer {
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
            if let response = self.tryHandle(buf) {
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// リクエストが完成していれば処理してレスポンスを返す。未完成なら nil。
    private func tryHandle(_ buf: Data) -> Data? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
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
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buf.subdata(in: headerEnd.upperBound..<buf.endIndex)
        if body.count < contentLength { return nil }

        switch (method, path) {
        case ("POST", "/event"):
            if let json = try? JSONSerialization.jsonObject(with: body.prefix(contentLength)) as? [String: Any] {
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
            let decision = sid.isEmpty ? "pending" : (decisionProvider?(key) ?? "pending")
            return httpResponse(200, "{\"decision\":\"\(decision)\"}")
        case ("POST", "/decision"):
            if let json = try? JSONSerialization.jsonObject(with: body.prefix(contentLength)) as? [String: Any],
               let sid = json["session_id"] as? String,
               let decision = json["decision"] as? String {
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
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        var res = Data("HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        res.append(data)
        return res
    }
}
