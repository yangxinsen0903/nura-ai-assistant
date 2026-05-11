import Foundation

final class APIClient {
    static let shared = APIClient()
    private init() {}

    func anonymousLogin(baseURL: String, deviceId: String) async throws -> TokenResponse {
        let reqBody = AnonymousLoginRequest(device_id: deviceId, nickname: nil)
        return try await request(
            baseURL: baseURL,
            path: "/auth/anonymous",
            method: "POST",
            body: reqBody,
            responseType: TokenResponse.self
        )
    }

    func sendMessage(baseURL: String, userId: Int, content: String) async throws -> ChatMessageResponse {
        let reqBody = ChatMessageRequest(user_id: userId, content: content)
        return try await request(
            baseURL: baseURL,
            path: "/chat/message",
            method: "POST",
            body: reqBody,
            responseType: ChatMessageResponse.self
        )
    }

    private func request<T: Codable, R: Codable>(
        baseURL: String,
        path: String,
        method: String,
        body: T,
        responseType: R.Type
    ) async throws -> R {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}
