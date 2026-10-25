/*
 * Copyright (c) 2025 Simon Peter
 * Copyright (c) 2026 Παναγιώτης Ἀθανασιάδης
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>

@class KeyboardSourcePicker;

/* Posted (NSDistributedNotificationCenter) after the list of input sources
   has been changed and applied. Menu extras can listen to this. */
extern NSString *const KeyboardInputSourcesDidChangeNotification;

@interface KeyboardController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSBox *keyboardTypeBox;
    NSScrollView *sourcesScroll;
    NSTableView *sourcesTable;
    NSButton *addSourceButton;
    NSButton *removeSourceButton;
    NSTextField *statusLabel;
    NSTextField *tryTextField;
    NSButton *isAppleKeyboardCheckbox;
    NSPopUpButton *keyboardTypePopup;

    NSDictionary *layouts;
    NSDictionary *variantsByLayout;
    NSString *setxkbmapPath;

    /* Selected input sources, in XKB group order.
       Each entry: NSDictionary { @"layout" : NSString, @"variant" : NSString (may be @"") } */
    NSMutableArray *inputSources;
    KeyboardSourcePicker *sourcePicker;   /* only non-nil while the sheet is open */

    NSString *lastAppliedLayout;
    NSString *lastAppliedVariant;
    NSString *lastAppliedKeyboardType;

    BOOL metadataLoaded;
    BOOL isRefreshing;
}

- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshFromSystem;
- (IBAction)applySelection:(id)sender;
- (IBAction)isAppleKeyboardCheckboxChanged:(id)sender;
- (IBAction)keyboardTypeChanged:(id)sender;
- (IBAction)addSourceClicked:(id)sender;
- (IBAction)removeSourceClicked:(id)sender;

@end
