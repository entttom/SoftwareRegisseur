import AVFAudio
import Speech
import SoftwareRegisseurAppCore

/// Reads and requests microphone and speech recognition permission. Requests happen only from
/// `PermissionFlow.continueTapped()`, i.e. directly after „Weiter“ on the explanation screen (spec Q4).
/// Notification permission is never requested (ADR-0011).
struct SystemPermissionAuthorizer: PermissionAuthorizing {
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            case .undetermined: .notDetermined
            @unknown default: .denied
            }
        case .speechRecognition:
            Self.map(SFSpeechRecognizer.authorizationStatus())
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        case .speechRecognition:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return Self.map(status)
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
