import SwiftUI

struct SixDigitPasscodeField: View {
    let label: String
    @Binding var passcode: String
    var isDisabled = false
    var onComplete: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField(label, text: $passcode)
            .keyboardType(.numberPad)
            .textContentType(.password)
            .focused($isFocused)
            .disabled(isDisabled)
            .foregroundStyle(.clear)
            .tint(.clear)
            .frame(height: 64)
            .overlay {
                HStack(spacing: QuietFrameTheme.compactSpacing) {
                    ForEach(0..<6, id: \.self) { index in
                        let isCurrentDigit = isFocused && !isDisabled && index == passcode.count
                        RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous)
                            .fill(index < passcode.count ? QuietFrameTheme.accent.opacity(0.14) : QuietFrameTheme.inset)
                            .overlay {
                                RoundedRectangle(cornerRadius: QuietFrameTheme.compactCornerRadius, style: .continuous)
                                    .strokeBorder(
                                        isCurrentDigit || index < passcode.count ? QuietFrameTheme.accent : Color.secondary,
                                        lineWidth: isCurrentDigit ? 2 : 1
                                    )
                            }
                            .overlay {
                                if index < passcode.count {
                                    Circle()
                                        .fill(.primary)
                                        .frame(width: 9, height: 9)
                                }
                            }
                            .frame(minWidth: 32, maxWidth: 44, minHeight: 54, maxHeight: 54)
                    }
                }
                .frame(maxWidth: 312)
                .opacity(isDisabled ? 0.5 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: passcode) { oldValue, newValue in
                let filtered = newValue.filter { character in
                    character >= "0" && character <= "9"
                }
                let limited = String(filtered.prefix(6))
                if limited != newValue { passcode = limited }
                if oldValue.count < 6, limited.count == 6 { onComplete?() }
            }
            .onAppear { isFocused = true }
            .accessibilityLabel(label)
            .accessibilityValue("\(passcode.count) of 6 digits entered")
            .accessibilityHint("Double tap to enter a numeric passcode")
    }
}
