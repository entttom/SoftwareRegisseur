import UIKit

/// The kind of device the universal app runs on (ADR-0025): texts say „auf diesem iPhone“ or
/// „auf diesem iPad“. Each variant is a complete sentence in the String Catalog, so later languages
/// can translate the grammar per device instead of splicing a device name into a sentence.
enum DeviceKind: Sendable {
    case phone
    case pad

    /// Fixed for the lifetime of the process. Read once on the main thread at launch
    /// (`SoftwareRegisseurApp.init`); later reads from any thread return the cached value.
    static let current: DeviceKind = {
        let read: @MainActor () -> DeviceKind = {
            UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(read)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
    }()

    /// Returns the variant written for this device, e.g.
    /// `DeviceKind.current.pick(phone: "Dieses iPhone", pad: "Dieses iPad")`.
    func pick<Value>(phone: Value, pad: Value) -> Value {
        switch self {
        case .phone: phone
        case .pad: pad
        }
    }
}
