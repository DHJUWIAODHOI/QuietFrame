import SwiftUI

struct RemovePasscodeView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var currentPasscode = ""
    @State private var understandsRisk = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: QuietFrameTheme.contentSpacing) {
                        Toggle(isOn: $understandsRisk) {
                            Text("I understand anyone using my unlocked iPhone can open the vault")
                                .foregroundStyle(QuietFrameTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, QuietFrameTheme.contentSpacing)
                        .padding(.vertical, 12)
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                        .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))

                        if let message {
                            AuthenticationErrorMessage(message: message)
                                .padding(QuietFrameTheme.contentSpacing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))
                        }

                        passcodePanel(isCompactHeight: proxy.size.height < 740)

                        Text("QuietFrame will open without asking for a passcode whenever this iPhone is unlocked. Media remains encrypted with a random key in the iOS Keychain.")
                            .font(.subheadline)
                            .foregroundStyle(QuietFrameTheme.quietInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: QuietFrameTheme.readableWidth)
                    .padding(.horizontal, QuietFrameTheme.pagePadding)
                    .padding(.vertical, QuietFrameTheme.contentSpacing)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(QuietFrameTheme.elevated)
            .navigationTitle("Turn off passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(QuietFrameTheme.elevated, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
    }

    private func passcodePanel(isCompactHeight: Bool) -> some View {
        VStack(spacing: QuietFrameTheme.contentSpacing) {
            Text("Enter your current passcode")
                .font(QuietFrameTheme.sectionTitleFont)
                .foregroundStyle(QuietFrameTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            SixDigitPasscodeField(
                label: "Current six-digit passcode",
                passcode: $currentPasscode,
                irisSize: isCompactHeight ? 88 : 140
            )

            Button(role: .destructive) { removePasscode() } label: {
                Text("Turn off app passcode")
            }
            .buttonStyle(.apertureDestructive)
            .disabled(!understandsRisk || currentPasscode.count != 6)
            .padding(.horizontal, QuietFrameTheme.compactSpacing)
        }
        .padding(.vertical, isCompactHeight ? QuietFrameTheme.contentSpacing : QuietFrameTheme.pagePadding)
        .padding(.horizontal, QuietFrameTheme.compactSpacing)
        .frame(maxWidth: .infinity)
        .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
    }

    private func removePasscode() {
        Task {
            if await coordinator.removePasscode(current: currentPasscode) {
                dismiss()
            } else {
                message = coordinator.userMessage
                currentPasscode = ""
            }
        }
    }
}
