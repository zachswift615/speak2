#import "ObjCExceptionCatcher.h"

NSErrorDomain const ObjCExceptionErrorDomain = @"ObjCExceptionErrorDomain";
NSString * const ObjCExceptionNameKey = @"ObjCExceptionName";
NSString * const ObjCExceptionReasonKey = @"ObjCExceptionReason";

NSError * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[ObjCExceptionNameKey] = exception.name ?: @"NSException";
        if (exception.reason) {
            userInfo[ObjCExceptionReasonKey] = exception.reason;
        }
        NSString *description = exception.reason
            ? [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]
            : exception.name;
        userInfo[NSLocalizedDescriptionKey] = description ?: @"Objective-C exception";
        return [NSError errorWithDomain:ObjCExceptionErrorDomain code:1 userInfo:userInfo];
    }
}
