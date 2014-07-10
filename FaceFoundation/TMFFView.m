//
//  TMFFView.m
//  FaceFoundation
//
//  Created by James Balnaves on 7/9/14.
//

#import "TMFFView.h"

#define FREEWHEELING_PERIOD_IN_SECONDS 0.5
#define ADVANCE_INTERVAL_IN_SECONDS 0.1

#define CREATE_CA_FACE_LAYERS 0

#pragma mark - TMFFLayer

/**
 A CALayer subclass that contains a reference to a Core Image facial recognition object.
 Eventually this will handle sublayers for eyes, mouth, etc.
 */
@interface TMFFLayer : CALayer
@property (strong, nonatomic) CIFaceFeature *faceFeature;
@end


@implementation TMFFLayer

- (id) init
{
    self = [super init];
    if (self)
    {
    }
    return self;
}

@end

#pragma mark - TMFFView

@interface TMFFView ()
{
	AVPlayerItem *_playerItem;
	AVPlayerItemVideoOutput *_playerItemVideoOutput;
	CVDisplayLinkRef _displayLink;
	CMVideoFormatDescriptionRef _videoInfo;
	
	uint64_t _lastHostTime;
	dispatch_queue_t _queue;
}

@property (nonatomic, strong) CIDetector *detector;
@property (nonatomic, strong) NSMutableDictionary *faceLayers;

@end

@interface TMFFView (AVPlayerItemOutputPullDelegate) <AVPlayerItemOutputPullDelegate>
@end

#pragma mark -

@implementation TMFFView

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                    const CVTimeStamp *inNow,
                                    const CVTimeStamp *inOutputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext);

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    
    if (self)
    {
		_queue = dispatch_queue_create(NULL, NULL);
		
		_playerItemVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB)}];
        
		if (_playerItemVideoOutput)
		{
			// Create a CVDisplayLink to receive a callback at every vsync
			CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
			CVDisplayLinkSetOutputCallback(_displayLink, displayLinkCallback, (__bridge void *)self);
            
			// Pause the displayLink till ready to conserve power
			CVDisplayLinkStop(_displayLink);
            
			// Request notification for media change in advance to start up displayLink or any setup necessary
			[_playerItemVideoOutput setDelegate:self queue:_queue];
			[_playerItemVideoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ADVANCE_INTERVAL_IN_SECONDS];
		}
		
		self.videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
		self.videoLayer.bounds = self.bounds;
		self.videoLayer.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
		self.videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
		self.videoLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        
		[self setLayer:self.videoLayer];
		[self setWantsLayer:YES];
		
        self.detector = [CIDetector detectorOfType:CIDetectorTypeFace
                                           context:nil
                                           options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh, CIDetectorTracking: @YES}];
        
        self.faceLayers = [NSMutableDictionary dictionaryWithCapacity:3];
    }
    return self;
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview
{
	if (!newSuperview)
    {
		CFRelease(_videoInfo);
		
		if (_displayLink)
		{
			CVDisplayLinkStop(_displayLink);
			CVDisplayLinkRelease(_displayLink);
		}
        
		dispatch_sync(_queue, ^{
			[_playerItemVideoOutput setDelegate:nil queue:NULL];
		});
	}
}

- (void)dealloc
{
	self.playerItem = nil;
	self.videoLayer = nil;
}

#pragma mark -

- (AVPlayerItem *)playerItem
{
	return _playerItem;
}

- (void)setPlayerItem:(AVPlayerItem *)playerItem
{
	if (_playerItem != playerItem)
	{
		if (_playerItem)
			[_playerItem removeOutput:_playerItemVideoOutput];
		
		_playerItem = playerItem;
		
		if (_playerItem)
			[_playerItem addOutput:_playerItemVideoOutput];
	}
}

#pragma mark -

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)outputTime
{
	// CVPixelBuffer is wrapped in a CMSampleBuffer and then displayed on a AVSampleBufferDisplayLayer
	CMSampleBufferRef sampleBuffer = NULL;
	OSStatus err = noErr;
    
	if (!_videoInfo || !CMVideoFormatDescriptionMatchesImageBuffer(_videoInfo, pixelBuffer))
    {
		err = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &_videoInfo);
	}
    
	if (err)
    {
		NSLog(@"Error at CMVideoFormatDescriptionCreateForImageBuffer %d", err);
	}
	
	// decodeTimeStamp is set to kCMTimeInvalid since we already receive decoded frames
	CMSampleTimingInfo sampleTimingInfo = {
		.duration = kCMTimeInvalid,
		.presentationTimeStamp = outputTime,
		.decodeTimeStamp = kCMTimeInvalid
	};
    
	// Wrap the pixel buffer in a sample buffer
	err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, _videoInfo, &sampleTimingInfo, &sampleBuffer);
	
	if (err)
    {
		NSLog(@"Error at CMSampleBufferCreateForImageBuffer %d", err);
	}
    
#if CREATE_CA_FACE_LAYERS
    [self findFacesAndAdjustLayersForPixelBuffer:pixelBuffer];
#else
    [self findFacesAndDrawBoundingRectsForPixelBuffer:pixelBuffer];
#endif
    
	// Enqueue sample buffers which will be displayed at their above set presentationTimeStamp
	if (self.videoLayer.readyForMoreMediaData)
    {
		[self.videoLayer enqueueSampleBuffer:sampleBuffer];
	}
    
	CFRelease(sampleBuffer);
}

/**
 Creates and positions a CALayer for each detected face in the CVPixelBuffer.
 If a face is no longer detected, the CALayer is removed.
 */
- (void)findFacesAndAdjustLayersForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    // Create a CIImage from the CV video image buffer so we can run the face detector against it.
    CIImage *image = [[CIImage alloc] initWithCVImageBuffer:pixelBuffer];
    
    // Run the CIDetector
    NSDictionary *options = @{ CIDetectorSmile: @(YES), CIDetectorEyeBlink: @(NO),};
    NSArray *features = [self.detector featuresInImage:image options:options];
    
    [CATransaction begin];
    [CATransaction setValue:(id)kCFBooleanTrue forKey: kCATransactionDisableActions];
    
    // Iterate over the detected face features and update the layers accordingly.
    NSMutableSet *currentTrackingIDs = [NSMutableSet set];
    for (CIFaceFeature *faceFeature in features)
    {
        CGRect faceBounds = [self transformRect:faceFeature.bounds
                                   forVideoSize:CGSizeMake(image.extent.size.width, image.extent.size.height)];
        
        if (faceFeature.trackingFrameCount == 1)
        {
            // This face is new (may be the same person back in frame),
            // CI does not detect *specific* faces.
            TMFFLayer *faceLayer = [[TMFFLayer alloc] init];
            faceLayer.faceFeature = faceFeature;
            faceLayer.borderColor = [NSColor orangeColor].CGColor;
            faceLayer.borderWidth = 2;
            faceLayer.cornerRadius = 5;
            faceLayer.frame = faceBounds;
            
            [self.faceLayers setObject:faceLayer forKey:@(faceFeature.trackingID)];
            [self.layer addSublayer:faceLayer];
        }
        else
        {
            // This face is still in frame and detectable
            TMFFLayer *faceLayer = [self.faceLayers objectForKey:@(faceFeature.trackingID)];
            faceLayer.frame = faceBounds;
            
            // Set the frame to green if the person is smiling! :)
            faceLayer.borderColor = faceFeature.hasSmile ? [NSColor greenColor].CGColor : [NSColor orangeColor].CGColor;
        }
        
        [currentTrackingIDs addObject: @(faceFeature.trackingID)];
    }
    
    // Now we want to find the set of IDs that we were tracking but are no longer detected
    NSMutableSet *removedTrackingIDs = [NSMutableSet setWithArray:self.faceLayers.allKeys];
    [removedTrackingIDs minusSet:currentTrackingIDs];
    
    // Now iterate over the faceLayers dictionary and remove any layers that are not longer detected.
    for (NSNumber *trackingID in removedTrackingIDs)
    {
        TMFFLayer *faceLayer = [self.faceLayers objectForKey:trackingID];
        [faceLayer removeFromSuperlayer];
    }
    
    [CATransaction commit];
    
    // Finally remove the trackingIDs from our dictionary
    [self.faceLayers removeObjectsForKeys:[removedTrackingIDs allObjects]];
}

/**
 Draw a rectangle around each detected face in the CVPixelBuffer.
 */
- (void)findFacesAndDrawBoundingRectsForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    //
    // Create a CGBitmap context from the CVPixelBuffer so we can draw into it.
    //
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    
    size_t bitsPerComponent = 8;
    CGBitmapInfo alphaInfo = kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst;
    
    // context to draw in, set to pixel buffer's address
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                                 CVPixelBufferGetWidth(pixelBuffer),
                                                 CVPixelBufferGetHeight(pixelBuffer),
                                                 bitsPerComponent,
                                                 CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                 cs,
                                                 alphaInfo);
    
    if (context)
    {
        // draw
        NSGraphicsContext *nsctxt = [NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:NO];
        
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:nsctxt];
        
        // Create a CIImage from the CV video image buffer so we can run the face detector against it.
        CIImage *image = [[CIImage alloc] initWithCVImageBuffer:pixelBuffer];
        
        // Run the CIDetector
        NSDictionary *options = @{ CIDetectorSmile: @(YES), CIDetectorEyeBlink: @(NO),};
        NSArray *features = [self.detector featuresInImage:image options:options];
        
        // Iterate over the detected face features and draw rectangles accordingly.
        for (CIFaceFeature *faceFeature in features)
        {
            [[NSColor orangeColor] setStroke];
            
            NSFrameRect(NSRectFromCGRect(faceFeature.bounds));
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

/**
 The feature bounds are relative to the full frame of video, so we need to work out
 where to place the sublayer relative to the frame of the AVSampleBufferDisplayLayer.
 It would be nice if the layer exposed the transformation it made on the video frame,
 but we can work it out ourselves.
 */
- (CGRect)transformRect:(CGRect)rect forVideoSize:(CGSize)size
{
    CGFloat scale = 1.f;
    CGFloat translationX = 0.f;
    CGFloat translationY = 0.f;
    
    CGFloat aspectSource = size.width / size.height;
    CGFloat aspectLayer = self.layer.frame.size.width / self.layer.frame.size.height;
    
    if (aspectLayer > aspectSource)
    {
        // Extra space on sides
        scale = self.layer.frame.size.height / size.height;
        translationX = (self.layer.frame.size.width - size.width * scale) / 2;
    }
    else
    {
        // Extra space on top and bottom
        scale = self.layer.frame.size.width / size.width;
        translationY = (self.layer.frame.size.height - size.height * scale) / 2;
    }
    
    CGAffineTransform transform = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale),
                                                          CGAffineTransformMakeTranslation(translationX, translationY));
    
    return CGRectApplyAffineTransform(rect, transform);
}

#pragma mark -

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                    const CVTimeStamp *inNow,
                                    const CVTimeStamp *inOutputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext)
{
	TMFFView *self = (__bridge TMFFView *)displayLinkContext;
	AVPlayerItemVideoOutput *playerItemVideoOutput = self->_playerItemVideoOutput;
	
	// The displayLink calls back at every vsync (screen refresh)
	// Compute itemTime for the next vsync
	CMTime outputItemTime = [playerItemVideoOutput itemTimeForCVTimeStamp:*inOutputTime];
    
	if ([playerItemVideoOutput hasNewPixelBufferForItemTime:outputItemTime])
	{
		self->_lastHostTime = inOutputTime->hostTime;
		
		// Copy the pixel buffer to be displayed next and add it to AVSampleBufferDisplayLayer for display
		CVPixelBufferRef pixBuff = [playerItemVideoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
		
		[self displayPixelBuffer:pixBuff atTime:outputItemTime];
		
		CVBufferRelease(pixBuff);
	}
	else
	{
		CMTime elapsedTime = CMClockMakeHostTimeFromSystemUnits(inNow->hostTime - self->_lastHostTime);
        
		if (CMTimeGetSeconds(elapsedTime) > FREEWHEELING_PERIOD_IN_SECONDS)
		{
			// No new images for a while.  Shut down the display link to conserve power,
            // but request a wakeup call if new images are coming.
			CVDisplayLinkStop(displayLink);
			[playerItemVideoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:ADVANCE_INTERVAL_IN_SECONDS];
		}
	}
	
	return kCVReturnSuccess;
}

@end

#pragma mark -

@implementation TMFFView (AVPlayerItemOutputPullDelegate)

- (void)outputMediaDataWillChange:(AVPlayerItemOutput *)sender
{
	// Start running again.
	_lastHostTime = CVGetCurrentHostTime();
	
	CVDisplayLinkStart(_displayLink);
}

@end
