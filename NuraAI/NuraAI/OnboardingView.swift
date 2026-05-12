import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    @State private var name = ""
    @State private var dateOfBirth = Date(timeIntervalSince1970: 631152000) // 1990
    @State private var occupation = ""
    @State private var hasTherapistTreatment = false

    @State private var loading = false
    @State private var errorMessage: String?

    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    var body: some View {
        ZStack {
            CalmBackground()

            VStack(alignment: .leading, spacing: 14) {
                Text("Welcome to Nura.ai")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Let’s personalize your support experience.")
                    .foregroundStyle(.white.opacity(0.9))

                Group {
                    LabeledField(title: "Name") {
                        TextField("Your name", text: $name)
                    }

                    LabeledField(title: "Date of Birth") {
                        DatePicker("", selection: $dateOfBirth, displayedComponents: .date)
                            .labelsHidden()
                    }

                    LabeledField(title: "Job Occupation") {
                        TextField("e.g. Software Engineer", text: $occupation)
                    }

                    Toggle("I currently have routine therapist treatment", isOn: $hasTherapistTreatment)
                        .tint(.cyan)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Button(loading ? "Saving..." : "Continue") {
                    Task { await submitOnboarding() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(loading)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .padding()
        }
    }

    @MainActor
    private func submitOnboarding() async {
        guard let userId = appState.userId else {
            errorMessage = "Please login first."
            return
        }

        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !occupation.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please complete all fields."
            return
        }

        loading = true
        defer { loading = false }

        let payload = OnboardingRequest(
            user_id: userId,
            name: name,
            date_of_birth: dateFormatter.string(from: dateOfBirth),
            occupation: occupation,
            has_therapist_treatment: hasTherapistTreatment
        )

        do {
            let profile = try await APIClient.shared.submitOnboarding(baseURL: appState.apiBaseURL, payload: payload)
            appState.profile = profile
            appState.onboardingCompleted = profile.onboarding_completed
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            content()
                .padding(10)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
    }
}
