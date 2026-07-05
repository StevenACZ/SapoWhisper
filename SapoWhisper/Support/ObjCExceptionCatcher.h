//
//  ObjCExceptionCatcher.h
//  SapoWhisper
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch and returns the caught
/// NSException, or nil when the block completed normally.
///
/// AVFAudio validates preconditions (tap formats, HAL device state) by
/// throwing NSException, which Swift cannot catch — during audio route
/// transitions (AirPods connecting, headset plug/unplug) those throws killed
/// the whole app with SIGABRT. This shim turns them into values the Swift
/// side can convert into recoverable errors.
NSException *_Nullable SapoWhisperCatchObjCException(void(NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
