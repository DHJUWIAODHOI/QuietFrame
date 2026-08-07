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
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index < passcode.count ? Color.accentColor : Color.secondary.opacity(0.12))
                            .overlay {
                                if index < passcode.count {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 9, height: 9)
                                }
                            }
                            .frame(minWidth: 32, maxWidth: 44, minHeight: 54, maxHeight: 54)
                    }
                }
                .frame(maxWidth: 312)
                .allowsHitTesting(false)
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
