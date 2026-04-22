import SwiftUI

struct OnboardingStepContainer<Content: View>: View {
    let stepIndex: Int
    let totalSteps: Int
    let canContinue: Bool
    let continueLabel: String
    let showSkip: Bool
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= stepIndex ? AppTheme.Colors.brandPrimary : AppTheme.Colors.border)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Content
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack {
                if stepIndex > 0 {
                    Button("Back") { onBack() }
                        .font(AppTheme.Fonts.body)
                        .buttonStyle(.bordered)
                }

                Spacer()

                if showSkip, let skip = onSkip {
                    Button("Skip") { skip() }
                        .font(AppTheme.Fonts.body)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .buttonStyle(.plain)
                }

                if stepIndex < totalSteps - 1 {
                    Button {
                        onContinue()
                    } label: {
                        HStack(spacing: 6) {
                            Text(continueLabel)
                                .font(AppTheme.Fonts.body)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(canContinue
                            ? AppTheme.Colors.brandPrimary
                            : AppTheme.Colors.brandPrimary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: 560)
        .frame(maxHeight: .infinity)
        .background(AppTheme.Colors.background)
    }
}