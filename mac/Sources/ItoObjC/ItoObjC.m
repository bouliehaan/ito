#import "ItoObjC.h"

BOOL ITOCatch(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
            *error = [NSError errorWithDomain:@"ito.objc" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
}
