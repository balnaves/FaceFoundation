//
//  TMFFView.h
//  FaceFoundation
//
//  Created by James Balnaves on 7/9/14.
//

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@interface TMFFView : NSView

@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *videoLayer;

@end
