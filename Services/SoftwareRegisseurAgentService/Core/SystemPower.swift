import Foundation
import IOKit
import IOKit.pwr_mgt
import Synchronization

/// Ruhezustand-Steuerung des Dienstes (D3, K3).
///
/// - Kein dauerhafter Schlafverhinderer: höchstens eine Leerlauf-Assertion, solange Agenten tatsächlich
///   arbeiten **und** der Benutzer das in den Diensteinstellungen eingeschaltet hat.
/// - Systemenergieeinstellungen bleiben maßgeblich (manueller Ruhezustand, Deckel zu, Akku-Kritisch).
protocol SleepAssertionControlling: Sendable {
    /// Hält oder löst die Assertion „kein Leerlauf-Ruhezustand“.
    func setPreventIdleSleep(_ prevent: Bool, reason: String)
}

/// IOKit-Assertion `PreventUserIdleSystemSleep`.
final class IOKitSleepAssertion: SleepAssertionControlling {
    private let assertion = Mutex<IOPMAssertionID?>(nil)

    func setPreventIdleSleep(_ prevent: Bool, reason: String) {
        assertion.withLock { current in
            if prevent, current == nil {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertPreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &id
                )
                if result == kIOReturnSuccess {
                    current = id
                    ServiceLog.power.notice("Leerlauf-Ruhezustand während aktiver Agentenläufe verhindert")
                } else {
                    ServiceLog.power.error("Ruhezustand-Assertion nicht möglich: \(result, privacy: .private)")
                }
            } else if !prevent, let id = current {
                IOPMAssertionRelease(id)
                current = nil
                ServiceLog.power.notice("Leerlauf-Ruhezustand wieder erlaubt")
            }
        }
    }
}

/// Keine Assertion (Tests).
struct NoSleepAssertion: SleepAssertionControlling {
    func setPreventIdleSleep(_ prevent: Bool, reason: String) {}
}

/// Meldet Ruhezustand und Aufwachen über `IORegisterForSystemPower` auf einer Dispatch-Queue.
///
/// Bewusst IOKit statt `NSWorkspace`-Benachrichtigungen: der Dienst läuft mit `dispatchMain()` ohne
/// AppKit-Runloop. Der Ruhezustand wird nie verzögert (`IOAllowPowerChange` sofort).
final class SystemPowerObserver: @unchecked Sendable {
    enum Event: Sendable {
        case willSleep
        case didWake
    }

    private let queue = DispatchQueue(label: "SoftwareRegisseur.power")
    private let handler: @Sendable (Event) -> Void
    // Nur auf `queue` bzw. in init/deinit benutzt.
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    /// Registriert sich beim Power Management. `false`, wenn IOKit die Registrierung verweigert.
    @discardableResult
    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        let root = IORegisterForSystemPower(context, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let observer = Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.handle(messageType: messageType, argument: argument)
        }, &notifier)
        guard root != 0, let port else {
            ServiceLog.power.error("Registrierung für Ruhezustand-Meldungen fehlgeschlagen")
            return false
        }
        rootPort = root
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        return true
    }

    func stop() {
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    deinit { stop() }

    // `iokit_common_msg(...)`-Makros sind in Swift nicht importierbar (IOKit/IOMessage.h).
    private static let messageCanSystemSleep: natural_t = 0xE000_0270
    private static let messageSystemWillSleep: natural_t = 0xE000_0280
    private static let messageSystemHasPoweredOn: natural_t = 0xE000_0300

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.messageCanSystemSleep:
            // Leerlauf-Ruhezustand nie aus Dienstgründen ablehnen (D3); die Assertion regelt das.
            IOAllowPowerChange(rootPort, notificationID)
        case Self.messageSystemWillSleep:
            handler(.willSleep)
            IOAllowPowerChange(rootPort, notificationID)
        case Self.messageSystemHasPoweredOn:
            handler(.didWake)
        default:
            break
        }
    }
}
