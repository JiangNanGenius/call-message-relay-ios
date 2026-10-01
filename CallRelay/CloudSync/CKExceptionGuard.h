#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions raised by CloudKit.
///
/// A provisioning profile can list broader iCloud rights than the effective
/// code signature actually carries (Feather/re-sign with stripped rights is
/// the concrete case). `CKContainer(identifier:)` then raises an
/// NSException ("This process has the right to..." / missing entitlement),
/// which Swift do/catch cannot handle and which crashes the app. This bridge
/// is a public-API-only ObjC @try/@catch boundary (no SecTask/SecCode, no
/// private API).
@interface CKExceptionGuard : NSObject

/// Execute `block`, catching any NSException. Returns NO and fills `error`
/// with a sanitized exception name/reason when an exception was caught.
+ (BOOL)executeCatchingException:(void (^)(void))block
                           error:(NSString *_Nullable *_Nullable)error
    NS_SWIFT_NAME(executeCatchingException(_:error:));

/// Test-only: raises a deterministic NSException so unit tests can prove the
/// bridge actually catches Objective-C exceptions without crashing.
+ (void)raiseTestException;

@end

NS_ASSUME_NONNULL_END
