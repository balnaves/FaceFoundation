//
//  TMFFDocument.h
//  FaceFoundation
//
//  Created by James Balnaves on 7/7/14.
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@class TMFFView;
@class TMFFTimeSlider;

@interface TMFFDocument : NSDocument

@property (nonatomic, assign) IBOutlet TMFFView *playerView;
@property (nonatomic, assign) IBOutlet NSButton *playPauseButton;
@property (nonatomic, assign) IBOutlet TMFFTimeSlider *currentTimeSlider;

@property double currentTime;
@property (readonly) double duration;

- (IBAction)togglePlayPause:(id)sender;

@end
