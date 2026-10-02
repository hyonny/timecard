import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FreeeError.invalidResponse("HTTP 以外の応答")
        }
        return (data, http)
    }
}

struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var companyID: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case companyID = "company_id"
    }
}

public enum OAuth {
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let tokenURL = URL(string: "https://accounts.secure.freee.co.jp/public_api/token")!
    static let apiBase = "https://api.freee.co.jp/hr/api/v1"

    /// ブラウザで開く認可ページ。許可すると認可コードが画面に表示される
    public static func authorizeURL(clientID: String) -> URL {
        var components = URLComponents(string: "https://accounts.secure.freee.co.jp/public_api/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "prompt", value: "select_company"),
        ]
        return components.url!
    }

    /// 認可コードをトークンに交換し、事業所と従業員の ID を取得する
    public static func authorize(
        clientID: String,
        clientSecret: String,
        code: String,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @Sendable () -> Date = { Date() }
    ) async throws -> Credentials {
        let (data, response) = try await transport.send(tokenRequest([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("redirect_uri", redirectURI),
        ]))
        guard response.statusCode == 200 else {
            throw FreeeError.api(status: response.statusCode, message: errorMessage(data))
        }
        let token = try decode(TokenResponse.self, data)

        var meRequest = URLRequest(url: URL(string: "\(apiBase)/users/me")!)
        meRequest.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (meData, meResponse) = try await transport.send(meRequest)
        guard meResponse.statusCode == 200 else {
            throw FreeeError.api(status: meResponse.statusCode, message: errorMessage(meData))
        }
        let me = try decode(MeResponse.self, meData)
        let company = me.companies.first { $0.id == token.companyID && $0.employeeID != nil }
            ?? me.companies.first { token.companyID == nil && $0.employeeID != nil }
        guard let company, let employeeID = company.employeeID else {
            throw FreeeError.employeeNotFound
        }

        return Credentials(
            clientID: clientID,
            clientSecret: clientSecret,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn)),
            companyID: company.id,
            employeeID: employeeID
        )
    }

    static func tokenRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FreeeError.invalidResponse(String(describing: error))
        }
    }

    /// freee のエラー応答は API によって形が違うので、ありそうな項目を順に探す
    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        if let errors = object["errors"] as? [[String: Any]] {
            let messages = errors.flatMap { $0["messages"] as? [String] ?? [] }
            if !messages.isEmpty {
                return messages.joined(separator: " ")
            }
        }
        for key in ["message", "error_description", "error"] {
            if let message = object[key] as? String {
                return message
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct MeResponse: Decodable {
    struct Company: Decodable {
        var id: Int
        var employeeID: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case employeeID = "employee_id"
        }
    }

    var companies: [Company]
}
