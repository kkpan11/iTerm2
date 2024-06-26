// -*- mode:objc -*-
/*
 **  PasteboardHistory.m
 **
 **  Copyright 2010
 **
 **  Author: George Nachman
 **
 **  Project: iTerm2
 **
 **  Description: Remembers pasteboard contents and offers a UI to access old
 **  entries.
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#include <wctype.h>
#import "DebugLogging.h"
#import "PasteboardHistory.h"
#import "NSDateFormatterExtras.h"
#import "NSStringITerm.h"
#import "PopupModel.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermController.h"
#import "iTermPreferences.h"
#import "iTermSecureKeyboardEntryController.h"

#define PBHKEY_ENTRIES @"Entries"
#define PBHKEY_VALUE @"Value"
#define PBHKEY_TIMESTAMP @"Timestamp"

@implementation PasteboardEntry

+ (PasteboardEntry*)entryWithString:(NSString *)s score:(double)score
{
    PasteboardEntry *e = [[PasteboardEntry alloc] init];
    [e setMainValue:s];
    [e setScore:score];
    [e setPrefix:@""];
    return e;
}

@end

@implementation PasteboardHistory {
    NSMutableArray *entries_;
    int maxEntries_;
    NSString *path_;
}

+ (int)maxEntries
{
    return [iTermAdvancedSettingsModel pasteHistoryMaxOptions];
}

+ (PasteboardHistory*)sharedInstance {
    static PasteboardHistory *instance;
    if (!instance) {
        int maxEntries = [PasteboardHistory maxEntries];
        // MaxPasteHistoryEntries is a legacy thing. I'm not removing it because it's a security
        // issue for some people.
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"MaxPasteHistoryEntries"]) {
            maxEntries = [[NSUserDefaults standardUserDefaults] integerForKey:@"MaxPasteHistoryEntries"];
            if (maxEntries < 0) {
                maxEntries = 0;
            }
        }
        instance = [[PasteboardHistory alloc] initWithMaxEntries:maxEntries];
    }
    return instance;
}

- (instancetype)initWithMaxEntries:(int)maxEntries {
    self = [super init];
    if (self) {
        maxEntries_ = maxEntries;
        entries_ = [[NSMutableArray alloc] init];


        path_ = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
        NSString *appname = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
        path_ = [path_ stringByAppendingPathComponent:appname];
        [[NSFileManager defaultManager] createDirectoryAtPath:path_ withIntermediateDirectories:YES attributes:nil error:NULL];
        path_ = [[path_ stringByAppendingPathComponent:@"pbhistory.plist"] copy];

        [self _loadHistoryFromDisk];
    }
    return self;
}

- (NSArray*)entries {
    return entries_;
}

- (NSDictionary*)_entriesToDict {
    NSMutableArray *a = [NSMutableArray array];

    for (PasteboardEntry *entry in entries_) {
        [a addObject:[NSDictionary dictionaryWithObjectsAndKeys:[entry mainValue], PBHKEY_VALUE,
                      [NSNumber numberWithDouble:[entry.timestamp timeIntervalSinceReferenceDate]], PBHKEY_TIMESTAMP,
                      nil]];
    }
    return [NSDictionary dictionaryWithObject:a forKey:PBHKEY_ENTRIES];
}

- (void)_addDictToEntries:(NSDictionary*)dict {
    NSArray *a = [dict objectForKey:PBHKEY_ENTRIES];
    for (NSDictionary *d in a) {
        double timestamp = [[d objectForKey:PBHKEY_TIMESTAMP] doubleValue];
        PasteboardEntry *entry = [PasteboardEntry entryWithString:[d objectForKey:PBHKEY_VALUE] score:timestamp];
        entry.timestamp = [NSDate dateWithTimeIntervalSinceReferenceDate:timestamp];
        [entries_ addObject:entry];
    }
}

- (void)clear {
    [entries_ removeAllObjects];
}

- (void)eraseHistory {
    [[NSFileManager defaultManager] removeItemAtPath:path_ error:NULL];
}

- (void)_writeHistoryToDisk {
    if ([iTermPreferences boolForKey:kPreferenceKeySavePasteAndCommandHistory]) {
        NSError *error = nil;
        NSData *data =
        [NSKeyedArchiver archivedDataWithRootObject:[self _entriesToDict]
                              requiringSecureCoding:NO
                                              error:&error];
        if (error) {
            DLog(@"Failed to archive command history: %@", error);
            return;
        }
        [data writeToFile:path_ atomically:NO];
        [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @0600 }
                                         ofItemAtPath:path_
                                                error:nil];
    }
}

- (void)_loadHistoryFromDisk {
    [entries_ removeAllObjects];

    NSData *data = [NSData dataWithContentsOfFile:path_];
    if (!data) {
        return;
    }
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    if (!unarchiver || error) {
        return;
    }
    unarchiver.requiresSecureCoding = NO;
    NSDictionary *dict = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];

    [self _addDictToEntries:dict];
}

- (void)save:(NSString*)value
{
    if (IsSecureEventInputEnabled() &&
        ![iTermAdvancedSettingsModel saveToPasteHistoryWhenSecureInputEnabled]) {
        DLog(@"Not saving paste history because secure keyboard entry is enabled");
        return;
    }
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![value length]) {
        return;
    }

    // Remove existing duplicate value.
    for (int i = 0; i < [entries_ count]; ++i) {
        PasteboardEntry *entry = [entries_ objectAtIndex:i];
        if ([[entry mainValue] isEqualToString:value]) {
            [entries_ removeObjectAtIndex:i];
            break;
        }
    }

    // If the last value is a prefix of this value then remove it. This prevents
    // pressing tab in the findbar from filling the history with various
    // versions of the same thing.
    PasteboardEntry *lastEntry;
    if ([entries_ count] > 0) {
        lastEntry = [entries_ objectAtIndex:[entries_ count] - 1];
        if ([value hasPrefix:[lastEntry mainValue]]) {
            [entries_ removeObjectAtIndex:[entries_ count] - 1];
        }
    }

    // Append this value.
    PasteboardEntry *entry = [PasteboardEntry entryWithString:value score:[[NSDate date] timeIntervalSince1970]];
    entry.timestamp = [NSDate date];
    [entries_ addObject:entry];
    if ([entries_ count] > maxEntries_) {
        [entries_ removeObjectAtIndex:0];
    }

    [self _writeHistoryToDisk];

    [[NSNotificationCenter defaultCenter] postNotificationName:kPasteboardHistoryDidChange
                                                        object:self];
}

@end

@implementation PasteboardHistoryWindowController {
    IBOutlet NSTableView *table_;
    NSTimer *minuteRefreshTimer_;
}

- (instancetype)init {
    self = [super initWithWindowNibName:@"PasteboardHistory" tablePtr:nil model:[[PopupModel alloc] init]];
    if (!self) {
        return nil;
    }

    [self window];
    [self setTableView:table_];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pasteboardHistoryDidChange:)
                                                 name:kPasteboardHistoryDidChange
                                               object:nil];

    return self;
}

- (NSString *)footerString {
    if ([iTermAdvancedSettingsModel saveToPasteHistoryWhenSecureInputEnabled]) {
        return nil;
    }
    if ([[iTermSecureKeyboardEntryController sharedInstance] isEnabled]) {
        return @"⚠️ Secure keyboard entry disables paste history.";
    }
    return nil;
}

- (void)pasteboardHistoryDidChange:(id)sender
{
    [self refresh];
}

- (void)copyFromHistory {
    [[self unfilteredModel] removeAllObjects];
    for (PasteboardEntry *e in [[PasteboardHistory sharedInstance] entries]) {
        [[self unfilteredModel] addObject:e];
    }
}

- (void)refresh
{
    [self copyFromHistory];
    [self reloadData:YES];
}

- (void)onOpen
{
    [self copyFromHistory];
    if (!minuteRefreshTimer_) {
        minuteRefreshTimer_ = [NSTimer scheduledTimerWithTimeInterval:61
                                                               target:self
                                                             selector:@selector(pasteboardHistoryDidChange:)
                                                             userInfo:nil
                                                              repeats:YES];
    }
}

- (void)onClose
{
    if (minuteRefreshTimer_) {
        [minuteRefreshTimer_ invalidate];
        minuteRefreshTimer_ = nil;
    }
    [self.delegate popupWillClose:self];
    [self setDelegate:nil];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
    PasteboardEntry *entry = [[self model] objectAtIndex:[self convertIndex:rowIndex]];
    if ([[aTableColumn identifier] isEqualToString:@"date"]) {
        // Date
        NSString *formattedDate = [NSDateFormatter dateDifferenceStringFromDate:entry.timestamp];
        int i = [self convertIndex:rowIndex];
        PopupEntry* e = [[self model] objectAtIndex:i];
        NSString *formattedLength = [NSString it_formatBytes:e.mainValue.length];
        const NSUInteger maximumLengthToScan = 1024 * 50;
        const NSInteger numberOfLines = [[e.mainValue substringToIndex:MIN(e.mainValue.length, maximumLengthToScan)] it_numberOfLines];
        NSString *formattedNumberOfLines;
        NSString *plus;
        if (e.mainValue.length > maximumLengthToScan) {
            plus = @"+";
        } else {
            plus = @"";
        }
        NSString *s = numberOfLines != 1 ? @"s": @"";
        formattedNumberOfLines = [NSString stringWithFormat:@"%@%@ line%@", @(numberOfLines), plus, s];
        return [NSString stringWithFormat:@"%@, %@, %@", formattedNumberOfLines, formattedLength, formattedDate];
    } else {
        // Contents
        return [super tableView:aTableView objectValueForTableColumn:aTableColumn row:rowIndex];
    }
}
- (NSString *)insertableString {
    if ([table_ selectedRow] < 0) {
        return nil;
    }
    PasteboardEntry *entry = [[self model] objectAtIndex:[self convertIndex:[table_ selectedRow]]];
    return [entry mainValue];
}

- (void)rowSelected:(id)sender {
    NSString *string = [self insertableString];
    if (!string) {
        return;
    }
    NSPasteboard *thePasteboard = [NSPasteboard generalPasteboard];
    [thePasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypeString] owner:nil];
    [thePasteboard setString:string forType:NSPasteboardTypeString];
    NSResponder *responder = [[[[iTermController sharedInstance] frontTextView] window] firstResponder];
    if ([responder respondsToSelector:@selector(paste:)]) {
        [responder it_performNonObjectReturningSelector:@selector(paste:) withObject:nil];
    }
    [super rowSelected:sender];
}

- (void)previewCurrentRow {
    NSString *string = [self insertableString];
    if (string) {
        [self.delegate popupPreview:string];
    }
}

@end

