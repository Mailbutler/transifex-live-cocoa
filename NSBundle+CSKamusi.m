//
//  NSBundle+CSKamusi.m
//  Kamusi
//
//  Created by Fabian Jäger on 17.08.12.
//  Copyright (c) 2015 Feingeist Software GmbH. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification,
//  are permitted provided that the following conditions are met:
//
//		Redistributions of source code must retain the above copyright notice, this
//	list of conditions and the following disclaimer.
//
//		Redistributions in binary form must reproduce the above copyright notice,
//	this list of conditions and the following disclaimer in the documentation and/or
//	other materials provided with the distribution.
//
//		Neither the name of Feingeist Software GmbH nor the names of its contributors
//	may be used to endorse or promote products derived from this software without
//	specific prior written permission.
//
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS AS IS AND
//	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
//	IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
//	INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
//	BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
//	OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//	ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//	POSSIBILITY OF SUCH DAMAGE.

#define TXClientVersionString @"0.11b3"

#import "NSBundle+CSKamusi.h"

#import "NSFileManager+DirectoryLocations.h"

static NSString * const CSKamusiMetadataFileName = @"Metadata.plist";
static NSString * const CSKamusiMetadataBundleIdentifierKey = @"BundleIdentifier";
static NSString * const CSKamusiMetadataBundleVersionKey = @"BundleVersion";
static NSString * const CSKamusiMetadataBundleShortVersionKey = @"BundleShortVersion";
static NSString * const CSKamusiTranslationsDirectoryName = @"KamusiTranslations";

@interface NSBundle (CSKamusi_PRIVATE)
+ (void) _pullTranslationsFromTransifex:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler;
+ (void) _pullTranslationsFromTransifexV3:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler;
+ (BOOL) _kamusiMetadataMatchesCurrentBundleAtPath:(NSString*)kamusiPath;
+ (NSDate*) _kamusiLanguageDirectoryModificationDateForLanguageCode:(NSString*)languageCode kamusiPath:(NSString*)kamusiPath;
+ (BOOL) _kamusiStoreTranslationData:(NSData*)translationData languageCode:(NSString*)languageCode languageIdentifier:(NSString*)languageIdentifier kamusiPath:(NSString*)kamusiPath;
+ (void) _kamusiPollDownloadStatusAtURL:(NSURL*)statusURL
                            bearerToken:(NSString*)bearerToken
                              attemptNo:(NSUInteger)attemptNo
                                  maxTry:(NSUInteger)maxTry
                          withCompletion:(void (^)(NSURL *downloadURL, NSError *error))completionHandler;
@end

@implementation NSBundle (CSKamusi)

+ (void) pullTranslationsFromTransifex:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler
{
    // check if we have a project + resource
    if(!(transifexDict[CSTransifexProject] && transifexDict[CSTransifexResource]))
    {
        NSLog(@"ERROR: You need to specify a project+resource for Transifex!");
        return;
    }

    BOOL hasV3Credentials = [transifexDict[CSTransifexAPIToken] length] > 0 && [transifexDict[CSTransifexOrganization] length] > 0;
    if(!hasV3Credentials)
    {
        NSLog(@"ERROR: You need to specify apiToken+organization for Transifex API v3.");
        return;
    }

    // the rest can be done in background
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_async(queue, ^{
        [self _pullTranslationsFromTransifex:transifexDict withCompletionHandler:completionHandler];
    });
}

#pragma mark Private Methods

+ (void) _pullTranslationsFromTransifex:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler
{
    __block BOOL installedNewTranslations = NO;
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:CSKamusiTranslationsDirectoryName];
    NSString* bundledKamusiPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:CSKamusiTranslationsDirectoryName];
    BOOL hasCompatibleInstalledTranslations = [self _kamusiMetadataMatchesCurrentBundleAtPath:kamusiPath];
    BOOL hasCompatibleBundledTranslations = [self _kamusiMetadataMatchesCurrentBundleAtPath:bundledKamusiPath];
    BOOL needsMetadataRecovery = !(hasCompatibleInstalledTranslations || hasCompatibleBundledTranslations);

    NSString *project = transifexDict[CSTransifexProject];
    NSString *resource = transifexDict[CSTransifexResource];
    NSString *organization = transifexDict[CSTransifexOrganization];
    NSString *bearerToken = transifexDict[CSTransifexAPIToken];

    NSString *projectIdentifier = [NSString stringWithFormat:@"o:%@:p:%@", organization, project];
    NSString *resourceIdentifier = [NSString stringWithFormat:@"o:%@:p:%@:r:%@", organization, project, resource];

    NSURLComponents *statsComponents = [NSURLComponents componentsWithString:@"https://rest.api.transifex.com/resource_language_stats"];
    statsComponents.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"filter[project]" value:projectIdentifier],
        [NSURLQueryItem queryItemWithName:@"filter[resource]" value:resourceIdentifier]
    ];

    NSMutableURLRequest *statsRequest = [NSMutableURLRequest requestWithURL:statsComponents.URL];
    [statsRequest setValue:[NSString stringWithFormat:@"%@ %@", @"Bearer", bearerToken] forHTTPHeaderField:@"Authorization"];
    [statsRequest setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:statsRequest completionHandler:^(NSData * _Nullable responseDataStatsOverview, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        if(error || !responseDataStatsOverview || ![httpResponse isKindOfClass:[NSHTTPURLResponse class]] || httpResponse.statusCode != 200)
        {
            NSInteger statusCode = [httpResponse isKindOfClass:[NSHTTPURLResponse class]] ? httpResponse.statusCode : 0;
            NSLog(@"Warning: Could not fetch Transifex language stats (resource=%@, status=%ld, error=%@)",
                  resourceIdentifier,
                  (long)statusCode,
                  error.localizedDescription ?: @"none");
            if(completionHandler)
                completionHandler(NO);
            return;
        }

        NSDictionary *statsPayload = [NSJSONSerialization JSONObjectWithData:responseDataStatsOverview options:kNilOptions error:nil];
        NSArray *statsData = [statsPayload[@"data"] isKindOfClass:[NSArray class]] ? statsPayload[@"data"] : nil;
        if(!statsData)
        {
            if(completionHandler)
                completionHandler(NO);
            return;
        }

        NSMutableDictionary<NSString*, NSDictionary*> *statsByLanguageIdentifier = [[NSMutableDictionary alloc] init];
        for(NSDictionary *entry in statsData)
        {
            NSString *languageID = entry[@"relationships"][@"language"][@"data"][@"id"];
            if(![languageID hasPrefix:@"l:"])
                continue;

            NSString *normalizedLanguageID = [[languageID substringFromIndex:2] lowercaseString];
            if([normalizedLanguageID length])
                statsByLanguageIdentifier[normalizedLanguageID] = entry;
        }

        NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];

        dispatch_group_t langDispatchGroup = dispatch_group_create();
        NSMutableSet* processedLanguageCodes = [[NSMutableSet alloc] init];

        for(NSString* localeIdentifier in [NSLocale preferredLanguages])
        {
            NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:localeIdentifier];
            NSString* languageCode = [locale.languageCode lowercaseString];
            if(![languageCode length] || [processedLanguageCodes containsObject:languageCode])
                continue;
            [processedLanguageCodes addObject:languageCode];

            NSMutableArray<NSString*>* candidateLanguageCodes = [[NSMutableArray alloc] init];
            NSString* normalizedLocaleIdentifier = [[localeIdentifier stringByReplacingOccurrencesOfString:@"-" withString:@"_"] lowercaseString];
            if([normalizedLocaleIdentifier length])
                [candidateLanguageCodes addObject:normalizedLocaleIdentifier];
            if(![candidateLanguageCodes containsObject:languageCode])
                [candidateLanguageCodes addObject:languageCode];

            NSDictionary *languageStats = nil;
            NSString *transifexLanguageIdentifier = nil;
            for(NSString *candidateLanguageCode in candidateLanguageCodes)
            {
                NSDictionary *candidateStats = statsByLanguageIdentifier[candidateLanguageCode];
                if([candidateStats isKindOfClass:[NSDictionary class]])
                {
                    languageStats = candidateStats;
                    transifexLanguageIdentifier = candidateStats[@"relationships"][@"language"][@"data"][@"id"];
                    break;
                }
            }

            if(!languageStats || ![transifexLanguageIdentifier hasPrefix:@"l:"])
                continue;

            NSDictionary *attributes = [languageStats[@"attributes"] isKindOfClass:[NSDictionary class]] ? languageStats[@"attributes"] : nil;
            if(!attributes)
                continue;

            double totalStrings = [attributes[@"total_strings"] respondsToSelector:@selector(doubleValue)] ? [attributes[@"total_strings"] doubleValue] : 0;
            double translatedStrings = [attributes[@"translated_strings"] respondsToSelector:@selector(doubleValue)] ? [attributes[@"translated_strings"] doubleValue] : 0;
            if(totalStrings <= 0 || ((translatedStrings / totalStrings) * 100.0) < 95.0)
                continue;

            NSDate* installedLangDate = hasCompatibleInstalledTranslations ? [self _kamusiLanguageDirectoryModificationDateForLanguageCode:languageCode kamusiPath:kamusiPath] : nil;
            NSDate* bundledLangDate = hasCompatibleBundledTranslations ? [self _kamusiLanguageDirectoryModificationDateForLanguageCode:languageCode kamusiPath:bundledKamusiPath] : nil;
            NSDate* activeLangDate = installedLangDate;
            if(bundledLangDate && (!activeLangDate || [bundledLangDate timeIntervalSinceDate:activeLangDate] > 0))
                activeLangDate = bundledLangDate;

            NSDate* lastUpdateDate = nil;
            NSString* lastUpdateDateString = attributes[@"last_update"];
            if([lastUpdateDateString isKindOfClass:[NSString class]])
                lastUpdateDate = [dateFormatter dateFromString:lastUpdateDateString];

            if(!needsMetadataRecovery && activeLangDate && (!lastUpdateDate || [lastUpdateDate timeIntervalSinceDate:activeLangDate] <= 0))
                continue;

            dispatch_group_enter(langDispatchGroup);

            NSDictionary *payload = @{
                @"data": @{
                    @"type": @"resource_translations_async_downloads",
                    @"attributes": @{
                        @"file_type": @"default",
                        @"mode": @"default"
                    },
                    @"relationships": @{
                        @"resource": @{
                            @"data": @{
                                @"type": @"resources",
                                @"id": resourceIdentifier
                            }
                        },
                        @"language": @{
                            @"data": @{
                                @"type": @"languages",
                                @"id": transifexLanguageIdentifier
                            }
                        }
                    }
                }
            };

            NSMutableURLRequest *downloadRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://rest.api.transifex.com/resource_translations_async_downloads"]];
            downloadRequest.HTTPMethod = @"POST";
            [downloadRequest setValue:[NSString stringWithFormat:@"%@ %@", @"Bearer", bearerToken] forHTTPHeaderField:@"Authorization"];
            [downloadRequest setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Accept"];
            [downloadRequest setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Content-Type"];
            downloadRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

            [[[NSURLSession sharedSession] dataTaskWithRequest:downloadRequest completionHandler:^(NSData * _Nullable responseData, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                NSHTTPURLResponse *createResponse = (NSHTTPURLResponse*)response;
                if(error || ![createResponse isKindOfClass:[NSHTTPURLResponse class]] || createResponse.statusCode != 202)
                {
                    dispatch_group_leave(langDispatchGroup);
                    return;
                }

                NSString *statusLocation = createResponse.allHeaderFields[@"Content-Location"];
                if(![statusLocation isKindOfClass:[NSString class]] || ![statusLocation length])
                {
                    dispatch_group_leave(langDispatchGroup);
                    return;
                }

                NSURL *statusURL = [NSURL URLWithString:statusLocation];
                if(!statusURL.scheme)
                    statusURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://rest.api.transifex.com%@", statusLocation]];
                if(!statusURL)
                {
                    dispatch_group_leave(langDispatchGroup);
                    return;
                }

                [self _kamusiPollDownloadStatusAtURL:statusURL bearerToken:bearerToken attemptNo:0 maxTry:20 withCompletion:^(NSURL *downloadURL, NSError *pollError) {
                    if(pollError || !downloadURL)
                    {
                        dispatch_group_leave(langDispatchGroup);
                        return;
                    }

                    [[[NSURLSession sharedSession] dataTaskWithURL:downloadURL completionHandler:^(NSData * _Nullable translationData, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                        if(!error && [translationData length] > 0)
                        {
                            BOOL stored = [self _kamusiStoreTranslationData:translationData languageCode:languageCode languageIdentifier:[transifexLanguageIdentifier substringFromIndex:2] kamusiPath:kamusiPath];
                            if(stored)
                            {
                                @synchronized(self) {
                                    installedNewTranslations = YES;
                                }
                            }
                        }
                        dispatch_group_leave(langDispatchGroup);
                    }] resume];
                }];
            }] resume];
        }

        dispatch_group_notify(langDispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if(completionHandler)
                completionHandler(installedNewTranslations);
        });
    }] resume];
}

+ (BOOL)_kamusiMetadataMatchesCurrentBundleAtPath:(NSString*)kamusiPath
{
    NSString *metadataPath = [kamusiPath stringByAppendingPathComponent:CSKamusiMetadataFileName];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if(![metadata isKindOfClass:[NSDictionary class]])
        return NO;

    NSDictionary *mainInfo = [[NSBundle mainBundle] infoDictionary] ?: @{};
    NSString *mainBundleIdentifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *mainBundleVersion = mainInfo[@"CFBundleVersion"] ?: @"";
    NSString *mainBundleShortVersion = mainInfo[@"CFBundleShortVersionString"] ?: @"";

    NSString *metadataBundleIdentifier = metadata[CSKamusiMetadataBundleIdentifierKey] ?: @"";
    NSString *metadataBundleVersion = metadata[CSKamusiMetadataBundleVersionKey] ?: @"";
    NSString *metadataBundleShortVersion = metadata[CSKamusiMetadataBundleShortVersionKey] ?: @"";

    if(![metadataBundleIdentifier length] || ![metadataBundleVersion length])
        return NO;

    if(![metadataBundleIdentifier isEqualToString:mainBundleIdentifier])
        return NO;

    if(![metadataBundleVersion isEqualToString:mainBundleVersion])
        return NO;

    if([metadataBundleShortVersion length] > 0 && ![metadataBundleShortVersion isEqualToString:mainBundleShortVersion])
        return NO;

    return YES;
}

+ (NSDate*) _kamusiLanguageDirectoryModificationDateForLanguageCode:(NSString*)languageCode kamusiPath:(NSString*)kamusiPath
{
    NSString* activeLangDir = [kamusiPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj", languageCode]];
    NSDictionary* activeAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:activeLangDir error:nil];
    if([[NSFileManager defaultManager] fileExistsAtPath:activeLangDir] && activeAttrs)
        return [activeAttrs fileModificationDate];

    return nil;
}

+ (void) _kamusiPollDownloadStatusAtURL:(NSURL*)statusURL
                            bearerToken:(NSString*)bearerToken
                              attemptNo:(NSUInteger)attemptNo
                                  maxTry:(NSUInteger)maxTry
                          withCompletion:(void (^)(NSURL *downloadURL, NSError *error))completionHandler
{
    NSMutableURLRequest *statusRequest = [NSMutableURLRequest requestWithURL:statusURL];
    [statusRequest setValue:[NSString stringWithFormat:@"%@ %@", @"Bearer", bearerToken] forHTTPHeaderField:@"Authorization"];
    [statusRequest setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:statusRequest completionHandler:^(NSData * _Nullable responseData, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse*)response;
        if(error || ![httpResponse isKindOfClass:[NSHTTPURLResponse class]])
        {
            if(completionHandler)
                completionHandler(nil, error);
            return;
        }

        if(httpResponse.statusCode == 303)
        {
            NSString *downloadLocation = httpResponse.allHeaderFields[@"Location"];
            NSURL *downloadURL = [downloadLocation isKindOfClass:[NSString class]] ? [NSURL URLWithString:downloadLocation] : nil;
            if(completionHandler)
                completionHandler(downloadURL, downloadURL ? nil : [NSError errorWithDomain:@"CSKamusi" code:303 userInfo:nil]);
            return;
        }

        if(httpResponse.statusCode != 200 || ![responseData length])
        {
            if(completionHandler)
                completionHandler(nil, [NSError errorWithDomain:@"CSKamusi" code:httpResponse.statusCode userInfo:nil]);
            return;
        }

        NSError *statusParseError = nil;
        NSDictionary *statusPayload = [NSJSONSerialization JSONObjectWithData:responseData options:kNilOptions error:&statusParseError];
        if(![statusPayload isKindOfClass:[NSDictionary class]])
        {
            // Some URLSession configurations follow the 303 automatically and return the final file URL/contents here.
            NSURL *finalURL = [response URL];
            if(finalURL && ![[finalURL absoluteString] isEqualToString:[statusURL absoluteString]])
            {
                if(completionHandler)
                    completionHandler(finalURL, nil);
                return;
            }

            if(completionHandler)
                completionHandler(nil, statusParseError ?: [NSError errorWithDomain:@"CSKamusi" code:-4 userInfo:nil]);
            return;
        }

        NSString *status = statusPayload[@"data"][@"attributes"][@"status"];
        if([status isEqualToString:@"failed"])
        {
            if(completionHandler)
                completionHandler(nil, [NSError errorWithDomain:@"CSKamusi" code:-2 userInfo:nil]);
            return;
        }

        if((!status || [status isEqualToString:@"pending"] || [status isEqualToString:@"processing"]) && attemptNo + 1 < maxTry)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self _kamusiPollDownloadStatusAtURL:statusURL bearerToken:bearerToken attemptNo:attemptNo + 1 maxTry:maxTry withCompletion:completionHandler];
            });
            return;
        }

        if(completionHandler)
            completionHandler(nil, [NSError errorWithDomain:@"CSKamusi" code:-3 userInfo:nil]);
    }] resume];
}

+ (BOOL) _kamusiStoreTranslationData:(NSData*)translationData languageCode:(NSString*)languageCode languageIdentifier:(NSString*)languageIdentifier kamusiPath:(NSString*)kamusiPath
{
    NSError *error = nil;
    NSXMLDocument* xmlDoc = [[NSXMLDocument alloc] initWithData:translationData options:0 error:&error];
    if(error != nil || !xmlDoc)
        return NO;

    BOOL installedAnyStrings = NO;
    NSArray* fileElements = [xmlDoc.rootElement nodesForXPath:@"//file" error:&error];
    if(error != nil)
        return NO;

    for(NSXMLElement* aFileElement in fileElements)
    {
        NSString* fileName = [[[[aFileElement attributeForName:@"original"] stringValue] lastPathComponent] stringByDeletingPathExtension];
        BOOL isSourceLang = [[[aFileElement attributeForName:@"source-language"] stringValue] isEqualToString:languageIdentifier];

        NSMutableString* strings = [NSMutableString stringWithCapacity:5000];
        NSXMLElement* bodyElement = [[aFileElement nodesForXPath:@"body" error:nil] firstObject];
        NSArray* translationItemList = [bodyElement nodesForXPath:@"trans-unit" error:nil];
        for(NSXMLElement* aTranslation in translationItemList)
        {
            NSString* transID = [[aTranslation attributeForName:@"id"] stringValue];
            if(!transID)
                continue;

            NSXMLElement* targetItem = [[aTranslation nodesForXPath:@"target" error:nil] firstObject];
            if(isSourceLang && targetItem == nil)
                targetItem = [[aTranslation nodesForXPath:@"source" error:nil] firstObject];

            NSString* translationString = [targetItem stringValue];
            if(!translationString)
                continue;

            NSString *escapedTranslationString = [[translationString stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                                  stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            escapedTranslationString = [escapedTranslationString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
            NSString* translationLine = [NSString stringWithFormat:@"\"%@\" = \"%@\";\n", transID, escapedTranslationString];
            [strings appendString:translationLine];
        }

        NSString* tempLangDir = [kamusiPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj_new", languageCode]];
        BOOL isDir = NO;
        if(!([[NSFileManager defaultManager] fileExistsAtPath:tempLangDir isDirectory:&isDir] && isDir))
            [[NSFileManager defaultManager] createDirectoryAtPath:tempLangDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString* stringFileName = [fileName stringByAppendingPathExtension:@"strings"];
        NSString* stringFilePath = [tempLangDir stringByAppendingPathComponent:stringFileName];

        if([[NSFileManager defaultManager] fileExistsAtPath:stringFilePath])
            [[NSFileManager defaultManager] removeItemAtPath:stringFilePath error:nil];

        if([strings length] > 20)
            installedAnyStrings |= [strings writeToFile:stringFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    return installedAnyStrings;
}

+ (BOOL) installTranslations
{
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:CSKamusiTranslationsDirectoryName];

    NSError* error;
    BOOL installed = NO;

    NSArray *langDirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kamusiPath error:&error];
    NSArray *tempLangDirs = [langDirs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.lproj_new'"]];

    for(NSString* tempLangDirName in tempLangDirs)
    {
        NSString* activeLangDir = [kamusiPath stringByAppendingPathComponent:[tempLangDirName stringByReplacingOccurrencesOfString:@"lproj_new" withString:@"lproj"]];

        NSDate* activeLangDate;
        NSDictionary* activeAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:activeLangDir error:nil];
        if([[NSFileManager defaultManager] fileExistsAtPath:activeLangDir] && activeAttrs)
            activeLangDate = [activeAttrs fileModificationDate];

        NSString* tempLangDir = [kamusiPath stringByAppendingPathComponent:tempLangDirName];

        NSDate* tempLangDate;
        NSDictionary* tempAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tempLangDir error:nil];
        if([[NSFileManager defaultManager] fileExistsAtPath:tempLangDir] && tempAttrs)
            tempLangDate = [tempAttrs fileModificationDate];

        if([tempLangDate timeIntervalSinceDate:activeLangDate] <= 0)
            continue;

        if([[NSFileManager defaultManager] fileExistsAtPath:activeLangDir])
            [[NSFileManager defaultManager] removeItemAtPath:activeLangDir error:nil];

        [[NSFileManager defaultManager] moveItemAtPath:tempLangDir toPath:activeLangDir error:&error];

        if(!error) {
            installed = YES;
        } else {
            NSLog(@"Error: Could not install new language - %@", error);
        }
    }

    if (installed)
    {
        NSDictionary *mainInfo = [[NSBundle mainBundle] infoDictionary] ?: @{};
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *bundleVersion = mainInfo[@"CFBundleVersion"] ?: @"";
        NSString *bundleShortVersion = mainInfo[@"CFBundleShortVersionString"] ?: @"";

        NSDictionary *metadata = @{
            CSKamusiMetadataBundleIdentifierKey: bundleIdentifier,
            CSKamusiMetadataBundleVersionKey: bundleVersion,
            CSKamusiMetadataBundleShortVersionKey: bundleShortVersion
        };

        NSString *metadataPath = [kamusiPath stringByAppendingPathComponent:CSKamusiMetadataFileName];
        if (![metadata writeToFile:metadataPath atomically:YES])
        {
            NSLog(@"Warning: Could not write Kamusi translation metadata file to %@", metadataPath);
        }
    }

    return installed;
}

@end
