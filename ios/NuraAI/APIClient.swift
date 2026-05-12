import Foundation

final class APIClient {
    static let shared = APIClient()
    private init() {}

    func register(baseURL: String, email: String, password: String) async throws -> AuthResponse {
        try await request(baseURL: baseURL, path: "/auth/register", method: "POST", body: RegisterRequest(email: email, password: password), responseType: AuthResponse.self)
    }

    func login(baseURL: String, email: String, password: String) async throws -> AuthResponse {
        try await request(baseURL: baseURL, path: "/auth/login", method: "POST", body: LoginRequest(email: email, password: password), responseType: AuthResponse.self)
    }

    func submitOnboarding(baseURL: String, payload: OnboardingRequest) async throws -> UserProfile {
        try await request(baseURL: baseURL, path: "/user/onboarding", method: "POST", body: payload, responseType: UserProfile.self)
    }

    func getProfile(baseURL: String, userId: Int) async throws -> UserProfile {
        guard let url = URL(string: baseURL + "/user/profile/\(userId)") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    func sendMessage(baseURL: String, userId: Int, content: String) async throws -> ChatMessageResponse {
        try await request(baseURL: baseURL, path: "/chat/message", method: "POST", body: ChatMessageRequest(user_id: userId, content: content), responseType: ChatMessageResponse.self)
    }

    func fetchMeditations(baseURL: String) async throws -> [MeditationItem] {
        guard let url = URL(string: baseURL + "/content/meditations") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([MeditationItem].self, from: data)
    }

    func fetchDiscover(baseURL: String) async throws -> [DiscoverItem] {
        guard let url = URL(string: baseURL + "/content/discover") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([DiscoverItem].self, from: data)
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
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "Request failed"
            throw NSError(domain: "NuraAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: serverMessage])
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}
