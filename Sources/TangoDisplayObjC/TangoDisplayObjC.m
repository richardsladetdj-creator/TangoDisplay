#import "include/TangoDisplayObjC.h"

BOOL TDTryAudioEngineConnect(AVAudioEngine *engine,
                              AVAudioNode   *source,
                              AVAudioNode   *destination,
                              AVAudioFormat *format,
                              NSString     **outReason) {
    @try {
        [engine connect:source to:destination format:format];
        return YES;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}

BOOL TDTryAudioPlayerPlay(AVAudioPlayerNode *player, NSString **outReason) {
    @try {
        [player play];
        return YES;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}

BOOL TDTryAudioEngineStart(AVAudioEngine *engine, NSString **outReason) {
    @try {
        NSError *error = nil;
        BOOL started = [engine startAndReturnError:&error];
        if (!started && outReason) *outReason = error.localizedDescription;
        return started;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}

AVAudioFile *TDTryOpenAudioFile(NSURL *url, NSString **outReason) {
    @try {
        NSError *error = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
        if (!file && outReason) *outReason = error.localizedDescription;
        return file;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return nil;
    }
}

BOOL TDTryAudioPlayerSchedule(AVAudioPlayerNode *player, AVAudioFile *file,
                              AVAudioFramePosition start, AVAudioFrameCount count,
                              void (^completion)(void), NSString **outReason) {
    @try {
        AVAudioPlayerNodeCompletionHandler handler = ^(AVAudioPlayerNodeCompletionCallbackType _) {
            completion();
        };
        if (count == 0) {
            [player scheduleFile:file atTime:nil
                     completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
                           completionHandler:handler];
        } else {
            [player scheduleSegment:file startingFrame:start frameCount:count atTime:nil
                        completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
                              completionHandler:handler];
        }
        return YES;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}

BOOL TDTryAudioPlayerScheduleBuffer(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer,
                                    void (^completion)(void), NSString **outReason) {
    @try {
        [player scheduleBuffer:buffer atTime:nil options:0
         completionCallbackType:AVAudioPlayerNodeCompletionDataConsumed
               completionHandler:^(AVAudioPlayerNodeCompletionCallbackType _) { completion(); }];
        return YES;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}

BOOL TDTryInstallAudioMeterTap(AVAudioNode *node, BOOL replacing, AVAudioNodeTapBlock tap,
                               NSString **outReason) {
    @try {
        if (replacing) [node removeTapOnBus:0];
        [node installTapOnBus:0 bufferSize:1024 format:nil block:tap];
        return YES;
    } @catch (NSException *ex) {
        if (outReason) *outReason = ex.reason ?: ex.name;
        return NO;
    }
}
