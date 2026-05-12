import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var apiBaseURL: String = "http://100.99.145.120:8010/api/v1"

    @Published var token: String?
    @Published var userId: Int?
    @Published var onboardingCompleted: Bool = false

    @Published var profile: UserProfile?

    var isLoggedIn: Bool { token != nil && userId != nil }

    func logout() {
        token = nil
        userId = nil
        onboardingCompleted = false
        profile = nil
    }
}
