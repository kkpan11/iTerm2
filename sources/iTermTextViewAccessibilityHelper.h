//
//  iTermTextViewAccessibilityHelper.h
//  iTerm2
//
//  Created by George Nachman on 6/22/15.
//
//

#import <Cocoa/Cocoa.h>
#import "ScreenChar.h"

// "Accessibility space" is the last lines of the session which are exposed to
// accessibility, as opposed to actual line numbers in the terminal. The 0th
// line in accessibility space may be the Nth line in the terminal, or the 0th
// line if accessibility space is at least as large as the terminal.
@protocol iTermTextViewAccessibilityHelperDelegate <NSObject>

// Return an array of characters for a line number in accessibility-space.
- (const screen_char_t *)accessibilityHelperLineAtIndex:(int)accessibilityIndex
                                           continuation:(screen_char_t *)continuation;

// Return the width of the screen in cells.
- (int)accessibilityHelperWidth;

// Return the number of lines visible to accessibility.
- (int)accessibilityHelperNumberOfLines;

// Return the coordinate for a point in screen coords.
- (VT100GridCoord)accessibilityHelperCoordForPoint:(NSPoint)point;

// Return a rect in screen coords for a range of cells in accessibility-space.
- (NSRect)accessibilityHelperFrameForCoordRange:(VT100GridCoordRange)coordRange;

// Return the location of the cursor in accessibility-space.
- (VT100GridCoord)accessibilityHelperCursorCoord;

// Select the range, which is in accessibility-space.
- (void)accessibilityHelperSetSelectedRange:(VT100GridCoordRange)range;

// Gets the selected range in accessibility-space.
- (VT100GridCoordRange)accessibilityHelperSelectedRange;

// Returns the contents of selected text in accessibility-space only.
- (NSString *)accessibilityHelperSelectedText;

// Returns the URL of the current document
- (NSURL *)accessibilityHelperCurrentDocumentURL;

@end

// This outsources accessibilty methods for PTYTextView. It's useful to keep
// separate because it operates on a subset of the lines of the terminal and
// there's a clean interface here.
@interface iTermTextViewAccessibilityHelper : NSObject

@property(nonatomic, assign) id<iTermTextViewAccessibilityHelperDelegate> delegate;

- (NSInteger)lineForIndex:(NSUInteger)theIndex;
- (NSRange)rangeForLine:(NSUInteger)lineNumber;
- (NSString *)stringForRange:(NSRange)range;
// WARNING! screenPosition is idiotic: y=0 is the top of the main screen and it increases going down.
- (NSRange)rangeForPosition:(NSPoint)screenPosition;
- (NSRange)rangeOfIndex:(NSUInteger)theIndex;
- (NSRect)boundsForRange:(NSRange)range;
- (NSAttributedString *)attributedStringForRange:(NSRange)range;
- (NSAccessibilityRole)role;
- (NSString *)roleDescription;
- (NSString *)help;
- (BOOL)focused;
- (NSString *)label;
- (NSString *)allText;
- (NSInteger)numberOfCharacters;
- (NSString *)selectedText;
- (NSRange)selectedTextRange;
- (NSArray *)selectedTextRanges;
- (NSInteger)insertionPointLineNumber;
- (NSRange)visibleCharacterRange;
- (NSURL *)currentDocumentURL;
- (void)setSelectedTextRange:(NSRange)range;


@end
