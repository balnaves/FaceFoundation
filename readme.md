# FaceFoundation
## Introduction
FaceFoundation is a simple AV Foundation document-based application that runs CIDetector face recognition on a real-time video playback buffer, using AVPlayerItemVideoOutput.

It is intended to be used to experiment with several ways of using the AVPlayerItemVideoOutput.
Currently it supports annotating faces using 2 methods:

1. By creating an additional CALayer for each recognised face and reframing those in real-time to follow the faces in the video. Using this method the frame is a similar thickness and drawing style regardless of the video scaling.
2. By creating a CGBitmapContext from the CVPixelBuffer data and drawing directly onto that. Using this method the drawn frame is scaled with the video.

## Notes
It originally used Apple sample code as a starting point.

