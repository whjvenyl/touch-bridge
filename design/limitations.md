> **⚠️ SUPERSEDED — kept for historical context only.**
> Current limitations: [`docs/docs/architecture/limitations.mdx`](../docs/docs/architecture/limitations.mdx)

# TouchBridge Limitations

## Cannot Do

### Keychain items with `kSecAccessControlBiometryCurrentSet`
macOS Keychain items sealed with biometric ACLs require the local Secure Enclave to unwrap them. This is a hardware-level restriction — no software can bypass it. TouchBridge cannot unlock these items.

### Sandboxed App Store apps calling LAContext
Third-party apps distributed via the App Store that call `LAContext.evaluatePolicy` internally are sandboxed. TouchBridge cannot intercept these calls due to SIP and sandbox restrictions.

### Apple Pay
Apple Pay uses a dedicated Secure Element on the Mac (or Watch) and cannot be delegated.

### FileVault unlock
FileVault decryption happens before the OS boots. No user-level daemon is running at that point.

## Design Tradeoffs

### BLE range
BLE range is typically 10-30 meters. The RSSI proximity gate (default -75 dBm) limits effective range to ~5 meters. This means your iPhone must be nearby.

### Background BLE on iOS
iOS aggressively kills background BLE connections. TouchBridge uses `CBCentralManagerOptionRestoreIdentifierKey` for state restoration, but there may be delays when the app is in the background.

### Multi-device: Mac side vs phone side
The Mac daemon supports multiple paired companion devices — any paired, connected device can approve a request (first valid response wins; every connected device is notified). The iOS app, however, currently pairs with a single Mac at a time; pairing with a second Mac replaces the first. Multi-Mac support on the phone is planned.

### Other scenarios worth knowing
- **SSH sessions**: `sudo` inside an SSH session goes through the same PAM stack, so the approval prompt appears on your phone even though you're remote. If your phone isn't near the Mac (BLE range), the request times out and falls back to password.
- **iPad**: the companion app targets iPhone; iPad is untested as a companion device.
- **Locked phone**: approval requires unlocking the phone with Face ID/Touch ID — that unlock is the biometric gate. A locked, unattended phone cannot silently approve anything.

### Browser authentication (WebAuthn, passkeys, password autofill)
TouchBridge does not cover browser-level authentication surfaces. Browser extensions cannot replace the platform authenticator — they can only intercept the JavaScript API call, not the OS-level Touch ID / iCloud Keychain flow that produces the actual credential. Password autofill interception is non-functional (browsers don't let extensions block native autofill), and WebAuthn interception adds a redundant step before the native prompt rather than replacing it. Users with password managers (1Password, Bitwarden, etc.) would also experience conflicts on the same DOM hooks. Browser auth is handled natively by macOS (Touch ID, iCloud Keychain passkey approval) and by the user's password manager — TouchBridge focuses on OS-level surfaces (sudo, screensaver, system auth) where no browser or password manager can reach.
