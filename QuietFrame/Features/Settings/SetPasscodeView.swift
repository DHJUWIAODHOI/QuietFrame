import SwiftUI

struct SetPasscodeView: View {
    private enum Step: Hashable {
        case passcode
        case confirmation
    }

    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var step: Step = .passcode

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: QuietFrameTheme.contentSpacing) {
                        stepPicker

                        if let message {
                            AuthenticationErrorMessage(message: message)
                                .padding(QuietFrameTheme.contentSpacing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(QuietFrameTheme.background, in: RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous))
                        }

                        passcodeWell(isCompactHeight: proxy.size.height < 640)

                        Text("The existing vault key will be wrapped by this passcode. Media files do not need to be re-encrypted.")
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
            .navigationTitle("Set passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(QuietFrameTheme.elevated, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { setPasscode() }
                        .disabled(passcode.count != 6 || confirmation.count != 6)
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
        stepChip("New", accessibilityTitle: "New passcode", for: .passcode, isComplete: passcode.count == 6)
        stepChip("Confirm", accessibilityTitle: "Confirm passcode", for: .confirmation, isComplete: confirmation.count == 6)
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
            Text(step == .passcode ? "Choose a passcode" : "Confirm the passcode")
                .font(QuietFrameTheme.sectionTitleFont)
                .foregroundStyle(QuietFrameTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            SixDigitPasscodeField(
                label: step == .passcode ? "New six-digit passcode" : "Confirm passcode",
                passcode: step == .passcode ? $passcode : $confirmation,
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

    private func advance() {
        if step == .passcode {
            select(.confirmation)
        }
    }

    private func select(_ target: Step) {
        guard step != target else { return }
        withAnimation(reduceMotion ? nil : .snappy) { step = target }
    }

    private func setPasscode() {
        Task {
            if await coordinator.addPasscode(passcode, confirmation: confirmation) {
                dismiss()
            } else {
                message = coordinator.userMessage
            }
        }
    }
}
