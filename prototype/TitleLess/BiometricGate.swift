import LocalAuthentication

/// Face ID, Touch ID, or the device passcode, in front of one thing: entering
/// private browsing.
///
/// `.deviceOwnerAuthentication` rather than `...WithBiometrics`, and the
/// difference matters. The biometrics-only policy fails outright on a device
/// with no Face ID hardware, and fails again after a few unrecognised looks —
/// with nothing behind it, that would lock someone out of their own private
/// tabs because they were wearing a scarf. The policy used here falls through
/// to the passcode, which is the same escape Apple puts behind every system
/// prompt.
enum BiometricGate {

    /// Whether the device can authenticate at all.
    ///
    /// False on a device with no passcode set, which is the case that decides
    /// how the rest of this behaves: there is no secret to check against, so
    /// there is nothing to put in front of private browsing. The setting is
    /// hidden rather than shown-and-broken, and `authenticate` lets the caller
    /// through rather than sealing the mode off entirely.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// What to call it in the settings row — whatever this device actually has.
    static var displayName: String {
        let context = LAContext()
        // Populates `biometryType`, which is `.none` until a policy is checked.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:       return "Passcode"
        }
    }

    /// Ask, and report whether it was granted.
    ///
    /// A fresh `LAContext` every time. A reused one remembers that it already
    /// succeeded and will wave the next call straight through — which for a
    /// lock that exists to be asked each time is the whole failure.
    ///
    /// Returns true when the device cannot authenticate. See `isAvailable`.
    @MainActor
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: reason)
        } catch {
            // Cancelled, failed, or interrupted. All of them mean no.
            return false
        }
    }
}
