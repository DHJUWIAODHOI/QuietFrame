import SwiftUI

struct ChangePasscodeView: View {
    private enum Step: Hashable {
        case current
        case newPasscode
        case confirmation
    }

    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current = ""
    @State private var newPasscode = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var step: Step = .current

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: QuietFrameTheme.contentSpacing) {
                        stepPicker

                        if let message {
                            AuthenticationErrorMessage(message: message)
                                .accessibilityLabel("Error: \(message)")
                                .padding(QuietFrameTheme.contentSpacing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))
                        }

                        passcodeWell(isCompactHeight: proxy.size.height < 640)

                        Text("Changing your passcode securely re-wraps the existing vault key. Media is not decrypted or rewritten.")
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
            .navigationTitle("Change passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(QuietFrameTheme.elevated, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") { changePasscode() }
                        .disabled(current.count != 6 || newPasscode.count != 6 || confirmation.count != 6 || coordinator.isWorking)
                }
            }
        }
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
    }

    private var stepPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                stepChips
            }
            VStack(alignment: .leading, spacing: 4) {
                stepChips
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepChips: some View {
        stepChip("Current", accessibilityTitle: "Current passcode", for: .current, isComplete: current.count == 6)
        stepChip("New", accessibilityTitle: "New passcode", for: .newPasscode, isComplete: newPasscode.count == 6)
        stepChip("Confirm", accessibilityTitle: "Confirm new passcode", for: .confirmation, isComplete: confirmation.count == 6)
    }

    private func stepChip(_ title: String, accessibilityTitle: String, for target: Step, isComplete: Bool) -> some View {
        let isSelected = step == target
        return Button {
            select(target)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? QuietFrameTheme.accent : QuietFrameTheme.quietInk)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(isSelected ? QuietFrameTheme.ink : QuietFrameTheme.quietInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: QuietFrameTheme.controlHeight)
            .background(isSelected ? QuietFrameTheme.background : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(isComplete ? "Entered" : "Not entered")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func passcodeWell(isCompactHeight: Bool) -> some View {
        VStack(spacing: QuietFrameTheme.contentSpacing) {
            Text(prompt)
                .font(QuietFrameTheme.sectionTitleFont)
                .foregroundStyle(QuietFrameTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            SixDigitPasscodeField(
                label: fieldLabel,
                passcode: activeBinding,
                irisSize: isCompactHeight ? 88 : 140,
                onComplete: { advance() }
            )
            .id(step)
        }
        .padding(.vertical, isCompactHeight ? QuietFrameTheme.contentSpacing : QuietFrameTheme.pagePadding)
        .padding(.horizontal, QuietFrameTheme.compactSpacing)
        .frame(maxWidth: .infinity)
        .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.cornerRadius, style: .continuous))
    }

    private var prompt: String {
        switch step {
        case .current: "Enter your current passcode"
        case .newPasscode: "Choose a new passcode"
        case .confirmation: "Confirm the new passcode"
        }
    }

    private var fieldLabel: String {
        switch step {
        case .current: "Current six-digit passcode"
        case .newPasscode: "New six-digit passcode"
        case .confirmation: "Confirm new passcode"
        }
    }

    private var activeBinding: Binding<String> {
        switch step {
        case .current: $current
        case .newPasscode: $newPasscode
        case .confirmation: $confirmation
        }
    }

    private func advance() {
        switch step {
        case .current: select(.newPasscode)
        case .newPasscode: select(.confirmation)
        case .confirmation: break
        }
    }

    private func select(_ target: Step) {
        guard step != target else { return }
        withAnimation(reduceMotion ? nil : .snappy) { step = target }
    }

    private func changePasscode() {
        Task {
            let succeeded = await coordinator.changePasscode(
                current: current,
                new: newPasscode,
                confirmation: confirmation
            )
            if succeeded {
                dismiss()
            } else {
                message = coordinator.userMessage
                current = ""
                select(.current)
            }
        }
    }
}
