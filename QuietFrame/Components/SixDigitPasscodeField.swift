import SwiftUI

/// Six-digit passcode entry: the aperture iris closes one blade per digit above an on-screen keypad.
/// Hardware keyboards can type digits and delete as well.
struct SixDigitPasscodeField: View {
    let label: String
    @Binding var passcode: String
    var isDisabled = false
    var irisSize: CGFloat = 176
    var onComplete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var scaledKeySize: CGFloat = 68
    @FocusState private var isFocused: Bool

    private static let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: QuietFrameTheme.sectionSpacing) {
            ApertureIris(
                closure: CGFloat(passcode.count) / 6,
                filledBlades: passcode.count,
                size: irisSize
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: passcode.count)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(passcode.count) of 6 digits entered")

            keypad
                .opacity(isDisabled ? 0.45 : 1)
                .disabled(isDisabled)
        }
        .focusable(!isDisabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits) { press in
            press.characters.forEach { append(String($0)) }
            return .handled
        }
        .onKeyPress(.delete) {
            deleteLastDigit()
            return .handled
        }
        .sensoryFeedback(.impact(weight: .light), trigger: passcode.count)
        .onChange(of: passcode) { oldValue, newValue in
            let filtered = newValue.filter { character in
                character >= "0" && character <= "9"
            }
            let limited = String(filtered.prefix(6))
            if limited != newValue { passcode = limited }
            if oldValue.count < 6, limited.count == 6 { onComplete?() }
        }
        .onAppear { isFocused = true }
    }

    private var keySize: CGFloat {
        min(scaledKeySize, 84)
    }

    private var keypad: some View {
        Grid(horizontalSpacing: 28, verticalSpacing: 12) {
            ForEach(Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digit in
                        digitKey(digit)
                    }
                }
            }
            GridRow {
                Color.clear
                    .frame(width: keySize, height: keySize)
                    .accessibilityHidden(true)
                digitKey("0")
                Button(action: deleteLastDigit) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(QuietFrameTheme.ink)
                        .frame(width: keySize, height: keySize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(passcode.isEmpty)
                .accessibilityLabel("Delete last digit")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Passcode keypad")
    }

    private func digitKey(_ digit: String) -> some View {
        Button {
            append(digit)
        } label: {
            Text(digit)
                .font(.system(size: 28, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(QuietFrameTheme.ink)
                .frame(width: keySize, height: keySize)
                .background(QuietFrameTheme.elevated, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(digit)
    }

    private func append(_ digit: String) {
        guard !isDisabled, passcode.count < 6 else { return }
        passcode.append(digit)
    }

    private func deleteLastDigit() {
        guard !isDisabled, !passcode.isEmpty else { return }
        passcode.removeLast()
    }
}
