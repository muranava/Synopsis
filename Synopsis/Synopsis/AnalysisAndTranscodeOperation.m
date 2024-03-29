//
//  TranscodeOperation.m
//  MetadataTranscoderTestHarness
//
//  Created by vade on 3/31/15.
//  Copyright (c) 2015 Synopsis. All rights reserved.
//

#import "AnalysisAndTranscodeOperation.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#import "AnalyzerPluginProtocol.h"

#import "NSDictionary+JSONString.h"
#import "BSON/BSONSerialization.h"
#import "GZIP/GZIP.h"

@interface AnalysisAndTranscodeOperation ()
{
}

// Prerequisites
@property (atomic, readwrite, strong) NSDictionary* transcodeOptions;
@property (atomic, readwrite, strong) NSArray* availableAnalyzers;



// If we Transcode
// Pass 1: we create our video decoders and analyzers and encoders

// If we dont Transcode
// Pass 1: we create out video decoders and analyzers

// Pass 2:
// we always make passthrough sample buffer readers and writers
// and make new metadata writers

// If we dont, we simply create our video sample buffer readers and writers for pass 2
@property (atomic, readwrite, assign) BOOL transcoding;
@property (atomic, readwrite, assign) BOOL transcodeAssetHasVideo;
@property (atomic, readwrite, assign) BOOL transcodeAssetHasAudio;

@property (atomic, readwrite, strong) NSDictionary* videoTranscodeSettings;
@property (atomic, readwrite, strong) NSDictionary* audioTranscodeSettings;

// Eventually becomes our analyzed metadata - this stuff is mutated during reading of frames
@property (atomic, readwrite, strong) NSMutableArray* inFlightVideoSampleBufferMetadata;
@property (atomic, readwrite, strong) NSMutableArray* inFlightAudioSampleBufferMetadata;
@property (atomic, readwrite, strong) NSMutableDictionary* inFlightGlobalMetadata;

// Reading the original sample Data
@property (atomic, readwrite, strong) AVURLAsset* transcodeAsset;
@property (atomic, readwrite, strong) AVAssetReader* transcodeAssetReader;
@property (atomic, readwrite, strong) AVAssetReaderTrackOutput* transcodeAssetReaderVideo;
@property (atomic, readwrite, strong) AVAssetReaderTrackOutput* transcodeAssetReaderAudio;

// We have optional pass through readers, which allow us to output pixel formats for analysis
// But we pass through the original data un-re-encoded to avoid generational loss
// Note that these are only used if our transcodeOptions dictionary is correctly configured
// See header for info.
@property (atomic, readwrite, strong) AVAssetReaderTrackOutput* transcodeAssetReaderVideoPassthrough;
@property (atomic, readwrite, strong) AVAssetReaderTrackOutput* transcodeAssetReaderAudioPassthrough;

// Writing new sample data (passthrough or transcode) + Metdata
@property (atomic, readwrite, strong) AVAssetWriter* transcodeAssetWriter;
@property (atomic, readwrite, strong) AVAssetWriterInput* transcodeAssetWriterVideo;
@property (atomic, readwrite, strong) AVAssetWriterInput* transcodeAssetWriterAudio;

@end

@implementation AnalysisAndTranscodeOperation

- (id) initWithSourceURL:(NSURL*)sourceURL destinationURL:(NSURL*)destinationURL transcodeOptions:(NSDictionary*)transcodeOptions availableAnalyzers:(NSArray*)analyzers
{
    self = [super init];
    if(self)
    {
        if(transcodeOptions == nil)
        {
            return nil;
        }
        
        // Nil settings provides raw undecoded samples, ie passthrough.
        // Note we still need to decode to send to our analyzers

        self.transcodeOptions = transcodeOptions;
        self.videoTranscodeSettings = nil;
        self.audioTranscodeSettings = nil;
        
        if(self.transcodeOptions[kSynopsisTranscodeVideoSettingsKey] != [NSNull null])
        {
            self.videoTranscodeSettings = self.transcodeOptions[kSynopsisTranscodeVideoSettingsKey];
        }
        
        if(self.transcodeOptions[kSynopsisTranscodeAudioSettingsKey] != [NSNull null])
        {
            self.audioTranscodeSettings = self.transcodeOptions[kSynopsisTranscodeAudioSettingsKey];
        }
        
        if(self.audioTranscodeSettings || self.videoTranscodeSettings)
        {
            self.transcoding = YES;
        }

        self.sourceURL = sourceURL;
        self.destinationURL = destinationURL;
        
        // Initialize an array of available analyzers from our analyzer class names
        NSMutableArray* initializedAnalyzers = [NSMutableArray new];
        for(NSString* analyzerClassNameString in analyzers)
        {
            Class pluginClass = NSClassFromString(analyzerClassNameString);
            id<AnalyzerPluginProtocol> pluginInstance = [[pluginClass alloc] init];

            [initializedAnalyzers addObject:pluginInstance];
        }
        
        self.availableAnalyzers = initializedAnalyzers;
        
        self.inFlightGlobalMetadata = [NSMutableDictionary new];
        self.inFlightVideoSampleBufferMetadata = [NSMutableArray new];
        self.inFlightAudioSampleBufferMetadata = [NSMutableArray new];
        
        [self setupTranscodeShitSucessfullyOrDontWhatverMan];
    }
    return self;
}

- (NSString*) description
{
    return [NSString stringWithFormat:@"Transcode Operation: %p, Source: %@, Destination: %@, options: %@", self, self.sourceURL, self.destinationURL, self.transcodeOptions];
}

- (void) main
{
    [self transcodeAndAnalyzeAsset];

    [super main];
}


- (NSError*) setupTranscodeShitSucessfullyOrDontWhatverMan
{
    self.transcodeAsset = [AVURLAsset URLAssetWithURL:self.sourceURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @TRUE}];
    
    self.transcodeAssetHasVideo = [self.transcodeAsset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual].count ? YES : NO;
    self.transcodeAssetHasAudio = [self.transcodeAsset tracksWithMediaCharacteristic:AVMediaCharacteristicAudible].count ? YES : NO;
    
    // TODO: error checking / handling
    NSError* error = nil;
    
    // Readers
    self.transcodeAssetReader = [AVAssetReader assetReaderWithAsset:self.transcodeAsset error:&error];
    
    // Video Reader -
    if(self.transcodeAssetHasVideo)
    {
        AVAssetTrack* firstVideoTrack = [self.transcodeAsset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual][0];
        self.transcodeAssetReaderVideo = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:firstVideoTrack
                                                                                    outputSettings:@{ (NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                                                                                      }];
        self.transcodeAssetReaderVideo.alwaysCopiesSampleData = YES;

        // Do we use passthrough?
        if(!self.transcoding)
        {
            self.transcodeAssetReaderVideoPassthrough = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:firstVideoTrack outputSettings:nil];
            self.transcodeAssetReaderVideoPassthrough.alwaysCopiesSampleData = YES;
        }
    }
    
    // Audio Reader -
    if(self.transcodeAssetHasAudio)
    {
        AVAssetTrack* firstAudioTrack = [self.transcodeAsset tracksWithMediaCharacteristic:AVMediaCharacteristicAudible][0];
        self.transcodeAssetReaderAudio = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:firstAudioTrack
                                                                                outputSettings:@{(NSString*) AVFormatIDKey : @(kAudioFormatLinearPCM)}];
        self.transcodeAssetReaderAudio.alwaysCopiesSampleData = YES;
        
        if(!self.transcoding)
        {
            self.transcodeAssetReaderAudioPassthrough = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:firstAudioTrack outputSettings:nil];
            self.transcodeAssetReaderAudioPassthrough.alwaysCopiesSampleData = YES;
        }
    }

    // Assign all our specific Outputs to our Reader
    // TODO: Error handling if we cant add outputs
    if(self.transcodeAssetHasVideo)
    {
        // Always decoding in Pass 1
        if([self.transcodeAssetReader canAddOutput:self.transcodeAssetReaderVideo])
        {
            [self.transcodeAssetReader addOutput:self.transcodeAssetReaderVideo];
        }
        
        if(!self.transcoding)
        {
            if([self.transcodeAssetReader canAddOutput:self.transcodeAssetReaderVideoPassthrough])
            {
                // only add outputs if we are using them.
                [self.transcodeAssetReader addOutput:self.transcodeAssetReaderVideoPassthrough];
            }
        }
    }

    if(self.transcodeAssetHasAudio)
    {
        if([self.transcodeAssetReader canAddOutput:self.transcodeAssetReaderAudio])
        {
            [self.transcodeAssetReader addOutput:self.transcodeAssetReaderAudio];
        }

        if(!self.transcoding)
        {
            if([self.transcodeAssetReader canAddOutput:self.transcodeAssetReaderAudioPassthrough])
            {
                [self.transcodeAssetReader addOutput:self.transcodeAssetReaderAudioPassthrough];
            }
        }
    }
    
    // Writers
    self.transcodeAssetWriter = [AVAssetWriter assetWriterWithURL:self.destinationURL fileType:AVFileTypeQuickTimeMovie error:&error];
    self.transcodeAssetWriterVideo = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.videoTranscodeSettings];
    self.transcodeAssetWriterAudio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:self.audioTranscodeSettings];
    
    // Assign all our specific inputs to our Writer
    if([self.transcodeAssetWriter canAddInput:self.transcodeAssetWriterVideo]
       && [self.transcodeAssetWriter canAddInput:self.transcodeAssetWriterAudio]
       )
    {
        if(self.transcodeAssetHasVideo)
            [self.transcodeAssetWriter addInput:self.transcodeAssetWriterVideo];
        
        if(self.transcodeAssetHasAudio)
            [self.transcodeAssetWriter addInput:self.transcodeAssetWriterAudio];
    }

    // For every Analyzer, begin an new Analysis Session
    for(id<AnalyzerPluginProtocol> analyzer in self.availableAnalyzers)
    {
        [analyzer beginMetadataAnalysisSessionWithQuality:SynopsisAnalysisQualityHintHigh andEnabledModules:nil];
    }
    
    return error;
}


- (void) transcodeAndAnalyzeAsset
{
    CGFloat assetDurationInSeconds = CMTimeGetSeconds(self.transcodeAsset.duration);
    
    if([self.transcodeAssetWriter startWriting] && [self.transcodeAssetReader startReading])
    {
        [self.transcodeAssetWriter startSessionAtSourceTime:kCMTimeZero];
    
        // We need a dispatch group since we have to wrangle multiple queues successfully.
        // Signal both audio and video are done within this task
        dispatch_group_t g = dispatch_group_create();

        // 0 = use as much as you want.
        // Probably want to throttle this and set a small usleep to keep threads happy
        // Or use the CMBufferqueue callbacks with a semaphore signal
        CMItemCount numBuffers = 0;
        
        // Decode and Encode Queues - each pair writes or reads to a CMBufferQueue
        CMBufferQueueRef passthroughVideoBufferQueue;
        CMBufferQueueCreate(kCFAllocatorDefault, numBuffers, CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS(), &passthroughVideoBufferQueue);

        CMBufferQueueRef uncompressedVideoBufferQueue;
        CMBufferQueueCreate(kCFAllocatorDefault, numBuffers, CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS(), &uncompressedVideoBufferQueue);

        dispatch_queue_t passthroughVideoDecodeQueue = dispatch_queue_create("passthroughVideoDecodeQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(g);
        
        dispatch_queue_t passthroughVideoEncodeQueue = dispatch_queue_create("passthroughVideoEncodeQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(g);
        
        // We always need to decode uncompressed frames to send to our analysis plugins
        dispatch_queue_t uncompressedVideoDecodeQueue = dispatch_queue_create("uncompressedVideoDecodeQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_group_enter(g);
        
        // Make a semaphor to control when our reads happen, we wait to write once we have a signal that weve read.
        dispatch_semaphore_t videoDequeueSemaphore = dispatch_semaphore_create(0);
        
//        CMBufferQueueRef passthroughAudioBufferQueue;
//        CMBufferQueueCreate(kCFAllocatorDefault, numBuffers, CMBufferQueueGetCallbacksForSampleBuffersSortedByOutputPTS(), &passthroughAudioBufferQueue);
//
//        dispatch_queue_t audioPassthroughDecodeQueue = dispatch_queue_create("audioPassthroughDecodeQueue", 0);
//        dispatch_group_enter(g);
//
//        dispatch_queue_t audioPassthroughEncodeQueue = dispatch_queue_create("audioPassthroughEncodeQueue", 0);
//        dispatch_group_enter(g);
        

        __block BOOL finishedReadingAllPassthroughVideo = NO;
        
        // Passthrough Video Read into our Buffer Queue
        dispatch_async(passthroughVideoDecodeQueue, ^{
            
            // read sample buffers from our video reader - and append them to the queue.
            // only read while we have samples, and while our buffer queue isnt full
            
            while(self.transcodeAssetReader.status == AVAssetReaderStatusReading)
            {
                @autoreleasepool
                {
                    CMSampleBufferRef passthroughVideoSampleBuffer = [self.transcodeAssetReaderVideoPassthrough copyNextSampleBuffer];
                    if(passthroughVideoSampleBuffer)
                    {
                        // Only add to our passthrough buffer queue if we are going to use those buffers on the encoder end.
                        if(!self.transcoding)
                        {
                            CMBufferQueueEnqueue(passthroughVideoBufferQueue, passthroughVideoSampleBuffer);
                            // Free to dequeue on other thread
                            dispatch_semaphore_signal(videoDequeueSemaphore);
                        }
                        
                        CFRelease(passthroughVideoSampleBuffer);
                    }
                    else
                    {
                        // Got NULL - were done
                        break;
                    }
                }
            }
            
            finishedReadingAllPassthroughVideo = YES;

            [[LogController sharedLogController] appendSuccessLog:@"Finished Passthrough Video Buffers"];

            // Fire final semaphore signal to hit finalization
            dispatch_semaphore_signal(videoDequeueSemaphore);

            dispatch_group_leave(g);
        });
        
        // TODO : look at SampleTimingInfo Struct to better get a handle on this shit.
        __block NSUInteger sampleCount = 0;
        __block CMTimeRange lastSampleTimeRange = kCMTimeRangeZero;
        __block BOOL finishedReadingAllUncompressedVideo = NO;

        dispatch_async(uncompressedVideoDecodeQueue, ^{
            
            while(self.transcodeAssetReader.status == AVAssetReaderStatusReading)
            {
                @autoreleasepool
                {
                    CMSampleBufferRef uncompressedVideoSampleBuffer = [self.transcodeAssetReaderVideo copyNextSampleBuffer];
                    if(uncompressedVideoSampleBuffer)
                    {
                        // Only add to our uncompressed buffer queue if we are going to use those buffers on the encoder end.
                        if(self.transcoding)
                        {
                            CMBufferQueueEnqueue(uncompressedVideoBufferQueue, uncompressedVideoSampleBuffer);
                            // Free to dequeue on other thread
                            dispatch_semaphore_signal(videoDequeueSemaphore);
                        }

                        CMTime currentSamplePTS = CMSampleBufferGetOutputPresentationTimeStamp(uncompressedVideoSampleBuffer);
                        CMTime currentSampleDuration = CMSampleBufferGetOutputDuration(uncompressedVideoSampleBuffer);
                        CMTimeRange currentSampleTimeRange = CMTimeRangeMake(currentSamplePTS, currentSampleDuration);
                        
                        CGFloat currentPresetnationTimeInSeconds = CMTimeGetSeconds(currentSamplePTS);
                        
                        self.progress = currentPresetnationTimeInSeconds / assetDurationInSeconds;
                        
//                        NSLog(@"Sample Count %i", sampleCount);
                        
//                        CFStringRef desc = CMTimeRangeCopyDescription(kCFAllocatorDefault, currentSampleTimeRange);
//                        NSLog(@"Sample Timing Info: %@", desc);
                        
                        // Write Metadata
                        
                        // Check that our metadata times are sensible. We need to ensure that each time range is:
                        // a: incremented from the last
                        // b: valid
                        // c: has no zero duration (should be the duration of a frame)
                        // d: there are probably other issues too but this seems to work for now.
                        
                        // Disable tests for now because why not.
//                        if(CMTIMERANGE_IS_VALID(currentSampleTimeRange)
//                           && CMTIME_COMPARE_INLINE(currentSampleTimeRange.start, >=, lastSampleTimeRange.start)
//                           && CMTIME_COMPARE_INLINE(currentSampleTimeRange.duration, >, kCMTimeZero)
//                           )
                        {
//                            NSLog(@"Sample %i PASSED", sampleCount);
                            
                            // For every Analyzer we have:
                            // A: analyze
                            // B: aggregate the metadata dictionary into a global dictionary with our plugin identifier as the key for that entry
                            // C: Once done analysis, convert aggregate metadata to JSON and write out a metadata object and append it.
                            
                            NSError* analyzerError = nil;
                            NSMutableDictionary* aggregatedAndAnalyzedMetadata = [NSMutableDictionary new];
                            
                            for(id<AnalyzerPluginProtocol> analyzer in self.availableAnalyzers)
                            {
                                NSString* newMetadataKey = [analyzer pluginIdentifier];
                                NSDictionary* newMetadataValue = [analyzer analyzedMetadataDictionaryForSampleBuffer:uncompressedVideoSampleBuffer error:&analyzerError];
                                
                                if(analyzerError)
                                {
                                    NSString* errorString = [@"Error Analyzing Sample buffer - bailing: " stringByAppendingString:[analyzerError description]];
                                    [[LogController sharedLogController] appendErrorLog:errorString];
                                    break;
                                }

                                if(newMetadataValue)
                                    [aggregatedAndAnalyzedMetadata setObject:newMetadataValue forKey:newMetadataKey];
                            }
                            
                            // Convert to BSON // JSON
                            if([NSJSONSerialization isValidJSONObject:aggregatedAndAnalyzedMetadata])
//                            NSData* BSONData = [aggregatedAndAnalyzedMetadata BSONRepresentation];
//                            NSData* gzipData = [BSONData gzippedData];
//                            if(gzipData)
                            {
                                // TODO: Probably want to mark to NO for shipping code:
                                NSString* aggregateMetadataAsJSON = [aggregatedAndAnalyzedMetadata jsonStringWithPrettyPrint:NO];
                                NSData* jsonData = [aggregateMetadataAsJSON dataUsingEncoding:NSUTF8StringEncoding];
                                
                                NSData* gzipData = [jsonData gzippedData];
                                
                                // Annotation text item
                                AVMutableMetadataItem *textItem = [AVMutableMetadataItem metadataItem];
                                textItem.identifier = kSynopsislMetadataIdentifier;
                                textItem.dataType = (__bridge NSString *)kCMMetadataBaseDataType_RawData;
                                textItem.value = gzipData;
                                
                                AVTimedMetadataGroup *group = [[AVTimedMetadataGroup alloc] initWithItems:@[textItem] timeRange:currentSampleTimeRange];
                                
                                // Store out running metadata
                                [self.inFlightVideoSampleBufferMetadata addObject:group];
                            }
                            else
                            {
                                [[LogController sharedLogController] appendErrorLog:@"Unable To Convert Metadata to JSON Format, invalid object"];
                            }
                        }
//                        else
//                        {
//                            NSLog(@"Sample %i FAILED", sampleCount);
//                        }
                        
                        sampleCount++;
                        lastSampleTimeRange = currentSampleTimeRange;

                        CFRelease(uncompressedVideoSampleBuffer);
                    }
                    else
                    {
                        // Got NULL - were done
                        break;
                    }
                    
                }
            }

            finishedReadingAllUncompressedVideo = YES;

            [[LogController sharedLogController] appendSuccessLog:@"Finished Reading Uncompressed Video Buffers"];
            
            // Fire final semaphore signal to hit finalization
            dispatch_semaphore_signal(videoDequeueSemaphore);

            dispatch_group_leave(g);
        });
                       

        {
            [self.transcodeAssetWriterVideo requestMediaDataWhenReadyOnQueue:passthroughVideoEncodeQueue usingBlock:^
            {
                [[LogController sharedLogController] appendVerboseLog:@"Begun Writing Video"];

                while([self.transcodeAssetWriterVideo isReadyForMoreMediaData])
                {
                    // Are we done reading,
                    if(finishedReadingAllPassthroughVideo && finishedReadingAllUncompressedVideo)
                    {
                        NSLog(@"Finished Reading waiting to empty queue...");
                        dispatch_semaphore_signal(videoDequeueSemaphore);

                        if(CMBufferQueueIsEmpty(passthroughVideoBufferQueue) && CMBufferQueueIsEmpty(uncompressedVideoBufferQueue))
                        {
                            // TODO: AGGREGATE METADATA THAT ISNT PER FRAME
                            NSError* analyzerError = nil;
                            for(id<AnalyzerPluginProtocol> analyzer in self.availableAnalyzers)
                            {
                                NSDictionary* finalizedMetadata = [analyzer finalizeMetadataAnalysisSessionWithError:&analyzerError];
                                if(analyzerError)
                                {
                                    NSString* errorString = [@"Error Finalizing Analysis - bailing: " stringByAppendingString:[analyzerError description]];
                                    [[LogController sharedLogController] appendErrorLog:errorString];

                                    break;
                                }
                                
                                // set our global metadata for the analyzer
                                if(finalizedMetadata)
                                {
                                    self.inFlightGlobalMetadata[analyzer.pluginIdentifier] = finalizedMetadata;
                                }
                                else
                                {
                                    NSString* warning = [@"No Global Analysis Data for Analyzer %@ " stringByAppendingString:analyzer.pluginIdentifier];
                                    [[LogController sharedLogController] appendWarningLog:warning];
                                }
                            }
                        
                            [self.transcodeAssetWriterVideo markAsFinished];
                            
                            [[LogController sharedLogController] appendSuccessLog:@"Finished Writing Video"];

                            dispatch_group_leave(g);
                            break;
                        }
                    }
                    
                    CMSampleBufferRef videoSampleBuffer = NULL;

                    // wait to dequeue until we have a enqueued buffer signal from our enqueue thread.
                    dispatch_semaphore_wait(videoDequeueSemaphore, DISPATCH_TIME_FOREVER);

                    // Pull from an appropriate source - passthrough or decompressed
                    if(self.transcoding)
                    {
                        videoSampleBuffer = (CMSampleBufferRef) CMBufferQueueDequeueAndRetain(uncompressedVideoBufferQueue);
                    }
                    else
                    {
                        videoSampleBuffer = (CMSampleBufferRef) CMBufferQueueDequeueAndRetain(passthroughVideoBufferQueue);
                    }
                    
                    if(videoSampleBuffer)
                    {
                        //[[LogController sharedLogController] appendVerboseLog:@"Dequeueing and Writing Uncompressed Sample Buffer"];
                        if(![self.transcodeAssetWriterVideo appendSampleBuffer:videoSampleBuffer])
                        {
                            NSString* errorString = [@"Unable to append sampleBuffer: " stringByAppendingString:[self.transcodeAssetWriter.error description]];
                            [[LogController sharedLogController] appendErrorLog:errorString];
                        }
                        CFRelease(videoSampleBuffer);
                    }
                    
                }
                
//                NSLog(@"Stopped Requesting Media");
                
            }];
        }
        // Wait until every queue is finished processing
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        
        // re-enter g
        dispatch_group_enter(g);
        
        [self.transcodeAssetWriter finishWritingWithCompletionHandler:^{

            dispatch_group_leave(g);
            
        }];
        
        // Wait until every queue is finished processing
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);

        self.analyzedGlobalMetadata = self.inFlightGlobalMetadata;
        self.analyzedVideoSampleBufferMetadata = self.inFlightVideoSampleBufferMetadata;
        self.analyzedAudioSampleBufferMetadata = self.inFlightAudioSampleBufferMetadata;
        
        // reset / empty our buffer queues
        CMBufferQueueReset(passthroughVideoBufferQueue);
        CMBufferQueueReset(uncompressedVideoBufferQueue);
        
        [[LogController sharedLogController] appendSuccessLog:@"Finished Analysis Operation"];
    }
}


@end
