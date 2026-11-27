#import <AVFAudio/AVFAudio.h>

// Umbrella header: SwiftPM exposes this module through this file alone, so anything
// Swift needs to see has to be reachable from here.
#import "TDRestoration.h"
#import "TDTagWriter.h"

NS_ASSUME_NONNULL_BEGIN

/// Calls -[AVAudioEngine connect:to:format:] inside @try/@catch.
/// Returns YES on success. On failure, *outReason is set to the exception reason.
BOOL TDTryAudioEngineConnect(AVAudioEngine *engine,
                              AVAudioNode   *source,
                              AVAudioNode   *destination,
                              AVAudioFormat * _Nullable format,
                              NSString * _Nullable * _Nullable outReason);

BOOL TDTryAudioPlayerPlay(AVAudioPlayerNode *player, NSString * _Nullable * _Nullable outReason);
BOOL TDTryAudioEngineStart(AVAudioEngine *engine, NSString * _Nullable * _Nullable outReason);
AVAudioFile * _Nullable TDTryOpenAudioFile(NSURL *url, NSString * _Nullable * _Nullable outReason) NS_RETURNS_RETAINED;

/// A zero frame count means schedule the whole file from its beginning.
BOOL TDTryAudioPlayerSchedule(AVAudioPlayerNode *player, AVAudioFile *file,
                              AVAudioFramePosition start, AVAudioFrameCount count,
                              void (^completion)(void), NSString * _Nullable * _Nullable outReason);

BOOL TDTryAudioPlayerScheduleBuffer(AVAudioPlayerNode *player, AVAudioPCMBuffer *buffer,
                                    void (^completion)(void), NSString * _Nullable * _Nullable outReason);

BOOL TDTryInstallAudioMeterTap(AVAudioNode *node, BOOL replacing, AVAudioNodeTapBlock tap,
                               NSString * _Nullable * _Nullable outReason);

NS_ASSUME_NONNULL_END
