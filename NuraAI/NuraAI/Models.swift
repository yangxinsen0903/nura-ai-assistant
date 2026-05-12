import Foundation

struct RegisterRequest: Codable {
    let email: String
    let password: String
}

struct LoginRequest: Codable {
    let email: String
    let password: String
}

struct AuthResponse: Codable {
    let access_token: String
    let token_type: String
    let user_id: Int
    let onboarding_completed: Bool
}

struct OnboardingRequest: Codable {
    let user_id: Int
    let name: String
    let date_of_birth: String
    let occupation: String
    let has_therapist_treatment: Bool
}

struct UserProfile: Codable {
    let user_id: Int
    let email: String
    let name: String?
    let date_of_birth: String?
    let occupation: String?
    let has_therapist_treatment: Bool?
    let onboarding_completed: Bool
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

struct MeditationItem: Codable, Identifiable {
    let id: String
    let title: String
    let duration_min: Int
    let category: String
}

struct DiscoverItem: Codable, Identifiable {
    let id: String
    let title: String
    let type: String
}
