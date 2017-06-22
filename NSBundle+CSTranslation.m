//
//  NSBundle+NSBundle_CSTranslation.m
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

#import "NSBundle+CSTranslation.h"

#import "NSFileManager+DirectoryLocations.h"

#import <objc/runtime.h>

@interface NSBundle (CSTranslation_Private)
+ (void)_csLocalizeStringsInObject:(id)object table:(NSString *)table;
+ (NSString *)_csLocalizedStringForString:(NSString *)string table:(NSString *)table;
// localize particular attributes in objects
+ (void)_csLocalizeTitleOfObject:(id)object table:(NSString *)table;
+ (void)_csLocalizeAlternateTitleOfObject:(id)object table:(NSString *)table;
+ (void)_csLocalizeStringValueOfObject:(id)object table:(NSString *)table;
+ (void)_csLocalizePlaceholderStringOfObject:(id)object table:(NSString *)table;
+ (void)_csLocalizeToolTipOfObject:(id)object table:(NSString *)table;
+ (void)_csLocalizeLabelOfObject:(id)object table:(NSString *)table;

+ (NSBundle*) kamusiBundle;
@end

static NSArray *kamusiBindingKeys = nil;

@implementation NSBundle (CSTranslation)

#pragma mark NSObject

+ (void)load
{
    // swizzle methods
    method_exchangeImplementations(class_getInstanceMethod(self, @selector(loadNibNamed:owner:topLevelObjects:)), class_getInstanceMethod(self, @selector(kamusiLoadNibNamed:owner:topLevelObjects:)));
    method_exchangeImplementations(class_getInstanceMethod(self, @selector(localizedStringForKey:value:table:)), class_getInstanceMethod(self, @selector(kamusiLocalizedStringForKey:value:table:)));
    
    kamusiBindingKeys = [[NSArray alloc] initWithObjects:
                         NSMultipleValuesPlaceholderBindingOption,
                         NSNoSelectionPlaceholderBindingOption,
                         NSNotApplicablePlaceholderBindingOption,
                         NSNullPlaceholderBindingOption,
                         nil];
}

#pragma mark API

+ (NSBundle*) kamusiBundle
{
    NSString* preferredLanguage = [[[NSBundle mainBundle] preferredLocalizations] firstObject];
    
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"KamusiTranslations"];
    NSBundle* kamusiBundle = [NSBundle bundleWithPath:kamusiPath];
    
    NSArray<NSString*>* availableKamusiLanguageCodes = [kamusiBundle localizations];
    NSArray<NSString*>* preferredUserLocaleIdentifiers = [[NSUserDefaults standardUserDefaults] valueForKey:@"AppleLanguages"];
    
    for(NSString* aLocaleIdentifier in preferredUserLocaleIdentifiers)
    {
        NSLocale* aLocale = [NSLocale localeWithLocaleIdentifier:aLocaleIdentifier];
        
        if([availableKamusiLanguageCodes containsObject:aLocale.languageCode])
        {
            preferredLanguage = aLocale.languageCode;
            break;
        }
    }
    
    NSString* localizationPath = [kamusiBundle pathForResource:preferredLanguage ofType:@"lproj"];
    
    BOOL isDir = NO;
    if([[NSFileManager defaultManager] fileExistsAtPath:localizationPath isDirectory:&isDir] && isDir)
        return [NSBundle bundleWithPath:localizationPath];
    else
        return kamusiBundle;
}

- (NSString*)kamusiLocalizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName
{
    if (![key length])
        return [self kamusiLocalizedStringForKey:key value:value table:tableName];  // use default behavior
    
    // try with Transifex directory first
    NSString *localizedString = [[NSBundle kamusiBundle] kamusiLocalizedStringForKey:key value:value table:tableName];
    
    // backup: try with application's main bundle
    if(!localizedString || localizedString == value || localizedString == key)
        localizedString = [self kamusiLocalizedStringForKey:key value:value table:tableName];
    
    if (localizedString != value) {
        return localizedString;
    } else {
        return value;
    }
}

- (BOOL)kamusiLoadNibNamed:(NSString *)nibName owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects
{
    NSString* nibFileName = [[NSBundle mainBundle] pathForResource:nibName ofType:@"nib"];
    if(!nibFileName)
        return [self kamusiLoadNibNamed:nibName owner:owner topLevelObjects:topLevelObjects];   // original implementation

    NSString *localizedStringsTablePath_Bundle = [[NSBundle mainBundle] pathForResource:nibName ofType:@"strings"];
    
    NSString* kamusiPath = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"KamusiTranslations"];
    NSString *localizedStringsTablePath_Kamusi = [[NSBundle bundleWithPath:kamusiPath] pathForResource:nibName ofType:@"strings"];
    
    if ((localizedStringsTablePath_Bundle || localizedStringsTablePath_Kamusi) && topLevelObjects) {
        
        NSNib *nib = [[NSNib alloc] initWithNibNamed:nibName bundle:self];
        
        BOOL success = [nib instantiateWithOwner:owner topLevelObjects:topLevelObjects];
        [[self class] _csLocalizeStringsInObject:*topLevelObjects table:nibName];
        
        return success;
        
    } else {
        return [self kamusiLoadNibNamed:nibName owner:owner topLevelObjects:topLevelObjects];   // original implementation
    }
}

#pragma mark Private API

+ (void)_csLocalizeStringsInObject:(id)object table:(NSString *)table;
{
    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = object;
        
        for (id nibItem in array)
            [self _csLocalizeStringsInObject:nibItem table:table];
		
    } else if ([object isKindOfClass:[NSCell class]]) {
        NSCell *cell = object;
        
        if ([cell isKindOfClass:[NSActionCell class]]) {
            NSActionCell *actionCell = (NSActionCell *)cell;
            
            if ([actionCell isKindOfClass:[NSButtonCell class]]) {
                NSButtonCell *buttonCell = (NSButtonCell *)actionCell;
                if ([buttonCell imagePosition] != NSImageOnly) {
                    [self _csLocalizeTitleOfObject:buttonCell table:table];
                    [self _csLocalizeStringValueOfObject:buttonCell table:table];
                    [self _csLocalizeAlternateTitleOfObject:buttonCell table:table];
                }
            } else if ([actionCell isKindOfClass:[NSPathCell class]]) {
                NSPathCell *pathCell = (NSPathCell *)actionCell;
                [self _csLocalizePlaceholderStringOfObject:pathCell table:table];
            } else if ([actionCell isKindOfClass:[NSTokenFieldCell class]]) {
                // Don't localize the string value of token fields because
                // calling the setStringValue method because this causes custom
                // (= non-strings) token objects to be converted to strings.
                // You can see this because suddenly NSTokenFieldDelegate's
                // tokenField:representedObjectForEditingString: when launching
                // the app in a localized language, but not called for the
                // English version.
                NSTokenFieldCell *tokenFieldCell = (NSTokenFieldCell *)actionCell;
                [self _csLocalizePlaceholderStringOfObject:tokenFieldCell table:table];
            } else if ([actionCell isKindOfClass:[NSTextFieldCell class]]) {
                NSTextFieldCell *textFieldCell = (NSTextFieldCell *)actionCell;
                // Following line is redundant with other code, localizes twice.
                // [self _csLocalizeTitleOfObject:textFieldCell table:table];
                [self _csLocalizeStringValueOfObject:textFieldCell table:table];
                [self _csLocalizePlaceholderStringOfObject:textFieldCell table:table];
				
            } else if ([actionCell type] == NSTextCellType) {
                [self _csLocalizeTitleOfObject:actionCell table:table];
                [self _csLocalizeStringValueOfObject:actionCell table:table];
            }
        }
        
    } else if ([object isKindOfClass:[NSMenu class]]) {
        NSMenu *menu = object;
        [self _csLocalizeTitleOfObject:menu table:table];
        
        [self _csLocalizeStringsInObject:[menu itemArray] table:table];
        
    } else if ([object isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *menuItem = object;
        [self _csLocalizeTitleOfObject:menuItem table:table];
        [self _csLocalizeToolTipOfObject:menuItem table:table];
        
        [self _csLocalizeStringsInObject:[menuItem submenu] table:table];
        
    } else if ([object isKindOfClass:[NSView class]]) {
        NSView *view = object;
        [self _csLocalizeToolTipOfObject:view table:table];
		
        if ([view isKindOfClass:[NSBox class]]) {
            NSBox *box = (NSBox *)view;
            [self _csLocalizeTitleOfObject:box table:table];
            
        } else if ([view isKindOfClass:[NSControl class]]) {
            NSControl *control = (NSControl *)view;
			
			// Localize BINDINGS
			if ([view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSPathControl class]]) {
				NSTextField *textField = (NSTextField *)control;
				
				// A text field can have more than one display pattern binding (displayPatternValue1, ...) but according to the Apple
				// docs its sufficient to change the first one and the change will be rippled through to the other ones
				if ([[textField exposedBindings] containsObject:@"displayPatternValue1"]) {
					NSDictionary *displayPatternInfo = [textField infoForBinding:@"displayPatternValue1"];
					if (displayPatternInfo) {
						// First get the unlocalized display pattern string from the bindings info and localize it
						NSString *unlocalizedDisplayPattern = displayPatternInfo[NSOptionsKey][NSDisplayPatternBindingOption];
						NSString *localizedDisplayPattern = [self _csLocalizedStringForString:unlocalizedDisplayPattern table:table];
						
						// To actually update the display pattern we need to re-create the bindings
						NSMutableDictionary *localizedOptions = [displayPatternInfo[NSOptionsKey] mutableCopy];
						localizedOptions[NSDisplayPatternBindingOption] = localizedDisplayPattern;
						[textField bind:@"displayPatternValue1" toObject:displayPatternInfo[NSObservedObjectKey] withKeyPath:displayPatternInfo[NSObservedKeyPathKey] options:localizedOptions];
					}
				}
                
                NSDictionary *vb = nil;
                if ((vb = [textField infoForBinding:@"value"]))
                {
                    NSMutableDictionary *lvb = [NSMutableDictionary dictionaryWithDictionary:vb[NSOptionsKey]];
                    for (NSString *bindingKey in kamusiBindingKeys)
                    {
                        if (lvb[bindingKey] == [NSNull null] || ![lvb[bindingKey] isKindOfClass:[NSString class]])
                            continue;
                        
                        NSString *localizedBindingString = [self _csLocalizedStringForString:lvb[bindingKey] table:table];
                        if (localizedBindingString)
                            lvb[bindingKey] = localizedBindingString;
                    }
                    [textField bind:@"value" toObject:vb[NSObservedObjectKey] withKeyPath:vb[NSObservedKeyPathKey] options:lvb];
                }
			}
			
            if ([view isKindOfClass:[NSButton class]]) {
                NSButton *button = (NSButton *)control;
				
                if ([button isKindOfClass:[NSPopUpButton class]]) {
                    NSPopUpButton *popUpButton = (NSPopUpButton *)button;
                    NSMenu *menu = [popUpButton menu];
                    
                    [self _csLocalizeStringsInObject:[menu itemArray] table:table];
                } else
                    [self _csLocalizeStringsInObject:[button cell] table:table];
				
                
            } else if ([view isKindOfClass:[NSMatrix class]]) {
                NSMatrix *matrix = (NSMatrix *)control;
                
                NSArray *cells = [matrix cells];
                [self _csLocalizeStringsInObject:cells table:table];
                
                for (NSCell *cell in cells) {
                    
                    NSString *localizedCellToolTip = [self _csLocalizedStringForString:[matrix toolTipForCell:cell] table:table];
                    if (localizedCellToolTip)
                        [matrix setToolTip:localizedCellToolTip forCell:cell];
                }
                
            } else if ([view isKindOfClass:[NSSegmentedControl class]]) {
                NSSegmentedControl *segmentedControl = (NSSegmentedControl *)control;
                
                NSUInteger segmentIndex, segmentCount = [segmentedControl segmentCount];
                for (segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++) {
                    NSString *localizedSegmentLabel = [self _csLocalizedStringForString:[segmentedControl labelForSegment:segmentIndex] table:table];
                    if (localizedSegmentLabel)
                        [segmentedControl setLabel:localizedSegmentLabel forSegment:segmentIndex];
                    NSString *localizedSegmentTooltip = [self _csLocalizedStringForString:[[segmentedControl cell] toolTipForSegment:segmentIndex] table:table];
                    if (localizedSegmentTooltip)
                        [[segmentedControl cell] setToolTip:localizedSegmentTooltip forSegment:segmentIndex];
                    
                    [self _csLocalizeStringsInObject:[segmentedControl menuForSegment:segmentIndex] table:table];
                }
                
            } else if ([object isKindOfClass:[NSTableView class]]) {   // table and outline views
				NSTableView* tableView = (NSTableView*)view;
				for (NSTableColumn *column in [tableView tableColumns]) {
                    [self _csLocalizeStringValueOfObject:[column headerCell] table:table];
                    NSString *localizedHeaderTip = [self _csLocalizedStringForString:[column headerToolTip] table:table];
                    if (localizedHeaderTip) [column setHeaderToolTip:localizedHeaderTip];
                    // localize table cells
                    for(NSInteger i=0; i<tableView.numberOfColumns; i++)
                    {
                        for(NSInteger j=0; j<tableView.numberOfRows; j++)
                        {
                            NSCell* tableCell = [tableView preparedCellAtColumn:i row:j];
                            [self _csLocalizeStringsInObject:tableCell table:table];
                        }
                    }
                }
			}
			else
                [self _csLocalizeStringsInObject:[control cell] table:table];
			
        } else if ([object isKindOfClass:[NSTabView class]]) {
			NSTabView *tabView = object;
			[self _csLocalizeStringsInObject:[tabView tabViewItems] table:table];
		}
        
        if([view subviews])
            [self _csLocalizeStringsInObject:[view subviews] table:table];
        
    } else if ([object isKindOfClass:[NSWindow class]]) {
        NSWindow *window = object;
        [self _csLocalizeTitleOfObject:window table:table];
        
        [self _csLocalizeStringsInObject:[window contentView] table:table];
        
    } else if ([object isKindOfClass:[NSTabViewItem class]]) {
		NSTabViewItem *tabViewItem = object;
		[self _csLocalizeLabelOfObject:object table:table];
        [self _csLocalizeStringsInObject:[tabViewItem view] table:table];
    } else if ([object isKindOfClass:[NSTableColumn class]]) {
		NSTableColumn *tableColumn = object;
        [self _csLocalizeTitleOfObject:[tableColumn headerCell] table:table];
    }
}

+ (NSString *)_csLocalizedStringForString:(NSString *)string table:(NSString *)table;
{
    if (![string length])
        return nil;
	
    static NSString *defaultValue = @"I AM THE DEFAULT VALUE";
    
    // try with Transifex directory first
    NSString *localizedString = [[NSBundle kamusiBundle] localizedStringForKey:string value:defaultValue table:table];
    
    // backup: try with application's main bundle
    if(localizedString == defaultValue)
        localizedString = [[NSBundle mainBundle] localizedStringForKey:string value:defaultValue table:table];
    
    if (localizedString != defaultValue) {
        return localizedString;
    } else {
        return string;
    }
}


#define DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(blahName, capitalizedBlahName) \
+ (void)_csLocalize ##capitalizedBlahName ##OfObject:(id)object table:(NSString *)table; \
{ \
NSString *localizedBlah = [self _csLocalizedStringForString:[object blahName] table:table]; \
if (localizedBlah) \
[object set ##capitalizedBlahName:localizedBlah]; \
}

DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(title, Title)
DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(alternateTitle, AlternateTitle)
DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(stringValue, StringValue)
DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(placeholderString, PlaceholderString)
DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(toolTip, ToolTip)
DM_DEFINE_CSLOCALIZE_BLAH_OF_OBJECT(label, Label)

@end
