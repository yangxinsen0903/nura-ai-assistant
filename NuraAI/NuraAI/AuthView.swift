import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var appState: AppState

    @State private var email = ""
    @State private var password = ""
    @State private var isRegisterMode = false
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            CalmBackground()

            VStack(spacing: 20) {
                Spacer()

                Text("Nura.ai")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Your AI emotional support therapist")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    SecureField("Password", text: $password)
                        .padding()
                        .background(.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                Button(loading ? "Please wait..." : (isRegisterMode ? "Create Account" : "Log In")) {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(loading)

                Button(isRegisterMode ? "Already have an account? Log In" : "New user? Create account") {
                    isRegisterMode.toggle()
                    errorMessage = nil
                }
                .foregroundStyle(.white.opacity(0.95))
                .font(.footnote)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.bottom, 40)
        }
    }

    @MainActor
    private func submit() async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter email and password."
            return
        }

        loading = true
        defer { loading = false }

        do {
            let auth: AuthResponse
            if isRegisterMode {
                auth = try await APIClient.shared.register(baseURL: appState.apiBaseURL, email: email, password: password)
            } else {
                auth = try await APIClient.shared.login(baseURL: appState.apiBaseURL, email: email, password: password)
            }

            appState.token = auth.access_token
            appState.userId = auth.user_id
            appState.onboardingCompleted = auth.onboarding_completed
            appState.profile = try? await APIClient.shared.getProfile(baseURL: appState.apiBaseURL, userId: auth.user_id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
