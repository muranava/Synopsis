//
//  OpenCVAnalyzerPlugin.h
//  MetadataTranscoderTestHarness
//
//  Created by vade on 4/3/15.
//  Copyright (c) 2015 Synopsis. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "AnalyzerPluginProtocol.h"

@interface StandardAnalyzerPlugin : NSObject <SampleBufferAnalyzerPluginProtocol>

@property (readonly) NSString* pluginName;
@property (readonly) NSString* pluginIdentifier;

@property (readonly) NSArray* pluginAuthors;
@property (readonly) NSString* pluginDescription;

@property (readonly) NSUInteger pluginAPIVersionMajor;
@property (readonly) NSUInteger pluginAPIVersionMinor;

@property (readonly) NSUInteger pluginVersionMajor;
@property (readonly) NSUInteger pluginVersionMinor;

@property (readonly) NSDictionary* pluginReturnedMetadataKeysAndDataTypes;

@property (readonly) NSString* pluginMediaType;

@property (readonly) NSArray* pluginModuleNames;

- (void) beginMetadataAnalysisSessionWithQuality:(SynopsisAnalysisQualityHint)qualityHint andEnabledModules:(NSDictionary*)enabledModuleKeys;

- (NSDictionary*) analyzedMetadataDictionaryForSampleBuffer:(CMSampleBufferRef)sampleBuffer error:(NSError**) error;

- (NSDictionary*) finalizeMetadataAnalysisSessionWithError:(NSError**)error;

@end
