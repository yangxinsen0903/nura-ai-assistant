import Foundation

struct AnonymousLoginRequest: Codable {
    let device_id: String
    let nickname: String?
}

struct TokenResponse: Codable {
    let access_token: String
    let token_type: String
    let user_id: Int
}

struct ChatMessageRequest: Codable {
    let user_id: Int
    let content: String
}

struct ChatMessageResponse: Codable {
    let reply: String
    let emotion: String
    let risk_level: String
}

struct LocalMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}
