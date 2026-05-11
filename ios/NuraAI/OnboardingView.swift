import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var loading = false
    @State private var err: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Nura.ai")
                .font(.largeTitle).bold()
            Text("你的 AI 情绪支持伙伴")
                .foregroundStyle(.secondary)

            Button(loading ? "连接中..." : "开始匿名使用") {
                Task { await login() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading)

            if let err {
                Text(err).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding()
    }

    @MainActor
    private func login() async {
        loading = true
        defer { loading = false }
        do {
            let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            let token = try await APIClient.shared.anonymousLogin(baseURL: appState.apiBaseURL, deviceId: deviceId)
            appState.userId = token.user_id
            appState.token = token.access_token
            err = nil
        } catch {
            err = "登录失败，请检查后端地址和网络。"
        }
    }
}
