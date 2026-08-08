# QuietFrame Security Notes

## Security Goal

QuietFrame protects private media against casual access, app-switcher exposure, ordinary sandbox extraction, device backup leakage, and ciphertext modification. It is local-only and has no server-side attack surface.

It does not claim protection against a compromised iOS kernel, a jailbroken device, runtime instrumentation in the app process, malicious enrolled biometrics, or a person who knows the QuietFrame passcode.

## Assets

- Original photos and videos
- Private thumbnails
- Random 256-bit vault master key
- Passcode verifier and wrapped-key envelope
- Filenames, dates, dimensions, sizes, albums, tags, and favorites
- Temporary plaintext required for Photos transfer, AVPlayer, and sharing

## Trust Boundaries

- iOS sandbox and Data Protection
- Keychain Services and LocalAuthentication
- PhotosUI scoped picker handoff
- PhotoKit add/delete transactions
- Activity extensions selected by the user

QuietFrame trusts Apple platform cryptography and does not implement AES, SHA-256, HMAC, HKDF, or random generation primitives itself. PBKDF2 orchestration is implemented with CryptoKit HMAC because Apple frameworks do not expose PBKDF2 directly.

## Key Management

- Master key: random 32 bytes from `SecRandomCopyBytes`
- Passcode KDF: PBKDF2-HMAC-SHA256, 210,000 iterations, random 16-byte salt
- Key envelope: AES-GCM with domain-separated authenticated data
- Passcode check: constant-time comparison of an HMAC verifier
- Main Keychain class: `WhenUnlockedThisDeviceOnly`, non-synchronizing
- No-passcode mode: random master key stored directly in the device-only Keychain
- Biometric Keychain class: `WhenPasscodeSetThisDeviceOnly` plus `biometryCurrentSet`
- Runtime key: actor-isolated and removed on lock
- Reset: journaled Keychain destruction before encrypted-file deletion

The six-digit passcode has limited entropy. The design relies on Keychain/sandbox protection to prevent extraction of the offline-verifiable envelope. A future high-assurance mode should require a device passcode and support an alphanumeric passphrase or a device-bound Secure Enclave secret.

No-passcode mode intentionally removes QuietFrame's app-level access gate. It does not remove media encryption, but anyone who can use the unlocked iPhone can open the vault. Users can add or remove a passcode later without rewriting media.

## File Encryption

Each file receives a random HKDF salt and nonce prefix. HKDF derives a unique AES-256-GCM content key. One MiB chunks use monotonically indexed nonces and authenticate the header plus chunk index. The decoder rejects unknown versions, invalid bounds, modified tags, truncation, and trailing bytes.

The maximum container size before the 32-bit chunk counter would repeat is far beyond practical iOS storage. The implementation rejects counter overflow.

## Data Protection and Backup

- Target default Data Protection is `NSFileProtectionComplete`.
- Encrypted media, thumbnails, Trash, staging, incoming files, exports, metadata store, and known SQLite sidecars receive complete protection.
- Sensitive directories and files are excluded from backup.
- Keychain items are device-only and do not synchronize.

SwiftData metadata is not encrypted with the QuietFrame passcode. While the device is unlocked, code executing with the app's sandbox privileges can read it. This is a known v1 boundary.

## Lock Boundary

The root removes all vault navigation before cleanup. Lock increments a session generation, and crypto validates that generation before every chunk and before completion. Import operations have their own generation and are cancelled on lock. Protected incoming, staging, export, and video files are then deleted; thumbnail memory is purged.

UI tasks outside import are not managed by a single global operation registry. Crypto work is revoked, but a future revision should serialize all metadata mutations, PhotoKit transactions, reconciliation, reset, and exports under one vault-operation coordinator.

## Reset and Recovery

Normal reset requires the QuietFrame passcode, an initial destructive confirmation, a typed `RESET`, and final confirmation. Forgotten/missing-key reset requires typed `ERASE`, explicit loss acknowledgement, and iOS device-owner authentication.

The reset journal makes interruption recoverable. Bootstrap completes pending credential, database, encrypted-root, and temporary-root deletion before opening SwiftData.

On flash storage, unlinking files does not guarantee physical overwrite. Destroying every Keychain path to the random master key provides cryptographic erasure for remaining ciphertext. Plaintext metadata remnants in SQLite free pages are protected by iOS Data Protection but are not cryptographically erased by the QuietFrame master key.

## Import and Export

- Read/write Photos access is requested only after the user starts an import so QuietFrame can inspect and revalidate exact assets before deletion. Picker import remains available without that access, but original deletion does not.
- Incoming picker files are plaintext but random-named, complete-protected, backup-excluded, cancellation-tracked, and removed after import or lock.
- Originals are never deleted automatically.
- Export asks for Photos authorization before decryption.
- Share and playback use random protected leases with completion and deinit cleanup.
- Reconciliation deletes encrypted files not referenced by metadata and repairs interrupted media/Trash moves.

Once data is transferred to another app or Photos, destination behavior is outside QuietFrame's security boundary.

## Privacy UI

- Inactive/background UI is replaced by an opaque privacy shield.
- Underlying content disables hit testing and is hidden from accessibility while shielded.
- Active screen capture causes a lock and pauses playback by removing the viewer hierarchy.
- iOS screenshots cannot be completely blocked with public API.

## Security Review Checklist

- [x] No hardcoded production key, passcode, or secret
- [x] No passcode stored in plaintext
- [x] No key stored in UserDefaults or SwiftData
- [x] No explicit sensitive logging
- [x] Authenticated encryption for all media and thumbnails
- [x] Per-file key derivation and per-chunk nonce uniqueness
- [x] Ciphertext integrity and format bounds checked
- [x] Device-only Keychain items
- [x] Biometric item invalidated by enrollment changes
- [x] Protected and backup-excluded media/temp roots
- [x] Metadata store and sidecars protected and backup-excluded
- [x] Temporary files cleaned after completion, cancellation, lock, and launch
- [x] Root navigation unavailable while locked
- [x] Crypto operations revoked after session lock
- [x] App-switcher and capture shield
- [x] Journaled, authenticated reset with key deletion
- [x] No network, analytics, ads, or third-party SDK
- [ ] Native Xcode build and test run
- [ ] Physical-device file-attribute verification
- [ ] Physical-device biometric enrollment-change test
- [ ] Fault injection at every reset and cleanup stage
- [ ] Instruments testing for very large libraries and media
- [ ] Independent pre-release security assessment

## Reporting

No public vulnerability-reporting channel is configured. Before public release, add a monitored security contact and response policy without including user media or secrets in reports.
