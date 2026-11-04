#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GStreamerVideoPlayerState) {
    GStreamerVideoPlayerStateIdle,
    GStreamerVideoPlayerStateConnecting,
    GStreamerVideoPlayerStatePlaying,
    GStreamerVideoPlayerStateReconnecting,
    GStreamerVideoPlayerStateStopped,
    GStreamerVideoPlayerStateFailed,
};

@class GStreamerVideoPlayer;

@protocol GStreamerVideoPlayerDelegate <NSObject>
- (void)videoPlayer:(GStreamerVideoPlayer *)player didChangeState:(GStreamerVideoPlayerState)state;
- (void)videoPlayer:(GStreamerVideoPlayer *)player
 didUpdateVideoWidth:(NSInteger)width
              height:(NSInteger)height
           frameRate:(double)frameRate;
- (void)videoPlayer:(GStreamerVideoPlayer *)player
 didUpdateMeasuredFrameRate:(double)frameRate
       lastFrameTime:(NSDate *)lastFrameTime;
- (void)videoPlayer:(GStreamerVideoPlayer *)player didReceiveError:(NSString *)message;
@end

@interface GStreamerVideoPlayer : NSObject
@property(nonatomic, weak, nullable) id<GStreamerVideoPlayerDelegate> delegate;

- (void)startWithURLString:(NSString *)URLString
                 transport:(NSString *)transport
       latencyMilliseconds:(NSInteger)latencyMilliseconds
       stallTimeoutSeconds:(NSTimeInterval)stallTimeoutSeconds
                renderView:(NSView *)renderView;
- (void)stop;
- (void)reconnect;
- (void)setRenderView:(nullable NSView *)renderView;
@end

NS_ASSUME_NONNULL_END
