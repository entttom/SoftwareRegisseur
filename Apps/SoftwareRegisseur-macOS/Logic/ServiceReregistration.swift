import Foundation

/// Spike S3, belegt am 2026-11-02 beim Update 1.0.0 → 1.0.1: Sparkle tauscht das Bundle samt Agent Service aus,
/// aber die bei der Registrierung über `SMAppService` hinterlegte Startbedingung (Launch Constraint) passt nicht
/// mehr zum neuen Dienst. Der alte Prozess läuft mit altem Code weiter; jeder Neustart scheitert mit
/// `OS_REASON_CODESIGNING | Launch Constraint Violation`. Erneutes Deregistrieren und Registrieren erneuert die
/// Bedingung. Das macht die App einmal je neuer Build-Nummer, wenn der Dienst registriert ist.
enum ServiceReregistrationPolicy {
    /// Build-Nummer, mit der der Dienst zuletzt registriert wurde (UserDefaults der Mac-App).
    static let registeredBuildKey = "SRAgentServiceRegisteredBuild"

    /// - Parameters:
    ///   - registeredBuild: zuletzt registrierte Build-Nummer; nil bei Registrierung durch eine ältere Version.
    ///   - isEnabled: `SMAppService.Status.enabled`. Nicht registriert, oder noch ohne Freigabe: nichts tun.
    static func needsReregistration(registeredBuild: String?, currentBuild: String, isEnabled: Bool) -> Bool {
        isEnabled && !currentBuild.isEmpty && registeredBuild != currentBuild
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}
