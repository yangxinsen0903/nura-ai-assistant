import Foundation

final class AppState: ObservableObject {
    @Published var apiBaseURL: String = "http://100.99.145.120:8010/api/v1"
    @Published var userId: Int?
    @Published var token: String?

    var isLoggedIn: Bool { userId != nil && token != nil }
}
