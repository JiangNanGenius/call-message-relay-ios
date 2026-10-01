#import "CKExceptionGuard.h"

@implementation CKExceptionGuard

+ (BOOL)executeCatchingException:(void (^)(void))block
                           error:(NSString *__autoreleasing _Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"";
            // Never bubble entitlement/account internals beyond a short note.
            *error = [NSString stringWithFormat:@"%@: %@", exception.name ?: @"NSException",
                      reason.length > 160 ? [reason substringToIndex:160] : reason];
        }
        return NO;
    }
}

+ (void)raiseTestException {
    [NSException raise:@"CMRTestException" format:@"synthetic ObjC exception for bridge tests"];
}

@end
