//
//  ObjCExceptionCatcher.m
//  SapoWhisper
//

#import "ObjCExceptionCatcher.h"

NSException *_Nullable SapoWhisperCatchObjCException(void(NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
