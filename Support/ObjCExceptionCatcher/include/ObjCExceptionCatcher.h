#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception (NSException) it raises.
///
/// Swift cannot catch NSExceptions; when a framework such as AVFAudio raises one
/// (e.g. `required condition is false: format.sampleRate == hwFormat.sampleRate`
/// from `AVAudioEngine`), the process terminates. This shim converts the exception
/// into an `NSError` so callers can recover instead of crashing.
///
/// Returns `nil` when the block completes normally.
NSError * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^block)(void));

/// Error domain used for caught Objective-C exceptions.
extern NSErrorDomain const ObjCExceptionErrorDomain;
/// `userInfo` key holding the exception's `name`.
extern NSString * const ObjCExceptionNameKey;
/// `userInfo` key holding the exception's `reason` (may be absent).
extern NSString * const ObjCExceptionReasonKey;

NS_ASSUME_NONNULL_END
