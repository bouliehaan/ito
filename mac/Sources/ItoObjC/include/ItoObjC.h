#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. An Objective-C exception (AVAudioEngine raises them for things like a
/// tap format mismatch) comes back as an NSError instead of aborting the process —
/// Swift has no way to catch these on its own.
BOOL ITOCatch(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
