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

@interface NSBundle (CSKamusi_PRIVATE)
+ (void) _pullTranslationsFromTransifex:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler;
@end

@implementation NSBundle (CSKamusi)

+ (void) pullTranslationsFromTransifex:(NSDictionary*)transifexDict withCompletionHandler:(void (^)(BOOL success))completionHandler
{    
    // check if we have a username + password
    if(!(transifexDict[CSTransifexUsername] && transifexDict[CSTransifexPassword]))
    {
        NSLog(@"ERROR: You need to specify a username+password for Transifex!");
        return;
    }
    
    // check if we have a project + resource
    if(!(transifexDict[CSTransifexProject] && transifexDict[CSTransifexResource]))
    {
        NSLog(@"ERROR: You need to specify a project+resource for Transifex!");
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
    
    // define some variables, e.g. paths
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"KamusiTranslations"];
    
    // pull translations for user languages
    dispatch_group_t langDispatchGroup = dispatch_group_create();
    for(NSString* localeIdentifier in [NSLocale preferredLanguages])
    {
        NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:localeIdentifier];
        NSString* languageCode = locale.languageCode;
        
        NSString* activeLangDir = [kamusiPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj", languageCode]];
        
        NSDate* activeLangDate;
        
        NSError* fileError;
        NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:activeLangDir error:&fileError];
        if([[NSFileManager defaultManager] fileExistsAtPath:activeLangDir] && attrs && !fileError)
        {
            activeLangDate = [attrs fileModificationDate];
        }
        
        NSString* authStr = [NSString stringWithFormat:@"%@:%@", transifexDict[CSTransifexUsername], transifexDict[CSTransifexPassword]];
        NSData* authData = [authStr dataUsingEncoding:NSUTF8StringEncoding];
        NSString* authValue = [NSString stringWithFormat:@"Basic %@", [authData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed]];
        
        // first check if we have enough coverage and if language was updated
        NSString* urlStringStats = [NSString stringWithFormat:@"https://www.transifex.com/api/2/project/%@/resource/%@/stats/%@/", transifexDict[CSTransifexProject], transifexDict[CSTransifexResource], languageCode];
        
        NSMutableURLRequest* requestStats = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStringStats]];
        [requestStats setValue:authValue forHTTPHeaderField:@"Authorization"];
        
        dispatch_group_enter(langDispatchGroup);
        [[[NSURLSession sharedSession] dataTaskWithRequest:requestStats completionHandler:^(NSData * _Nullable responseDataStats, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            
            if(!error && response && responseDataStats && [response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse*)response statusCode] == 200)
            {
                NSUInteger coverage = 0;
                NSDate* lastUpdateDate;
                if(responseDataStats)
                {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseDataStats options:kNilOptions error:nil];
                    coverage = [[json[@"completed"] stringByReplacingOccurrencesOfString:@"%" withString:@""] integerValue];
                    
                    NSString* lastUpdateDateString = json[@"last_update"];
                    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
                    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
                    
                    lastUpdateDate = [dateFormatter dateFromString:lastUpdateDateString];
                }
                
                if(coverage < 95)
                {
                    // this language is not sufficiently translated, don't use it!
                    dispatch_group_leave(langDispatchGroup);
                    return;
                }
                
                if(activeLangDate && [lastUpdateDate timeIntervalSinceDate:activeLangDate] <= 0)
                {
                    // localization is up-to-date or no update date available
                    dispatch_group_leave(langDispatchGroup);
                    return;
                }
                
                // now download file
                NSString* urlStringFile = [NSString stringWithFormat:@"https://www.transifex.com/api/2/project/%@/resource/%@/translation/%@/?mode=default&file", transifexDict[CSTransifexProject], transifexDict[CSTransifexResource], languageCode];
                NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStringFile]];
                [request setValue:authValue forHTTPHeaderField:@"Authorization"];
                
                [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable responseDataFile, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                    
                    if(error == nil && [responseDataFile length])
                    {
                        NSXMLDocument* xmlDoc = [[NSXMLDocument alloc] initWithData:responseDataFile options:0 error:&error];
                        
                        if(error == nil)
                        {
                            NSArray* fileElements = [xmlDoc.rootElement nodesForXPath:@"//file" error:&error];
                            for(NSXMLElement* aFileElement in fileElements)
                            {
                                NSString* fileName = [[[[aFileElement attributeForName:@"original"] stringValue] lastPathComponent] stringByDeletingPathExtension];
                                BOOL isSourceLang = [[[aFileElement attributeForName:@"source-language"] stringValue] isEqualToString:languageCode];
                                
                                // get translated strings
                                NSMutableString* strings = [NSMutableString stringWithCapacity:5000];
                                
                                NSXMLElement* bodyElement = [[aFileElement nodesForXPath:@"body" error:nil] firstObject];
                                NSArray* translationItemList = [bodyElement nodesForXPath:@"trans-unit" error:nil];
                                for(NSXMLElement* aTranslation in translationItemList)
                                {
                                    NSString* transID = [[aTranslation attributeForName:@"id"] stringValue];
                                    
                                    if(!transID)
                                        continue;
                                    
                                    NSXMLElement* targetItem = [[aTranslation nodesForXPath:@"target" error:nil] firstObject];
                                    
                                    // if source language, use source string instead
                                    if(isSourceLang && targetItem == nil)
                                        targetItem = [[aTranslation nodesForXPath:@"source" error:nil] firstObject];
                                    
                                    NSString* translationString = [targetItem stringValue];
                                    
                                    if(!translationString)
                                        continue;
                                    
                                    NSString* translationLine = [NSString stringWithFormat:@"\"%@\" = \"%@\";\n", transID, translationString];
                                    
                                    [strings appendString:translationLine];
                                }
                                
                                // write strings file to temporary directory
                                NSString* tempLangDir = [kamusiPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj_new", languageCode]];
                                
                                BOOL isDir = NO;
                                if(!([[NSFileManager defaultManager] fileExistsAtPath:tempLangDir isDirectory:&isDir] && isDir))
                                    [[NSFileManager defaultManager] createDirectoryAtPath:tempLangDir withIntermediateDirectories:YES attributes:nil error:nil];
                                
                                NSString* stringFileName = [fileName stringByAppendingPathExtension:@"strings"];
                                NSString* stringFilePath = [tempLangDir stringByAppendingPathComponent:stringFileName];
                                
                                if([[NSFileManager defaultManager] fileExistsAtPath:stringFilePath])
                                    [[NSFileManager defaultManager] removeItemAtPath:stringFilePath error:nil];
                                
                                if([strings length] > 20)
                                    installedNewTranslations |= [strings writeToFile:stringFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                            }
                        }
                    }
                    
                    dispatch_group_leave(langDispatchGroup);
                    
                }] resume];
                
            }
            else
            {
                dispatch_group_leave(langDispatchGroup);
            }
        }] resume];
        
    }
    
    dispatch_group_notify(langDispatchGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        if(completionHandler)
            completionHandler(installedNewTranslations);
    });
    
}

+ (BOOL) installTranslations
{
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"KamusiTranslations"];
    
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
    
    return installed;
}

@end
