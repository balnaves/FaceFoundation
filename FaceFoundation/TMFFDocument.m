//
//  TMFFDocument.m
//  FaceFoundation
//
//  Created by James Balnaves on 7/7/14.
//

#import <AVFoundation/AVFoundation.h>

#import "TMFFDocument.h"
#import "TMFFView.h"

static void *TMFFPlayerItemStatusContext = &TMFFPlayerItemStatusContext;

NSString* const TMFFMouseDownNotification = @"TMFFMouseDownNotification";
NSString* const TMFFMouseUpNotification = @"TMFFMouseUpNotification";

@interface TMFFTimeSliderCell : NSSliderCell

@end

@interface TMFFTimeSlider : NSSlider

@end

// Custom NSSlider and NSSliderCell subclasses to track scrubbing.
// Make sure the proper bindings are set up in IB as well.

@implementation TMFFTimeSliderCell

- (void)stopTracking:(NSPoint)lastPoint at:(NSPoint)stopPoint inView:(NSView *)controlView mouseIsUp:(BOOL)flag
{
	if (flag)
    {
		[[NSNotificationCenter defaultCenter] postNotificationName:TMFFMouseUpNotification object:self];
	}
	[super stopTracking:lastPoint at:stopPoint inView:controlView mouseIsUp:flag];
}

@end

@implementation TMFFTimeSlider

- (void)mouseDown:(NSEvent *)theEvent
{
	[[NSNotificationCenter defaultCenter] postNotificationName:TMFFMouseDownNotification object:self];
	[super mouseDown:theEvent];
}

@end

@implementation TMFFDocument

{
	AVPlayer *_player;
    AVPlayerItem *_currentPlayerItem;
	float _playRateToRestore;
	id _observer;
}

#pragma mark -

- (id)init
{
	self = [super init];
	
	if (self)
	{
		_player = [[AVPlayer alloc] init];
		
		[self addTimeObserverToPlayer];
    }
	
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TMFFMouseDownNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TMFFMouseUpNotification object:nil];
	
	[_player removeTimeObserver:_observer];
	
	_player = nil;
	_currentPlayerItem = nil;
}

#pragma mark -

- (NSString *)windowNibName
{
	return @"TMFFDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)windowController
{
	[super windowControllerDidLoadNib:windowController];
	
    _currentPlayerItem = [_player currentItem];
    
	self.playerView.playerItem = _currentPlayerItem;
    
	[self.currentTimeSlider setDoubleValue:0.0];
	
    
    // Subscribe to KVO for the players' current item status
    
	[self addObserver:self
           forKeyPath:@"self.player.currentItem.status"
              options:NSKeyValueObservingOptionNew
              context:TMFFPlayerItemStatusContext];
    
    // Subscribe to some NSNotifications
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:_currentPlayerItem];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(beginScrubbing:)
                                                 name:TMFFMouseDownNotification object:self.currentTimeSlider];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(endScrubbing:)
                                                 name:TMFFMouseUpNotification object:self.currentTimeSlider.cell];
}

- (void)close
{
	self.playerView = nil;
	self.playPauseButton = nil;
	self.currentTimeSlider = nil;
	
	[self removeObserver:self forKeyPath:@"self.player.currentItem.status"];
	
	[super close];
}

#pragma mark -

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError *__autoreleasing *)outError
{
	AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:url];
	if (playerItem)
	{
		[_player replaceCurrentItemWithPlayerItem:playerItem];
		return YES;
	}
	return NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == TMFFPlayerItemStatusContext)
    {
		AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
		if (status == AVPlayerItemStatusReadyToPlay)
        {
			self.playerView.videoLayer.controlTimebase = _player.currentItem.timebase;
		}
	}
	else
    {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark -

- (IBAction)togglePlayPause:(id)sender
{
	if (CMTIME_COMPARE_INLINE([[_player currentItem] currentTime], >=, [[_player currentItem] duration]))
    {
		[[_player currentItem] seekToTime:kCMTimeZero];
    }
	
	[_player setRate:([_player rate] == 0.0f ? 1.0f : 0.0f)];
	
	[(NSButton *)sender setTitle:([_player rate] == 0.0f ? @"Play" : @"Pause")];
}

+ (NSSet *)keyPathsForValuesAffectingDuration
{
	return [NSSet setWithObjects:@"player.currentItem", @"player.currentItem.status", nil];
}

- (double)duration
{
	AVPlayerItem *playerItem = [_player currentItem];
	
	if ([playerItem status] == AVPlayerItemStatusReadyToPlay)
		return CMTimeGetSeconds([[playerItem asset] duration]);
	else
		return 0.f;
}

- (double)currentTime
{
	return CMTimeGetSeconds([_player currentTime]);
}

- (void)setCurrentTime:(double)time
{
	// Flush the previous enqueued sample buffers for display while scrubbing
	[self.playerView.videoLayer flush];
	
	[_player seekToTime:CMTimeMakeWithSeconds(time, 1)];
}

#pragma mark -

- (void)playerItemDidPlayToEndTime:(NSNotification *)notification
{
	[(NSButton *)self.playPauseButton setTitle:([_player rate] == 0.0f ? @"Play" : @"Pause")];
}

- (void)addTimeObserverToPlayer
{
	if (_observer)
		return;
    // __weak is used to ensure that a retain cycle between the document, player and notification block is not formed.
	__weak TMFFDocument* weakSelf = self;
	_observer = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1, 10) queue:dispatch_get_main_queue() usingBlock:
                 ^(CMTime time) {
                     [weakSelf syncScrubber];
                 }];
}

- (void)removeTimeObserverFromPlayer
{
	if (_observer)
	{
		[_player removeTimeObserver:_observer];
		_observer = nil;
	}
}

#pragma mark - Scrubbing Utilities

- (void)beginScrubbing:(NSNotification*)notification
{
	_playRateToRestore = [_player rate];
	
	[self removeTimeObserverFromPlayer];
	
	[_player setRate:0.0];
}

- (void)endScrubbing:(NSNotification*)notification
{
	[_player setRate:_playRateToRestore];
	
	[self addTimeObserverToPlayer];
}

- (void)syncScrubber
{
	double time = CMTimeGetSeconds([_player currentTime]);
	
	[self.currentTimeSlider setDoubleValue:time];
}

@end