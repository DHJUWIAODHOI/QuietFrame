import SwiftUI

struct ResetApplicationView: View {
    let coordinator: VaultLockCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var understandsDeletion = false
    @State private var confirmationText = ""
    @State private var passcode = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("All encrypted photos and videos", systemImage: "photo.stack")
                    Label("Albums, favorites, tags, and Trash", systemImage: "rectangle.stack")
                    Label("Passcode data and encryption keys", systemImage: "key")
                } header: {
                    sectionHeader("This permanently removes")
                }
                .quietRows()

                Section {
                    Toggle(isOn: $understandsDeletion) {
                        Text("I understand this cannot be undone")
                            .foregroundStyle(QuietFrameTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Type RESET", text: $confirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(QuietFrameTheme.ink)
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                    SecureField("Current six-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { _, value in
                            passcode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                        .foregroundStyle(QuietFrameTheme.ink)
                        .frame(minHeight: QuietFrameTheme.controlHeight)
                } footer: {
                    Text("QuietFrame authenticates first, deletes the Keychain master-key envelope, then removes encrypted files.")
                        .foregroundStyle(QuietFrameTheme.quietInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .quietRows()

                if let message {
                    Section { AuthenticationErrorMessage(message: message) }
                        .quietRows()
                }

                Section {
                    Button(role: .destructive) { reset() } label: {
                        ResetConfirmButtonLabel(title: "Permanently reset QuietFrame")
                    }
                    .disabled(!canReset || coordinator.isWorking)
                    .accessibilityIdentifier("confirm-reset")
                }
                .quietRows()
            }
            .labelStyle(QuietSettingsLabelStyle())
            .listSectionSpacing(QuietFrameTheme.sectionSpacing)
            .quietFormStyle()
            .navigationTitle("Final reset confirmation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(QuietFrameTheme.elevated)
        .presentationCornerRadius(QuietFrameTheme.sheetCornerRadius)
    }

    private var canReset: Bool {
        understandsDeletion && confirmationText == "RESET" && passcode.count == 6
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.sectionTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private func reset() {
        Task {
            let succeeded = await coordinator.resetApplication(passcode: passcode)
            if succeeded {
                dismiss()
            } else {
                message = coordinator.userMessage
                passcode = ""
            }
        }
    }
}

private struct ResetConfirmButtonLabel: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(isEnabled ? QuietFrameTheme.destructive : QuietFrameTheme.quietInk)
            .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
