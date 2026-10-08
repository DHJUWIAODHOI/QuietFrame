import SwiftData
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRecords: [AppSettings]

    private enum Sheet: String, Identifiable {
        case changePasscode
        case setPasscode
        case removePasscode
        case reset

        var id: String { rawValue }
    }

    @State private var activeSheet: Sheet?
    @State private var confirmsReset = false
    @State private var userMessage: String?
    @ScaledMetric(relativeTo: .title3) private var headerIrisSize: CGFloat = 18

    private var settings: AppSettings? { settingsRecords.first }

    var body: some View {
        List {
            privacyFactsSection
            securitySection
            vaultSection
            privacySection
            destructiveSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(QuietFrameTheme.sectionSpacing)
        .labelStyle(QuietSettingsLabelStyle())
        .labeledContentStyle(SettingsValueStyle())
        .quietFormStyle()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .changePasscode:
                ChangePasscodeView(coordinator: dependencies.lockCoordinator)
            case .setPasscode:
                SetPasscodeView(coordinator: dependencies.lockCoordinator)
            case .removePasscode:
                RemovePasscodeView(coordinator: dependencies.lockCoordinator)
            case .reset:
                if dependencies.lockCoordinator.authenticationMode == .passcode {
                    ResetApplicationView(coordinator: dependencies.lockCoordinator)
                        .interactiveDismissDisabled(dependencies.lockCoordinator.isWorking)
                } else {
                    RecoveryResetView(coordinator: dependencies.lockCoordinator)
                        .interactiveDismissDisabled(dependencies.lockCoordinator.isWorking)
                }
            }
        }
        .confirmationDialog(
            "Reset QuietFrame?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Continue to reset", role: .destructive) { activeSheet = .reset }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetConfirmationMessage)
        }
        .alert("QuietFrame", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { userMessage = nil }
        } message: {
            Text(userMessage ?? "The setting could not be saved.")
        }
    }

    private var privacyFactsSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: QuietFrameTheme.contentSpacing) {
                    privacyFacts
                }
                VStack(alignment: .leading, spacing: 4) {
                    privacyFacts
                }
            }
            .font(.subheadline)
            .foregroundStyle(QuietFrameTheme.quietInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    @ViewBuilder
    private var privacyFacts: some View {
        Text("Analytics and tracking: Off")
            .fixedSize(horizontal: false, vertical: true)
        Text("Cloud sync: Off")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var securitySection: some View {
        Section {
            if dependencies.lockCoordinator.authenticationMode == .passcode {
                LabeledContent {
                    Text("On")
                } label: {
                    Label("App passcode", systemImage: "lock.fill")
                }

                Toggle(isOn: biometricsBinding) {
                    Label(dependencies.lockCoordinator.biometricKind.title, systemImage: biometricSymbol)
                }
                .disabled(dependencies.lockCoordinator.biometricKind == .none)
                .accessibilityHint("Uses biometrics currently enrolled on this device")

                Button {
                    activeSheet = .changePasscode
                } label: {
                    Label("Change passcode", systemImage: "ellipsis.rectangle")
                }

                Picker(selection: autoLockBinding) {
                    ForEach(AutoLockPeriod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Label("Auto-Lock", systemImage: "lock.rotation")
                }
                .tint(QuietFrameTheme.quietInk)

                Button {
                    Task { await dependencies.lockCoordinator.lock() }
                } label: {
                    Label("Lock QuietFrame now", systemImage: "lock.fill")
                        .fontWeight(.medium)
                }
                .accessibilityIdentifier("lock-now")

                Button(role: .destructive) {
                    activeSheet = .removePasscode
                } label: {
                    SettingsDestructiveRowLabel(title: "Turn off app passcode", systemImage: "lock.open")
                }
            } else {
                LabeledContent {
                    Text("Off")
                } label: {
                    Label("App passcode", systemImage: "lock.open")
                }

                Button {
                    activeSheet = .setPasscode
                } label: {
                    Label("Set a passcode", systemImage: "lock.badge.plus")
                }

                Text("Media remains encrypted, but QuietFrame opens whenever your iPhone is unlocked.")
                    .font(.footnote)
                    .foregroundStyle(QuietFrameTheme.quietInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack(spacing: QuietFrameTheme.compactSpacing) {
                ApertureIris(closure: 1, filledBlades: 6, size: headerIrisSize, showsRing: false)
                    .accessibilityHidden(true)
                sectionHeader("Security")
            }
        } footer: {
            Text("QuietFrame is covered immediately in the app switcher. Auto-lock controls how long an unlocked session may remain during a brief background transition.")
                .foregroundStyle(QuietFrameTheme.quietInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .quietRows()
    }

    private var vaultSection: some View {
        Section {
            Picker(selection: trashRetentionBinding) {
                ForEach(TrashRetentionPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Trash retention", systemImage: "trash.circle")
            }
            .tint(QuietFrameTheme.quietInk)

            Picker(selection: thumbnailBinding) {
                ForEach(ThumbnailSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            } label: {
                Label("Thumbnail size", systemImage: "square.grid.3x3")
            }
            .tint(QuietFrameTheme.quietInk)
        } header: {
            sectionHeader("Vault")
        }
        .quietRows()
    }

    private var privacySection: some View {
        Section {
            NavigationLink {
                StorageManagementView(service: dependencies.storageAnalysisService)
            } label: {
                Label("Storage usage", systemImage: "internaldrive")
            }

            NavigationLink {
                ExportOptionsView()
            } label: {
                Label("Export behavior", systemImage: "square.and.arrow.up")
            }

            NavigationLink {
                PrivacyInformationView()
            } label: {
                Label("How QuietFrame protects you", systemImage: "hand.raised.fill")
            }
        } header: {
            sectionHeader("Privacy")
        }
        .quietRows()
    }

    private var destructiveSection: some View {
        Section {
            Button(role: .destructive) {
                confirmsReset = true
            } label: {
                SettingsDestructiveRowLabel(title: "Reset QuietFrame", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .accessibilityHint("Permanently deletes encrypted media and keys after additional confirmations")
        } header: {
            sectionHeader("Danger")
        }
        .quietRows()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(QuietFrameTheme.sectionTitleFont)
            .foregroundStyle(QuietFrameTheme.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private var biometricSymbol: String {
        dependencies.lockCoordinator.biometricKind == .touchID ? "touchid" : "faceid"
    }

    private var resetConfirmationMessage: String {
        if dependencies.lockCoordinator.authenticationMode == .passcode {
            return "Reset permanently deletes all encrypted media, albums, settings, and encryption keys. You will confirm again and enter your passcode."
        }
        return "Reset permanently deletes all encrypted media, albums, settings, and encryption keys. You will confirm again and authenticate with iOS."
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { settings?.biometricsEnabled ?? false },
            set: { enabled in
                Task {
                    let succeeded = await dependencies.lockCoordinator.setBiometricsEnabled(enabled)
                    if !succeeded {
                        userMessage = dependencies.lockCoordinator.userMessage
                    }
                }
            }
        )
    }

    private var autoLockBinding: Binding<AutoLockPeriod> {
        Binding(
            get: { settings?.autoLockPeriod ?? .immediately },
            set: { value in updateSettings { $0.autoLockPeriod = value } }
        )
    }

    private var trashRetentionBinding: Binding<TrashRetentionPeriod> {
        Binding(
            get: { settings?.trashRetentionPeriod ?? .thirtyDays },
            set: { value in updateSettings { $0.trashRetentionPeriod = value } }
        )
    }

    private var thumbnailBinding: Binding<ThumbnailSize> {
        Binding(
            get: { settings?.thumbnailSize ?? .comfortable },
            set: { value in updateSettings { $0.thumbnailSize = value } }
        )
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { userMessage != nil }, set: { if !$0 { userMessage = nil } })
    }

    private func updateSettings(_ update: (AppSettings) -> Void) {
        guard let settings else { return }
        update(settings)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            userMessage = VaultError.persistenceFailure.localizedDescription
        }
    }
}

private struct SettingsDestructiveRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: QuietFrameTheme.contentSpacing) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(QuietFrameTheme.destructive)
        .frame(maxWidth: .infinity, minHeight: QuietFrameTheme.controlHeight, alignment: .leading)
    }
}
