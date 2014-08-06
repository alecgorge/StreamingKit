/**********************************************************************************
 AudioPlayer.m
 
 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/audjustable
 
 Copyright (c) 2012 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by Thong Nguyen (tumtumtum@gmail.com)
 4. Neither the name of Thong Nguyen nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY Thong Nguyen ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THONG NGUYEN BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **********************************************************************************/

#import "STKHTTPDataSource.h"
#import "STKLocalFileDataSource.h"

static NSString *userAgent = nil;

@interface STKHTTPDataSource()
{
@private
    UInt32 httpStatusCode;
    
    NSInteger shoutcastMetadataInterval;
    NSInteger shoutcastMetadataBytesRead;
    
    char *metadataHeader;
    NSInteger metadataLength;
    NSInteger metadataHeaderIndex;
    
    SInt64 seekStart;
    SInt64 relativePosition;
    SInt64 fileLength;
    int discontinuous;
	int requestSerialNumber;

    NSURL* currentUrl;
    STKAsyncURLProvider asyncUrlProvider;
    NSDictionary* httpHeaders;
    AudioFileTypeID audioFileTypeHint;
}
-(void) open;

@end

@implementation STKHTTPDataSource

+ (void)setDefaultUserAgent:(NSString *)str
{
	userAgent = str;
}

-(id) initWithURL:(NSURL*)urlIn
{
    return [self initWithURLProvider:^NSURL* { return urlIn; }];
}

-(id) initWithURLProvider:(STKURLProvider)urlProviderIn
{
	urlProviderIn = [urlProviderIn copy];
    
    return [self initWithAsyncURLProvider:^(STKHTTPDataSource* dataSource, BOOL forSeek, STKURLBlock block)
    {
        block(urlProviderIn());
    }];
}

-(id) initWithAsyncURLProvider:(STKAsyncURLProvider)asyncUrlProviderIn
{
    if (self = [super init])
    {
        seekStart = 0;
        relativePosition = 0;
        fileLength = -1;
        
        self->asyncUrlProvider = [asyncUrlProviderIn copy];
        
        audioFileTypeHint = [STKLocalFileDataSource audioFileTypeHintFromFileExtension:self->currentUrl.pathExtension];
    }
    
    return self;
}

-(void) dealloc
{
    free(metadataHeader);
}

-(NSURL*) url
{
    return self->currentUrl;
}

+(AudioFileTypeID) audioFileTypeHintFromMimeType:(NSString*)mimeType
{
    static dispatch_once_t onceToken;
    static NSDictionary* fileTypesByMimeType;
    
    dispatch_once(&onceToken, ^
    {
        fileTypesByMimeType =
        @{
            @"audio/mp3": @(kAudioFileMP3Type),
            @"audio/mpg": @(kAudioFileMP3Type),
            @"audio/mpeg": @(kAudioFileMP3Type),
            @"audio/wav": @(kAudioFileWAVEType),
            @"audio/aifc": @(kAudioFileAIFCType),
            @"audio/aiff": @(kAudioFileAIFFType),
            @"audio/x-m4a": @(kAudioFileM4AType),
            @"audio/x-mp4": @(kAudioFileMPEG4Type),
            @"audio/aacp": @(kAudioFileAAC_ADTSType),
            @"audio/m4a": @(kAudioFileM4AType),
            @"audio/mp4": @(kAudioFileMPEG4Type),
            @"audio/caf": @(kAudioFileCAFType),
            @"audio/aac": @(kAudioFileAAC_ADTSType),
            @"audio/ac3": @(kAudioFileAC3Type),
            @"audio/3gp": @(kAudioFile3GPType)
        };
    });
    
    NSNumber* number = [fileTypesByMimeType objectForKey:mimeType];
    
    if (!number)
    {
        return 0;
    }
    
    return (AudioFileTypeID)number.intValue;
}

-(AudioFileTypeID) audioFileTypeHint
{
    return audioFileTypeHint;
}

-(void) dataAvailable
{
    if (stream == NULL) {
        return;
    }
    
	if (self.httpStatusCode == 0)
	{
        CFTypeRef response = CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
        
        NSString *statusLine = (__bridge NSString *)CFHTTPMessageCopyResponseStatusLine(response);
        
        // if the status line is empty, the response was wonky--"ICY 200 OK" kinda wonky perhaps!
        if(statusLine.length == 0)
        {
            static NSInteger httpConnectionBufferSize = 1024;
            static char *http = "HTTP/1.1 200 OK";
            static NSInteger icy200OkLength = 10;
     
            /* If the response has the "ICY 200 OK" string,
             * we are dealing with the ShoutCast protocol.
             * The HTTP headers won't be available.
             */
            UInt8 *httpReadBuffer = malloc(sizeof(UInt8) * httpConnectionBufferSize);
            CFIndex bytesRead = CFReadStreamRead(stream, httpReadBuffer, httpConnectionBufferSize);
            if (bytesRead >= 10 &&
                httpReadBuffer[0] == 0x49 && httpReadBuffer[1] == 0x43 && httpReadBuffer[2] == 0x59 &&
                httpReadBuffer[3] == 0x20 && httpReadBuffer[4] == 0x32 && httpReadBuffer[5] == 0x30 &&
                httpReadBuffer[6] == 0x30 && httpReadBuffer[7] == 0x20 && httpReadBuffer[8] == 0x4F &&
                httpReadBuffer[9] == 0x4B)
            {
                _isShoutCastStream = YES;
                
                response = CFHTTPMessageCreateEmpty(NULL, false);
                
                // +5 is needed because HTTP/1.1 is 5 chars longer than ICY
                UInt8 *headerCopyBuffer = malloc(sizeof(UInt8) * (httpConnectionBufferSize + 5));
                
                // append the correct HTTP status line
                memcpy(headerCopyBuffer, http, strlen(http));
                
                // append the rest of the SHOUTcast quasi-HTTP response for processing (content-type, etc)
                memcpy(headerCopyBuffer + (sizeof(UInt8) * strlen(http)), httpReadBuffer + (sizeof(UInt8) * icy200OkLength), bytesRead - 10);
                
                if(!CFHTTPMessageAppendBytes(response, headerCopyBuffer, bytesRead + 5)) {
                    NSLog(@"failed to append SHOUTcast headers to HTTP response");
                }
                
                // find the postion of the CRLFCRLF so properly track read bytes for metadata purposes
                // by not including the header in the bytes read
                for (NSInteger i = 3; i < bytesRead; i++) {
                    if(httpReadBuffer[i - 3] == '\r' && httpReadBuffer[i - 2] == '\n' &&
                       httpReadBuffer[i - 1] == '\r' && httpReadBuffer[i - 0] == '\n') {
                        shoutcastMetadataBytesRead = bytesRead - (i + 1);
                    }
                }
                
                free(headerCopyBuffer);
            }
            
            free(httpReadBuffer);
        }
        
        if (response)
        {
            httpHeaders = (__bridge_transfer NSDictionary*)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)response);
            
            self->httpStatusCode = (UInt32)CFHTTPMessageGetResponseStatusCode((CFHTTPMessageRef)response);
            
            CFRelease(response);
        }
		
		if (self.httpStatusCode == 200)
		{
			if (seekStart == 0)
			{
				fileLength = (SInt64)[[httpHeaders objectForKey:@"Content-Length"] longLongValue];
			}
			
			NSString* contentType = [httpHeaders objectForKey:@"Content-Type"];
			AudioFileTypeID typeIdFromMimeType = [STKHTTPDataSource audioFileTypeHintFromMimeType:contentType];
			
			if (typeIdFromMimeType != 0)
			{
				audioFileTypeHint = typeIdFromMimeType;
			}
            
            if(self.isShoutCastStream) {
                NSString *metadataInterval = httpHeaders[@"icy-metaint"];
                shoutcastMetadataInterval = metadataInterval.integerValue;
                
                NSMutableDictionary *dict = NSMutableDictionary.dictionary;
                for (NSString *key in @[@"notice1", @"notice2", @"name", @"genre", @"url", @"pub", @"br"]) {
                    dict[key] = httpHeaders[[@"icy-" stringByAppendingString:key]];
                }
                
                [self willChangeValueForKey:@"shoutCastStationMetadata"];
                _shoutCastStationMetadata = dict;
                [self didChangeValueForKey:@"shoutCastStationMetadata"];
            }
		}
		else if (self.httpStatusCode == 206)
		{
			NSString* contentRange = [httpHeaders objectForKey:@"Content-Range"];
			NSArray* components = [contentRange componentsSeparatedByString:@"/"];
			
			if (components.count == 2)
			{
				fileLength = [[components objectAtIndex:1] integerValue];
			}
		}
		else if (self.httpStatusCode == 416)
		{
			if (self.length >= 0)
			{
				seekStart = self.length;
			}
			
			[self eof];
			
			return;
		}
		else if (self.httpStatusCode >= 300)
		{
			[self errorOccured];
			
			return;
		}
	}
	
	[super dataAvailable];
}

-(SInt64) position
{
    return seekStart + relativePosition;
}

-(SInt64) length
{
    return fileLength >= 0 ? fileLength : 0;
}

-(void) reconnect
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    [self seekToOffset:self.position];
}

-(void) seekToOffset:(SInt64)offset
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    NSAssert([NSRunLoop currentRunLoop] == eventsRunLoop, @"Seek called on wrong thread");
    
    stream = 0;
    relativePosition = 0;
    seekStart = offset;
    
    self->isInErrorState = NO;
    
    [self openForSeek:YES];
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (size == 0)
    {
        return 0;
    }
    
    int read = 0;
    if(!self.isShoutCastStream) {
        read = (int)CFReadStreamRead(stream, buffer, size);
    }
    else {
        UInt8 *swap = malloc(sizeof(UInt8) * size);
        read = (int)CFReadStreamRead(stream, swap, size);
        
        if (read < 0)
        {
            return read;
        }

        if(metadataHeader == NULL) {
            metadataHeader = malloc(sizeof(char) * 1024);
        }
        
        NSInteger bufferIndex = 0;
        for(int i = 0; i < read; i++) {
            if(metadataLength != 0) {
                metadataHeader[metadataHeaderIndex++] = swap[i];
                metadataLength--;
                
                if(metadataLength == 0) {
                    metadataHeader[metadataHeaderIndex++] = '\0';
                    metadataHeaderIndex = 0;
                    
                    NSString *meta = [NSString stringWithUTF8String:metadataHeader];
                    NSString *title = @"";
                    
                    NSArray *comps = [meta componentsSeparatedByString:@";"];
                    for (NSString *comp in comps) {
                        NSArray *subcomps = [comp componentsSeparatedByString:@"="];
                        if (subcomps.count >= 2 && [subcomps[0] isEqualToString:@"StreamTitle"]) {
                            title = [subcomps[1] substringWithRange:NSMakeRange(1, [subcomps[1] length] - 2)];
                            break;
                        }
                    }
                    
                    if (title != nil) {
                        [self willChangeValueForKey:@"shoutCastSongMetadata"];
                        _shoutCastSongMetadata = @{kSTKShoutcastSongMetadataTitleKey: title};
                        [self didChangeValueForKey:@"shoutCastSongMetadata"];
                    }
                }
            }
            else {
                if(shoutcastMetadataBytesRead++ < shoutcastMetadataInterval) {
                    buffer[bufferIndex++] = swap[i];
                }
                else {
                    metadataLength = swap[i] * 16;
                    shoutcastMetadataBytesRead = 0;
                }
            }
        }
        
        read = bufferIndex;
    }
    
    if (read < 0)
    {
        return read;
    }
    
    relativePosition += read;
    
    return read;
}

-(void) open
{
    return [self openForSeek:NO];
}

-(void) openForSeek:(BOOL)forSeek
{
	int localRequestSerialNumber;
	
	requestSerialNumber++;
	localRequestSerialNumber = requestSerialNumber;
	
    asyncUrlProvider(self, forSeek, ^(NSURL* url)
    {
		if (localRequestSerialNumber != self->requestSerialNumber)
		{
			return;
		}
		
        self->currentUrl = url;

        if (url == nil)
        {
            return;
        }

        CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)self->currentUrl, kCFHTTPVersion1_1);
        
        // Make sure no metadata is sent to screw up the stream
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Icy-MetaData"), CFSTR("1"));
				
		if(userAgent) {
			CFHTTPMessageSetHeaderFieldValue(message, CFSTR("User-Agent"), (__bridge CFStringRef)userAgent);
		}
        
        if (seekStart > 0)
        {
            CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"), (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%lld-", seekStart]);

            discontinuous = YES;
        }

        stream = CFReadStreamCreateForHTTPRequest(NULL, message);
        
        if (stream == nil)
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }

        if (!CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue))
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }

        // Proxy support

        CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
        CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
        CFRelease(proxySettings);

        // SSL support

        if ([self->currentUrl.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)
        {
            NSDictionary* sslSettings = [NSDictionary dictionaryWithObjectsAndKeys:
            (NSString*)kCFStreamSocketSecurityLevelNegotiatedSSL, kCFStreamSSLLevel,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredCertificates,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredRoots,
            [NSNumber numberWithBool:YES], kCFStreamSSLAllowsAnyRoot,
            [NSNumber numberWithBool:NO], kCFStreamSSLValidatesCertificateChain,
            [NSNull null], kCFStreamSSLPeerName,
            nil];

            CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings, (__bridge CFTypeRef)sslSettings);
        }

        [self reregisterForEvents];
        
		self->httpStatusCode = 0;
		
        // Open

        if (!CFReadStreamOpen(stream))
        {
            CFRelease(stream);
            CFRelease(message);
            
            stream = 0;

            [self errorOccured];

            return;
        }
        
        self->isInErrorState = NO;
        
        CFRelease(message);
    });
}

-(UInt32) httpStatusCode
{
    return self->httpStatusCode;
}

-(NSRunLoop*) eventsRunLoop
{
    return self->eventsRunLoop;
}

-(NSString*) description
{
    return [NSString stringWithFormat:@"HTTP data source with file length: %lld and position: %lld", self.length, self.position];
}

@end
