import Foundation
import ObjCExceptionCatcher

/// Error thrown when an Objective-C exception is caught by `withObjCExceptionsCaught`.
struct ObjCExceptionError: LocalizedError, Sendable {
    let name: String
    let reason: String?

    var errorDescription: String? {
        if let reason { return "\(name): \(reason)" }
        return name
    }
}

/// Runs `body`, converting any Objective-C `NSException` it raises into a thrown `ObjCExceptionError`.
///
/// AVFAudio reports programmer-error conditions (e.g. installing a tap whose format no longer matches
/// the hardware after a Bluetooth headset switched profiles) by raising NSExceptions, which Swift cannot
/// catch and which therefore terminate the process. Wrapping engine setup in this helper turns those
/// into ordinary recoverable errors. Swift errors thrown by `body` are rethrown unchanged.
func withObjCExceptionsCaught<T>(_ body: () throws -> T) throws -> T {
    var outcome: Result<T, Error>?
    let nsError = ObjCTryCatch {
        outcome = Result { try body() }
    }
    if let nsError {
        let info = (nsError as NSError).userInfo
        throw ObjCExceptionError(
            name: info[ObjCExceptionNameKey] as? String ?? "NSException",
            reason: info[ObjCExceptionReasonKey] as? String
        )
    }
    // `outcome` is always set when no exception was raised.
    return try outcome!.get()
}
