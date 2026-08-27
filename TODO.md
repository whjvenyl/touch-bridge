# TouchBridge — Task List

## Cleanup

All cleanup items completed.

## Features

All features completed.

## Deferred

- [ ] Multi-Mac support on phone side (iOS pairs with one Mac at a time)
- [ ] Developer ID signing + notarization for distribution
- [ ] iOS companion test coverage (Android has 7 golden vector tests, iOS has 0)
- [ ] Android CI (no build or test in CI for Android/Wear OS)
- [x] PAM JSON injection hardening (escape username/service in snprintf)
- [x] Authenticate identify message with device key signature (ECDSA P-256 of deviceID + ephemeralPubKey, daemon verifies, both iOS + Android)
- [x] Fix threading issues (BLEServer connectedCentrals, AuthNotifier, ProximityMonitor, DaemonCoordinator lock)
