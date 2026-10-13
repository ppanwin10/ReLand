import SwiftUI

struct OnboardingView: View {
    @Bindable var model: ClientAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero

                    Text("Before you pair")
                        .font(.title2.bold())

                    prerequisite(
                        number: 1,
                        title: "Install ReLand Host",
                        detail:
                            "Run ReLand Host on the Mac or Windows PC you own and want to control.",
                        systemImage: "macbook"
                    )
                    prerequisite(
                        number: 2,
                        title: "Prepare your computer",
                        detail:
                            "On Mac, allow Screen Recording and Accessibility. On Windows, keep the PC unlocked and ReLand Host running.",
                        systemImage: "lock.shield"
                    )
                    prerequisite(
                        number: 3,
                        title: "Use a private network",
                        detail:
                            "Keep both devices on the same trusted LAN or private Tailscale network.",
                        systemImage: "network"
                    )
                    prerequisite(
                        number: 4,
                        title: "Scan the one-time QR",
                        detail:
                            "Initial pairing requires physical access to your computer. Confirm its name and private address.",
                        systemImage: "qrcode.viewfinder"
                    )

                    privacyCard

                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(ReLandTheme.canvas)
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.completeOnboarding()
            } label: {
                Text("Continue to ReLand")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .accessibilityIdentifier(
                "completeOnboardingButton"
            )
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(ReLandTheme.accent)
                .accessibilityHidden(true)

            Text("Your computer, back in reach")
                .font(.largeTitle.bold())
                .foregroundStyle(ReLandTheme.strongText)

            Text(
                "Control your Mac or Windows PC from iPhone or iPad. "
                    + "Mac hosts also support terminal and AI CLI sessions and files."
            )
            .font(.title3)
            .foregroundStyle(ReLandTheme.mutedText)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "No ReLand cloud relay",
                systemImage: "checkmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(ReLandTheme.strongText)

            Text(
                "ReLand does not operate an account or relay service. "
                    + "Your screen, terminal, prompts, and files travel "
                    + "directly over your LAN or Tailscale network."
            )
            .foregroundStyle(ReLandTheme.mutedText)
        }
        .padding(18)
        .background(
            ReLandTheme.surface,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(ReLandTheme.accent.opacity(0.3))
        }
    }

    private func prerequisite(
        number: Int,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(ReLandTheme.accent, in: Circle())
                .accessibilityHidden(true)

            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(ReLandTheme.accent)
                .frame(width: 30, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ReLandTheme.strongText)
                Text(detail)
                    .foregroundStyle(ReLandTheme.mutedText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
