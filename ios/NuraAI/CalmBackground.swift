import SwiftUI

struct CalmBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.15, blue: 0.32),
                Color(red: 0.07, green: 0.25, blue: 0.44),
                Color(red: 0.11, green: 0.39, blue: 0.50)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(
            Circle()
                .fill(.white.opacity(0.08))
                .blur(radius: 60)
                .frame(width: 220, height: 220)
                .offset(x: 120, y: -240)
        )
    }
}
