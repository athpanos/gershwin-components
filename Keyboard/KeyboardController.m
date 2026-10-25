/*
 * Copyright (c) 2025 Simon Peter
 * Copyright (c) 2026 Παναγιώτης Ἀθανασιάδης
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "KeyboardController.h"
#import "AppearanceMetrics.h"
#import <dispatch/dispatch.h>

@class KeyboardController;

NSString *const KeyboardInputSourcesDidChangeNotification = @"GershwinKeyboardInputSourcesDidChange";

/* XKB supports at most 4 groups (layouts) at the same time. */
static const NSUInteger kMaxInputSources = 4;

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface KeyboardMainView : NSView
{
    KeyboardController *_layoutOwner;
}
@end

@implementation KeyboardMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        /* The host window does not necessarily size the pane view to its
           content area; make it fill the box content and re-lay out so the
           left/right margins stay symmetric.  GNUstep's setFrame: bypasses
           setFrameSize:, so re-lay out explicitly here. */
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:[self bounds].size.width];
    }
}
- (void)setLayoutOwner:(KeyboardController *)owner
{
    _layoutOwner = owner;
}
@end

static NSString *const kKeyboardDomain = @"KeyboardPreferences";
static NSString *const kDefaultKeyboardFile = @"/etc/default/keyboard";
static NSString *const kSetxkbmapLocal = @"/usr/local/bin/setxkbmap";
static NSString *const kSetxkbmapSystem = @"/usr/bin/setxkbmap";

static NSComparisonResult LayoutComparator(id a, id b, void *context)
{
    NSDictionary *map = (NSDictionary *)context;
    NSString *da = [map objectForKey:a];
    NSString *db = [map objectForKey:b];
    return [da caseInsensitiveCompare:db];
}

static NSTextField *PickerLabel(NSString *text, NSRect frame)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [label setStringValue:text ?: @""];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    return label;
}

/* ------------------------------------------------------------------------
 * KeyboardSourcePicker
 *
 * The sheet shown by the "+" button: a (filterable) list of the available
 * keyboard layouts on the left, the variants of the selected layout on the
 * right, and Cancel / Add buttons.
 * --------------------------------------------------------------------- */

@interface KeyboardSourcePicker : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
{
    NSPanel *panel;
    NSTextField *filterField;
    NSTableView *layoutTable;
    NSTableView *variantTable;
    NSButton *addButton;
    NSButton *cancelButton;

    NSDictionary *layouts;          /* code -> description */
    NSDictionary *variantsByLayout; /* code -> array of {code, description} */
    NSArray *allLayouts;            /* sorted codes */
    NSArray *shownLayouts;          /* after filtering */
    NSArray *currentVariants;       /* variants of activeLayout */
    NSString *activeLayout;         /* currently selected layout code or nil */
}
- (id)initWithLayouts:(NSDictionary *)layoutMap variants:(NSDictionary *)variantMap;
- (NSWindow *)window;
- (NSDictionary *)selectedSource;
@end

@implementation KeyboardSourcePicker

- (id)initWithLayouts:(NSDictionary *)layoutMap variants:(NSDictionary *)variantMap
{
    self = [super init];
    if (!self) {
        return nil;
    }
    layouts = [layoutMap retain];
    variantsByLayout = [variantMap retain];
    allLayouts = [[[layouts allKeys] sortedArrayUsingFunction:LayoutComparator context:layouts] retain];
    shownLayouts = [allLayouts retain];
    currentVariants = [[NSArray alloc] init];
    [self buildPanel];
    return self;
}

- (void)dealloc
{
    [layoutTable setDelegate:nil];
    [layoutTable setDataSource:nil];
    [variantTable setDelegate:nil];
    [variantTable setDataSource:nil];
    [filterField setDelegate:nil];
    [panel release];
    [filterField release];
    [layoutTable release];
    [variantTable release];
    [addButton release];
    [cancelButton release];
    [layouts release];
    [variantsByLayout release];
    [allLayouts release];
    [shownLayouts release];
    [currentVariants release];
    [activeLayout release];
    [super dealloc];
}

- (NSTableView *)addTableToView:(NSView *)parent frame:(NSRect)frame width:(CGFloat)colWidth
{
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:NO];
    [scroll setBorderType:NSBezelBorder];
    [parent addSubview:scroll];

    NSTableView *table = [[NSTableView alloc] initWithFrame:[scroll bounds]];
    [table setDelegate:self];
    [table setDataSource:self];
    [table setAllowsMultipleSelection:NO];
    [table setAllowsEmptySelection:YES];
    [table setHeaderView:nil];
    [table setTarget:self];
    [table setDoubleAction:@selector(addPressed:)];

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [column setTitle:@""];
    [column setWidth:colWidth];
    [column setEditable:NO];
    [table addTableColumn:column];
    [column release];

    [scroll setDocumentView:table];
    return table; /* +1, owned by the caller */
}

- (void)buildPanel
{
    const CGFloat W = 520, H = 380;
    const CGFloat margin = 20;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat btnW = 80, btnH = 24, btnBottom = 16;
    const CGFloat labelH = 18, fieldH = 22;

    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                       styleMask:NSTitledWindowMask
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    [panel setReleasedWhenClosed:NO];
    NSView *content = [panel contentView];

    CGFloat y = H - margin - labelH;
    [content addSubview:PickerLabel(@"Select a keyboard layout to add:",
                                    NSMakeRect(margin, y, W - 2 * margin, labelH))];

    y -= gap + fieldH;
    filterField = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, y, W - 2 * margin, fieldH)];
    [filterField setPlaceholderString:@"Filter"];
    [filterField setDelegate:self];
    [content addSubview:filterField];

    const CGFloat tablesBottom = btnBottom + btnH + 12;
    const CGFloat tablesTop = y - gap;
    const CGFloat tablesH = tablesTop - tablesBottom;
    const CGFloat halfW = (W - 2 * margin - gap) / 2.0;

    layoutTable = [self addTableToView:content
                                 frame:NSMakeRect(margin, tablesBottom, halfW, tablesH)
                                 width:halfW - 22];
    variantTable = [self addTableToView:content
                                  frame:NSMakeRect(margin + halfW + gap, tablesBottom, halfW, tablesH)
                                  width:halfW - 22];

    /* setDataSource: (inside addTableToView:) already queried the row count,
       but at that point layoutTable/variantTable were still nil, so the data
       source answered 0. Reload now that the ivars are set. */
    [layoutTable reloadData];
    [variantTable reloadData];

    cancelButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(W - margin - 2 * btnW - gap, btnBottom, btnW, btnH)];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setBezelStyle:NSRoundedBezelStyle];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelPressed:)];
    [cancelButton setKeyEquivalent:@"\033"];
    [content addSubview:cancelButton];

    addButton = [[NSButton alloc] initWithFrame:
        NSMakeRect(W - margin - btnW, btnBottom, btnW, btnH)];
    [addButton setTitle:@"Add"];
    [addButton setBezelStyle:NSRoundedBezelStyle];
    [addButton setTarget:self];
    [addButton setAction:@selector(addPressed:)];
    [addButton setKeyEquivalent:@"\r"];
    [addButton setEnabled:NO];
    [content addSubview:addButton];

    [panel setInitialFirstResponder:filterField];
}

- (NSWindow *)window
{
    return panel;
}

- (IBAction)addPressed:(id)sender
{
    (void)sender;
    if (!activeLayout) {
        return;
    }
    [NSApp endSheet:panel returnCode:NSOKButton];
}

- (IBAction)cancelPressed:(id)sender
{
    (void)sender;
    [NSApp endSheet:panel returnCode:NSCancelButton];
}

/* Returns {layout, variant} for the current selection, or nil. */
- (NSDictionary *)selectedSource
{
    if (!activeLayout) {
        return nil;
    }
    NSString *variant = @"";
    NSInteger vr = [variantTable selectedRow];
    if (vr >= 1 && (vr - 1) < (NSInteger)[currentVariants count]) {
        NSString *code = [[currentVariants objectAtIndex:vr - 1] objectForKey:@"code"];
        if (code) {
            variant = code;
        }
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            activeLayout, @"layout", variant, @"variant", nil];
}

/* Re-read the layout table selection into activeLayout / currentVariants. */
- (void)syncActiveLayout
{
    NSInteger row = [layoutTable selectedRow];

    [activeLayout release];
    activeLayout = nil;
    [currentVariants release];
    currentVariants = nil;

    if (row >= 0 && row < (NSInteger)[shownLayouts count]) {
        activeLayout = [[shownLayouts objectAtIndex:row] retain];
        currentVariants = [[variantsByLayout objectForKey:activeLayout] retain];
    }
    if (!currentVariants) {
        currentVariants = [[NSArray alloc] init];
    }

    [variantTable reloadData];
    if (activeLayout) {
        [variantTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [addButton setEnabled:(activeLayout != nil)];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    (void)notification;
    NSString *query = [[[filterField stringValue] lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSMutableArray *result = [NSMutableArray array];
    for (NSString *code in allLayouts) {
        if ([query length] == 0) {
            [result addObject:code];
            continue;
        }
        NSString *desc = [[layouts objectForKey:code] lowercaseString];
        if ([desc rangeOfString:query].location != NSNotFound ||
            [[code lowercaseString] rangeOfString:query].location != NSNotFound) {
            [result addObject:code];
        }
    }
    [shownLayouts release];
    shownLayouts = [result copy];

    [layoutTable reloadData];
    [layoutTable deselectAll:nil];
    [self syncActiveLayout];
}

// NSTableView data source
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == layoutTable) {
        return [shownLayouts count];
    } else if (tableView == variantTable) {
        return activeLayout ? (NSInteger)[currentVariants count] + 1 : 0;
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableColumn;
    if (tableView == layoutTable) {
        NSString *code = [shownLayouts objectAtIndex:row];
        NSString *desc = [layouts objectForKey:code];
        return [NSString stringWithFormat:@"%@ (%@)", desc, code];
    } else if (tableView == variantTable) {
        if (row == 0) {
            return @"Default";
        }
        NSDictionary *entry = [currentVariants objectAtIndex:row - 1];
        NSString *code = [entry objectForKey:@"code"];
        NSString *desc = [entry objectForKey:@"description"];
        return [NSString stringWithFormat:@"%@ (%@)", desc, code];
    }
    return nil;
}

// NSTableView delegate
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if ([notification object] == layoutTable) {
        [self syncActiveLayout];
    }
}

@end

/* ------------------------------------------------------------------------
 * KeyboardController
 * --------------------------------------------------------------------- */

@interface KeyboardController ()
- (void)ensureMetadataLoaded;
- (void)parseKeyboardMetadata;
- (NSDictionary *)fallbackLayouts;
- (NSString *)findExecutableFromCandidates:(NSArray *)candidates;
- (NSString *)pathForTool:(NSString *)name;
- (NSDictionary *)savedPreferences;
- (NSDictionary *)systemKeyboardDefaults;
- (NSDictionary *)currentXkbmapSettingsSync;
- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options error:(NSString **)error;
- (void)persistUserDefaultsLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (void)writeUserAutostartWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (BOOL)updateSystemKeyboardFileWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple error:(NSString **)error;
- (NSString *)modelForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (NSString *)shellEscapedValue:(NSString *)value;
- (NSString *)trimmed:(NSString *)value;
- (void)updateStatus:(NSString *)message;
- (void)showAlertWithTitle:(NSString *)title text:(NSString *)text;

/* Input sources model. */
- (NSArray *)sourcesFromLayoutString:(NSString *)layout variantString:(NSString *)variant;
- (NSArray *)sanitizedSources:(NSArray *)raw;
- (NSString *)joinedLayoutsForSources:(NSArray *)sources;
- (NSString *)joinedVariantsForSources:(NSArray *)sources;
- (NSString *)summaryForSources:(NSArray *)sources;
- (NSString *)displayNameForSource:(NSDictionary *)source;
- (NSInteger)indexOfSourceWithLayout:(NSString *)layout variant:(NSString *)variant;
- (void)updateSourceButtons;
- (void)addSheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo;

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w;
- (NSButton *)sourceButtonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame;
@end

@implementation KeyboardController

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;  // Start in refresh mode to prevent unwanted writes during initialization
        inputSources = [[NSMutableArray alloc] init];
        NSDebugLog(@"[Keyboard] Controller init, isRefreshing set to YES");
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [sourcesTable release];
    [sourcesScroll release];
    [addSourceButton release];
    [removeSourceButton release];
    [statusLabel release];
    [tryTextField release];
    [isAppleKeyboardCheckbox release];
    [keyboardTypePopup release];
    [layouts release];
    [variantsByLayout release];
    [setxkbmapPath release];
    [inputSources release];
    [sourcePicker release];
    [lastAppliedLayout release];
    [lastAppliedVariant release];
    [lastAppliedKeyboardType release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }

    [self ensureMetadataLoaded];

    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under status line */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    const CGFloat keyboardTypeBoxH = 96;      /* apple checkbox, type popup */
    const CGFloat tryFieldH = 24;             /* try text field (no box) */
    const CGFloat statusH = 18;

    mainView = [[KeyboardMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(KeyboardMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Keyboard Type group box ---- */
    keyboardTypeBox = [self groupBoxWithTitle:@"Keyboard Type"
                                       frame:NSMakeRect(sideMargin, y - keyboardTypeBoxH, boxW, keyboardTypeBoxH)
                                      inView:mainView];
    {
        CGFloat by = keyboardTypeBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:isAppleKeyboardCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:keyboardTypeBox y:by width:boxW];
        [isAppleKeyboardCheckbox setButtonType:NSSwitchButton];
        [isAppleKeyboardCheckbox setTitle:@"Apple keyboard"];
        [isAppleKeyboardCheckbox setTarget:self];
        [isAppleKeyboardCheckbox setAction:@selector(isAppleKeyboardCheckboxChanged:)];

        by -= METRICS_SPACE_8 + rowH;
        [self addPopUpRowWithLabel:@"Type:"
                            popup:keyboardTypePopup =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:keyboardTypeBox y:by width:boxW];
        [keyboardTypePopup addItemWithTitle:@"ANSI"];
        [keyboardTypePopup addItemWithTitle:@"ISO"];
        [keyboardTypePopup addItemWithTitle:@"JIS"];
        [keyboardTypePopup setTarget:self];
        [keyboardTypePopup setAction:@selector(keyboardTypeChanged:)];
    }

    /* ---- Input sources table with +/- buttons underneath (like macOS),
             filling the space between the box and the try field ---- */
    {
        const CGFloat tryFieldY = bottomMargin + statusH + METRICS_SPACE_8;
        const CGFloat tablesBottom = tryFieldY + tryFieldH + boxGap;
        const CGFloat tablesTop = winH - topMargin - keyboardTypeBoxH - boxGap;
        const CGFloat buttonW = 26, buttonH = 22;
        const CGFloat scrollBottom = tablesBottom + buttonH;
        const CGFloat scrollH = tablesTop - scrollBottom;

        sourcesScroll = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(sideMargin, scrollBottom, boxW, scrollH)];
        [sourcesScroll setHasVerticalScroller:YES];
        [sourcesScroll setHasHorizontalScroller:NO];
        [sourcesScroll setBorderType:NSBezelBorder];
        [mainView addSubview:sourcesScroll];

        sourcesTable = [[NSTableView alloc] initWithFrame:[sourcesScroll bounds]];
        [sourcesTable setDelegate:self];
        [sourcesTable setDataSource:self];
        [sourcesTable setAllowsMultipleSelection:NO];
        [sourcesTable setAllowsEmptySelection:YES];
        [sourcesTable setHeaderView:nil];
        NSTableColumn *sourceColumn = [[NSTableColumn alloc] initWithIdentifier:@"source"];
        [sourceColumn setTitle:@""];
        [sourceColumn setWidth:boxW - 22];
        [sourceColumn setEditable:NO];
        [sourcesTable addTableColumn:sourceColumn];
        [sourceColumn release];
        [sourcesScroll setDocumentView:sourcesTable];

        addSourceButton = [self sourceButtonWithTitle:@"+"
                                               action:@selector(addSourceClicked:)
                                                frame:NSMakeRect(sideMargin, tablesBottom, buttonW, buttonH)];
        removeSourceButton = [self sourceButtonWithTitle:@"-"
                                                  action:@selector(removeSourceClicked:)
                                                   frame:NSMakeRect(sideMargin + buttonW - 1, tablesBottom, buttonW, buttonH)];
        [removeSourceButton setEnabled:NO];
    }

    /* ---- Try text field directly on the view (single item, no box) ---- */
    {
        const CGFloat tryFieldY = bottomMargin + statusH + METRICS_SPACE_8;
        tryTextField = [[NSTextField alloc] initWithFrame:
            NSMakeRect(sideMargin, tryFieldY, contentW, tryFieldH)];
        [tryTextField setEditable:YES];
        [tryTextField setSelectable:YES];
        [tryTextField setBezeled:YES];
        [tryTextField setDrawsBackground:YES];
        [tryTextField setPlaceholderString:@"Type here to test the keyboard layout"];
        [tryTextField setAutoresizingMask:NSViewWidthSizable];
        [mainView addSubview:tryTextField];
    }

    /* Status label at the bottom */
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, statusH)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    [self refreshFromSystem];

    return mainView;
}

/* Re-lay out the group boxes for the given view width, keeping the
   left and right margins equal. Called whenever the host resizes the
   pane view. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    NSRect f;

    if (keyboardTypeBox) {
        f = [keyboardTypeBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [keyboardTypeBox setFrame:f];
    }
    if (sourcesScroll) {
        f = [sourcesScroll frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [sourcesScroll setFrame:f];
        NSTableColumn *col = [sourcesTable tableColumnWithIdentifier:@"source"];
        [col setWidth:f.size.width - 22];
    }
    if (tryTextField) {
        f = [tryTextField frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [tryTextField setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored. Width is managed by
   relayoutWithWidth: so margins stay symmetric. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setAutoresizingMask:NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

/* A plain read-only label. */
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text ?: @""];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setAlignment:align];
    return label;
}

/* Position a checkbox in the top-left of a group box's content area.
   Width-flexible so it tracks the box. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* A label + pop-up row: label on the left (right aligned), pop-up
   stretching to fill the rest of the row. */
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat popupW = w - 2 * pad - labelW - gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [popup setFrame:NSMakeRect(pad + labelW + gap, y, popupW, 22)];
    [popup setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:popup];
}

/* A small square "+" / "-" button attached to the bottom of the table.
   Returns an owned (+1) button, also added to mainView. */
- (NSButton *)sourceButtonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSSmallSquareBezelStyle];
    [button setButtonType:NSMomentaryPushInButton];
    [button setTarget:self];
    [button setAction:action];
    [mainView addSubview:button];
    return button;
}

- (void)ensureMetadataLoaded
{
    if (metadataLoaded) {
        return;
    }

    [self parseKeyboardMetadata];
    setxkbmapPath = [[self findExecutableFromCandidates:[NSArray arrayWithObjects:kSetxkbmapLocal, kSetxkbmapSystem, nil]] retain];
    metadataLoaded = YES;
}

- (void)parseKeyboardMetadata
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *possiblePaths = [NSArray arrayWithObjects:
                              @"/usr/share/X11/xkb/rules/base.lst",
                              @"/usr/local/share/X11/xkb/rules/base.lst",
                              nil];
    NSString *lstPath = nil;
    for (NSString *path in possiblePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            lstPath = path;
            break;
        }
    }
    NSError *error = nil;
    NSString *contents = lstPath ? [NSString stringWithContentsOfFile:lstPath encoding:NSUTF8StringEncoding error:&error] : nil;

    NSMutableDictionary *layoutMap = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *variantMap = [[NSMutableDictionary alloc] init];

    if (contents) {
        BOOL inLayout = NO;
        BOOL inVariant = NO;
        NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

        for (NSString *line in lines) {
            NSString *trim = [line stringByTrimmingCharactersInSet:ws];
            if ([trim length] == 0) {
                continue;
            }

            if ([trim hasPrefix:@"! "]) {
                inLayout = [trim hasPrefix:@"! layout"];
                inVariant = [trim hasPrefix:@"! variant"];
                continue;
            }

            if (inLayout) {
                NSRange space = [trim rangeOfString:@" "];
                if (space.location == NSNotFound) {
                    continue;
                }
                NSString *code = [[trim substringToIndex:space.location] stringByTrimmingCharactersInSet:ws];
                NSString *desc = [[trim substringFromIndex:space.location] stringByTrimmingCharactersInSet:ws];
                if ([code length] > 0) {
                    [layoutMap setObject:(desc.length ? desc : code) forKey:code];
                }
                continue;
            }

            if (inVariant) {
                NSRange colon = [trim rangeOfString:@":"];
                if (colon.location == NSNotFound) {
                    continue;
                }
                NSString *lhs = [[trim substringToIndex:colon.location] stringByTrimmingCharactersInSet:ws];
                NSString *rhs = [[trim substringFromIndex:(colon.location + 1)] stringByTrimmingCharactersInSet:ws];

                NSArray *parts = [lhs componentsSeparatedByCharactersInSet:ws];
                if ([parts count] < 2) {
                    continue;
                }
                NSString *variantCode = [parts objectAtIndex:0];
                NSString *layoutCode = [parts lastObject];

                if ([variantCode length] == 0 || [layoutCode length] == 0) {
                    continue;
                }

                NSMutableArray *list = [variantMap objectForKey:layoutCode];
                if (!list) {
                    list = [NSMutableArray array];
                    [variantMap setObject:list forKey:layoutCode];
                }
                NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:variantCode, @"code", (rhs.length ? rhs : variantCode), @"description", nil];
                [list addObject:entry];
            }
        }
    }

    if ([layoutMap count] == 0) {
        NSDictionary *fallback = [self fallbackLayouts];
        layoutMap = [fallback mutableCopy];
    }

    [layouts release];
    [variantsByLayout release];

    layouts = layoutMap;
    variantsByLayout = variantMap;
}

- (NSDictionary *)fallbackLayouts
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            @"English (US)", @"us",
            @"English (UK)", @"gb",
            @"German", @"de",
            @"French", @"fr",
            @"Spanish", @"es",
            @"Italian", @"it",
            nil];
}

- (NSString *)findExecutableFromCandidates:(NSArray *)candidates
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:[NSArray arrayWithObject:@"setxkbmap"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];

    NSString *trim = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] > 0 && [fm isExecutableFileAtPath:trim]) {
        return trim;
    }

    return nil;
}

/* Locate an executable in the usual system directories and in $PATH.
   (/usr/bin/<tool> is not where every system keeps it, e.g. /usr/local/bin.) */
- (NSString *)pathForTool:(NSString *)name
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:
                            @"/usr/local/bin", @"/usr/bin", @"/bin",
                            @"/usr/local/sbin", @"/usr/sbin", @"/sbin", nil];
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    if ([pathEnv length]) {
        [dirs addObjectsFromArray:[pathEnv componentsSeparatedByString:@":"]];
    }
    for (NSString *dir in dirs) {
        if (![dir length]) {
            continue;
        }
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (NSDictionary *)savedPreferences
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *domain = [defaults persistentDomainForName:kKeyboardDomain];
    if (domain) {
        return domain;
    }
    return [NSDictionary dictionary];
}

- (NSDictionary *)systemKeyboardDefaults
{
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:kDefaultKeyboardFile encoding:NSUTF8StringEncoding error:&error];
    if (!contents) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        val = [val stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if ([key length] && [val length]) {
            [result setObject:val forKey:key];
        }
    }
    return result;
}

// Synchronous helper - runs setxkbmap and parses its output.
// Only call from a background thread or during init.
- (NSDictionary *)currentXkbmapSettingsSync
{
    if (!setxkbmapPath) {
        return [NSDictionary dictionary];
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:setxkbmapPath];
    [task setArguments:[NSArray arrayWithObject:@"-query"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([key length] && [val length]) {
            [result setObject:val forKey:key];
        }
    }
    return result;
}

#pragma mark - Input sources model

/* Build a source list from XKB-style comma separated layout/variant strings
   ("us,gr" / ",polytonic"). Empty variant slots are preserved so that the
   layout <-> variant pairing stays positional. */
- (NSArray *)sourcesFromLayoutString:(NSString *)layout variantString:(NSString *)variant
{
    NSMutableArray *result = [NSMutableArray array];
    if (![layout length]) {
        return result;
    }
    NSArray *ls = [layout componentsSeparatedByString:@","];
    NSArray *vs = [variant length] ? [variant componentsSeparatedByString:@","] : [NSArray array];

    for (NSUInteger i = 0; i < [ls count]; i++) {
        NSString *l = [self trimmed:[ls objectAtIndex:i]];
        if (![l length]) {
            continue;
        }
        NSString *v = (i < [vs count]) ? [self trimmed:[vs objectAtIndex:i]] : @"";
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:l, @"layout", v, @"variant", nil]];
    }
    return result;
}

/* Validate and normalise a list read from the preferences. */
- (NSArray *)sanitizedSources:(NSArray *)raw
{
    NSMutableArray *result = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) {
        return result;
    }
    for (id item in raw) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *l = [item objectForKey:@"layout"];
        NSString *v = [item objectForKey:@"variant"];
        if (![l isKindOfClass:[NSString class]] || ![l length]) {
            continue;
        }
        if (![v isKindOfClass:[NSString class]]) {
            v = @"";
        }
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:l, @"layout", v, @"variant", nil]];
        if ([result count] >= kMaxInputSources) {
            break;
        }
    }
    return result;
}

- (NSString *)joinedLayoutsForSources:(NSArray *)sources
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *s in sources) {
        [parts addObject:[s objectForKey:@"layout"]];
    }
    return [parts componentsJoinedByString:@","];
}

/* Positional variant list; @"" when no source uses a variant at all. */
- (NSString *)joinedVariantsForSources:(NSArray *)sources
{
    NSMutableArray *parts = [NSMutableArray array];
    BOOL any = NO;
    for (NSDictionary *s in sources) {
        NSString *v = [s objectForKey:@"variant"];
        if (!v) {
            v = @"";
        }
        if ([v length]) {
            any = YES;
        }
        [parts addObject:v];
    }
    return any ? [parts componentsJoinedByString:@","] : @"";
}

/* "us, gr/polytonic" */
- (NSString *)summaryForSources:(NSArray *)sources
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *s in sources) {
        NSString *v = [s objectForKey:@"variant"];
        if ([v length]) {
            [parts addObject:[NSString stringWithFormat:@"%@/%@", [s objectForKey:@"layout"], v]];
        } else {
            [parts addObject:[s objectForKey:@"layout"]];
        }
    }
    return [parts componentsJoinedByString:@", "];
}

/* Human readable name for a table row, e.g. "Greek (polytonic)". */
- (NSString *)displayNameForSource:(NSDictionary *)source
{
    NSString *layout = [source objectForKey:@"layout"];
    NSString *variant = [source objectForKey:@"variant"];

    if ([variant length]) {
        NSArray *list = [variantsByLayout objectForKey:layout];
        for (NSDictionary *entry in list) {
            if ([[entry objectForKey:@"code"] isEqualToString:variant]) {
                return [entry objectForKey:@"description"];
            }
        }
        return [NSString stringWithFormat:@"%@ (%@)", layout, variant];
    }
    NSString *desc = [layouts objectForKey:layout];
    return desc ? desc : layout;
}

- (NSInteger)indexOfSourceWithLayout:(NSString *)layout variant:(NSString *)variant
{
    NSString *v = variant ? variant : @"";
    for (NSUInteger i = 0; i < [inputSources count]; i++) {
        NSDictionary *s = [inputSources objectAtIndex:i];
        NSString *sv = [s objectForKey:@"variant"];
        if (!sv) {
            sv = @"";
        }
        if ([[s objectForKey:@"layout"] isEqualToString:layout] && [sv isEqualToString:v]) {
            return (NSInteger)i;
        }
    }
    return -1;
}

- (void)updateSourceButtons
{
    NSInteger row = [sourcesTable selectedRow];
    [removeSourceButton setEnabled:(row >= 0 && [inputSources count] > 1)];
    [addSourceButton setEnabled:([inputSources count] < kMaxInputSources)];
}

#pragma mark - Add / remove

- (IBAction)addSourceClicked:(id)sender
{
    (void)sender;
    if (isRefreshing || sourcePicker) {
        return;
    }
    [self ensureMetadataLoaded];

    if ([inputSources count] >= kMaxInputSources) {
        [self showAlertWithTitle:@"Too many keyboard layouts"
                            text:[NSString stringWithFormat:
                                  @"At most %lu keyboard layouts can be active at the same time.",
                                  (unsigned long)kMaxInputSources]];
        return;
    }

    NSWindow *host = [mainView window];
    if (!host) {
        return;
    }

    sourcePicker = [[KeyboardSourcePicker alloc] initWithLayouts:layouts variants:variantsByLayout];
    [NSApp beginSheet:[sourcePicker window]
       modalForWindow:host
        modalDelegate:self
       didEndSelector:@selector(addSheetDidEnd:returnCode:contextInfo:)
          contextInfo:NULL];
}

- (void)addSheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    (void)contextInfo;
    [sheet orderOut:nil];

    NSDictionary *source = (returnCode == NSOKButton) ? [sourcePicker selectedSource] : nil;
    [sourcePicker release];
    sourcePicker = nil;

    if (!source) {
        return;
    }

    NSString *layout = [source objectForKey:@"layout"];
    NSString *variant = [source objectForKey:@"variant"];

    NSInteger existing = [self indexOfSourceWithLayout:layout variant:variant];
    if (existing >= 0) {
        [sourcesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:existing] byExtendingSelection:NO];
        [self showAlertWithTitle:@"Already added"
                            text:@"This keyboard layout is already in the list."];
        return;
    }
    if ([inputSources count] >= kMaxInputSources) {
        return;
    }

    [inputSources addObject:source];
    [sourcesTable reloadData];
    NSInteger last = (NSInteger)[inputSources count] - 1;
    [sourcesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:last] byExtendingSelection:NO];
    [sourcesTable scrollRowToVisible:last];
    [self updateSourceButtons];
    [self applySelection:nil];
}

- (IBAction)removeSourceClicked:(id)sender
{
    (void)sender;
    if (isRefreshing) {
        return;
    }
    NSInteger row = [sourcesTable selectedRow];
    if (row < 0 || row >= (NSInteger)[inputSources count] || [inputSources count] <= 1) {
        return;
    }

    [inputSources removeObjectAtIndex:row];
    [sourcesTable reloadData];

    NSInteger count = (NSInteger)[inputSources count];
    if (count > 0) {
        NSInteger newRow = (row < count) ? row : count - 1;
        [sourcesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
    }
    [self updateSourceButtons];
    [self applySelection:nil];
}

#pragma mark - NSTableView

// NSTableView data source methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == sourcesTable) {
        return [inputSources count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableColumn;
    if (tableView == sourcesTable && row >= 0 && row < (NSInteger)[inputSources count]) {
        return [self displayNameForSource:[inputSources objectAtIndex:row]];
    }
    return nil;
}

// NSTableView delegate methods
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if ([notification object] == sourcesTable) {
        [self updateSourceButtons];
    }
}

- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant error:(NSString **)error
{
    return [self applyLayout:layout variant:variant options:@"" error:error];
}

- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options error:(NSString **)error
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] applyLayout blocked during refresh");
        return YES;  // Pretend success during refresh
    }
    NSDebugLog(@"[Keyboard] applyLayout: layout='%@' variant='%@' options='%@'", layout, variant, options);
    if (!setxkbmapPath) {
        if (error) {
            *error = @"setxkbmap not found";
        }
        return NO;
    }

    NSString *trimmedLayout = [self trimmed:layout];
    NSString *trimmedVariant = [self trimmed:variant];
    NSString *trimmedOptions = [self trimmed:options];

    NSTask *clearTask = [[NSTask alloc] init];
    [clearTask setLaunchPath:setxkbmapPath];
    [clearTask setArguments:[NSArray arrayWithObjects:@"-option", @"", nil]];
    [clearTask launch];
    [clearTask waitUntilExit];
    [clearTask release];

    NSMutableArray *args = [NSMutableArray array];
    if ([trimmedLayout length]) {
        [args addObject:@"-layout"];
        [args addObject:trimmedLayout];
    }

    if ([trimmedVariant length]) {
        [args addObject:@"-variant"];
        [args addObject:trimmedVariant];
    }

    if ([trimmedOptions length]) {
        [args addObject:@"-option"];
        [args addObject:trimmedOptions];
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:setxkbmapPath];
    [task setArguments:args];

    NSPipe *stderrPipe = [NSPipe pipe];
    [task setStandardError:stderrPipe];

    [task launch];
    // Drain stderr before waitUntilExit to avoid pipe-buffer deadlock
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    int status = [task terminationStatus];
    [task release];

    if (status != 0) {
        NSString *stderrString = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] autorelease];
        if (error) {
            *error = (stderrString.length ? stderrString : @"Failed to run setxkbmap");
        }
        return NO;
    }

    [lastAppliedLayout release];
    [lastAppliedVariant release];

    lastAppliedLayout = [trimmedLayout copy];
    lastAppliedVariant = [trimmedVariant copy];

    return YES;
}

- (void)persistUserDefaultsLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] persistUserDefaultsLayout blocked during refresh");
        return;
    }
    NSDebugLog(@"[Keyboard] persistUserDefaultsLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    /* Start from the existing domain so that other keys stored there (for
       example a future switching shortcut) are not wiped out. */
    NSDictionary *existing = [defaults persistentDomainForName:kKeyboardDomain];
    NSMutableDictionary *domain = existing ? [NSMutableDictionary dictionaryWithDictionary:existing]
                                           : [NSMutableDictionary dictionary];
    if (layout) {
        [domain setObject:layout forKey:@"layout"];
    }
    if (variant) {
        [domain setObject:variant forKey:@"variant"];
    }
    if (options) {
        [domain setObject:options forKey:@"options"];
    }
    if (keyboardType) {
        [domain setObject:keyboardType forKey:@"keyboardType"];
    }
    [domain setObject:[NSNumber numberWithBool:isApple] forKey:@"isApple"];

    /* Source of truth for the list of input sources (XKB group order).
       "layout" / "variant" above hold the same data joined with commas. */
    if ([inputSources count]) {
        /* "name" is only for display (e.g. in the menu bar extra), so that
           other components do not have to parse base.lst themselves. */
        NSMutableArray *stored = [NSMutableArray array];
        for (NSDictionary *s in inputSources) {
            NSString *v = [s objectForKey:@"variant"];
            [stored addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                               [s objectForKey:@"layout"], @"layout",
                               (v ? v : @""), @"variant",
                               [self displayNameForSource:s], @"name",
                               nil]];
        }
        [domain setObject:stored forKey:@"inputSources"];
    }

    [defaults setPersistentDomain:domain forName:kKeyboardDomain];
    [defaults synchronize];
}

- (void)writeUserAutostartWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] writeUserAutostartWithLayout blocked during refresh");
        return;
    }
    NSDebugLog(@"[Keyboard] writeUserAutostartWithLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);
    NSString *home = NSHomeDirectory();
    NSString *binDir = [home stringByAppendingPathComponent:@".local/bin"];
    NSString *scriptPath = [binDir stringByAppendingPathComponent:@"gershwin-apply-keyboard.sh"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:binDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *escapedLayout = [self shellEscapedValue:(layout ? layout : @"")];
    NSString *escapedVariant = [self shellEscapedValue:(variant ? variant : @"")];
    NSString *escapedOptions = [self shellEscapedValue:(options ? options : @"")];
    NSString *model = [self modelForKeyboardType:(keyboardType ? keyboardType : @"") isApple:isApple];
    NSString *escapedModel = [self shellEscapedValue:model];

    NSMutableString *script = [NSMutableString string];
    [script appendString:@"#!/bin/sh\nset -e\n\nsetxkbmap_bin=\"/usr/local/bin/setxkbmap\"\n[ -x \"$setxkbmap_bin\" ] || setxkbmap_bin=\"/usr/bin/setxkbmap\"\n[ -x \"$setxkbmap_bin\" ] || exit 0\n\n$setxkbmap_bin -option '' >/dev/null 2>&1 || true\ncmd=\"$setxkbmap_bin -model '"];
    [script appendString:escapedModel];
    [script appendString:@"' -layout '"];
    [script appendString:escapedLayout];
    [script appendString:@"'\"\nif [ -n \""];
    [script appendString:escapedVariant];
    [script appendString:@"\" ]; then\n  cmd=\"$cmd -variant '"];
    [script appendString:escapedVariant];
    [script appendString:@"'\"\nfi\nif [ -n \""];
    [script appendString:escapedOptions];
    [script appendString:@"\" ]; then\n  cmd=\"$cmd -option '"];
    [script appendString:escapedOptions];
    [script appendString:@"'\"\nelse\n  cmd=\"$cmd -option ''\"\nfi\nsh -c \"$cmd\" >/dev/null 2>&1\n"];
    
    /*
     * Apple ISO Keyboard TLDE/LSGT Swap Fix
     * 
     * Problem: Apple ISO keyboards have two keys physically swapped compared to PC ISO keyboards:
     * 
     * PC ISO Layout:              Apple ISO Layout:
     *   Top-left: ^ (TLDE = 49)     Top-left: < (physically TLDE = 49)
     *   Left of Z: < (LSGT = 94)    Left of Z: ^ (physically LSGT = 94)
     * 
     * The XKB applealu_iso model correctly identifies the keyboard but does NOT remap
     * the keycodes to match the physical layout. This causes the symbols to appear wrong:
     * - Pressing the top-left key (expecting <) produces ^
     * - Pressing the left-of-Z key (expecting ^) produces <
     * 
     * Solution: After setxkbmap configures the layout, use xmodmap to swap the symbol
     * mappings for keycodes 49 and 94, so they match what users expect based on the
     * physical key labels and positions on Apple ISO keyboards.
     * 
     * For German (de) layout specifically:
     *   - Keycode 49 should produce: < > (less/greater with bar/dagger on level 3/4)
     *   - Keycode 94 should produce: ^ ° (circumflex/degree with notsign on level 3)
     *
     * NOTE: these xmodmap commands hard-code Latin keysyms and would overwrite the
     * symbols of every XKB group. They are therefore only applied when a single
     * layout is active.
     */
    BOOL singleLayout = ([layout rangeOfString:@","].location == NSNotFound);
    if (isApple && [keyboardType isEqualToString:@"ISO"] && singleLayout) {
        [script appendString:@"\n# Fix Apple ISO keyboard TLDE/LSGT swap\n"];
        [script appendString:@"if command -v xmodmap >/dev/null 2>&1; then\n"];
        [script appendString:@"  xmodmap -e 'keycode 49 = less greater less greater bar dagger bar' >/dev/null 2>&1 || true\n"];
        [script appendString:@"  xmodmap -e 'keycode 94 = asciicircum degree asciicircum degree notsign notsign notsign' >/dev/null 2>&1 || true\n"];
        [script appendString:@"fi\n"];
    }

    [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];
    [fm setAttributes:attrs ofItemAtPath:scriptPath error:nil];
}

- (BOOL)updateSystemKeyboardFileWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple error:(NSString **)error
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] updateSystemKeyboardFileWithLayout blocked during refresh");
        if (error) {
            *error = @"Skipped during refresh";
        }
        return NO;
    }
    NSDebugLog(@"[Keyboard] updateSystemKeyboardFileWithLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];

    NSDictionary *systemDefaults = [self systemKeyboardDefaults];
    NSString *model = nil;
    if ([keyboardType length]) {
        model = [self modelForKeyboardType:keyboardType isApple:isApple];
    } else {
        model = [systemDefaults objectForKey:@"XKBMODEL"];
        if (![model length]) {
            // Default to a reasonable PC ISO model if nothing else is known
            model = @"pc105";
        }
    }

    NSMutableString *payload = [NSMutableString string];
    [payload appendFormat:@"XKBMODEL=\"%@\"\n", model];
    [payload appendFormat:@"XKBLAYOUT=\"%@\"\n", (layout ? layout : @"")];
    [payload appendFormat:@"XKBVARIANT=\"%@\"\n", (variant ? variant : @"")];
    [payload appendFormat:@"XKBOPTIONS=\"%@\"\n", (options ? options : @"")];

    if (![payload writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) {
            *error = @"Unable to write temporary keyboard file";
        }
        return NO;
    }

    NSString *sudoPath = [self pathForTool:@"sudo"];
    if (!sudoPath) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = @"sudo not available";
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:sudoPath];
    [task setArguments:[NSArray arrayWithObjects:@"-E", @"-A", @"install", @"-m", @"644", tmpPath, kDefaultKeyboardFile, nil]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardError:pipe];

    [task launch];
    [task waitUntilExit];

    int status = [task terminationStatus];
    NSData *stderrData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *stderrString = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] autorelease];

    [task release];
    [fm removeItemAtPath:tmpPath error:nil];

    if (status != 0) {
        if (error) {
            *error = (stderrString.length ? stderrString : @"Failed to update /etc/default/keyboard");
        }
        return NO;
    }

    return YES;
}

- (NSString *)modelForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isApple) {
        if ([keyboardType isEqualToString:@"ISO"]) {
            return @"applealu_iso";
        } else if ([keyboardType isEqualToString:@"JIS"]) {
            return @"applealu_jis";
        } else {
            return @"applealu_ansi";
        }
    } else {
        if ([keyboardType isEqualToString:@"ISO"]) {
            return @"pc105";
        } else if ([keyboardType isEqualToString:@"JIS"]) {
            return @"pc106";
        } else {
            return @"pc104";
        }
    }
}

- (NSString *)shellEscapedValue:(NSString *)value
{
    NSString *v = (value ? value : @"");
    return [v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

- (NSString *)trimmed:(NSString *)value
{
    if (!value) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

- (void)showAlertWithTitle:(NSString *)title text:(NSString *)text
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:(title ? title : @"Keyboard Preference")];
    [alert setInformativeText:(text ? text : @"")];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (IBAction)isAppleKeyboardCheckboxChanged:(id)sender
{
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        return;
    }
    [self applySelection:nil];
}

- (IBAction)keyboardTypeChanged:(id)sender
{
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        return;
    }
    [self applySelection:nil];
}

- (IBAction)applySelection:(id)sender
{
    NSDebugLog(@"[Keyboard] applySelection called, isRefreshing=%d", isRefreshing);
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] Blocking applySelection during refresh");
        return;
    }
    [self ensureMetadataLoaded];

    if ([inputSources count] == 0) {
        return;
    }

    /* XKB groups: "us,gr" / ",polytonic" - one entry per input source. */
    NSString *layout = [self joinedLayoutsForSources:inputSources];
    NSString *variant = [self joinedVariantsForSources:inputSources];
    BOOL multipleSources = ([inputSources count] > 1);

    NSString *options = @"";
    if ([isAppleKeyboardCheckbox state] == NSOnState) {
        options = @"altwin:swap_alt_win";
    }

    NSString *keyboardType = [[keyboardTypePopup titleOfSelectedItem] copy];
    BOOL isApple = ([isAppleKeyboardCheckbox state] == NSOnState);

    NSDebugLog(@"[Keyboard] Applying layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);

    [self updateStatus:@"Applying layout..."];

    // Capture values for the block
    NSString *layoutCopy  = [layout copy];
    NSString *variantCopy = [variant copy];
    NSString *optionsCopy = [options copy];
    NSString *summaryCopy = [[self summaryForSources:inputSources] copy];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *applyError = nil;
        BOOL success = [self applyLayout:layoutCopy variant:variantCopy options:optionsCopy error:&applyError];
        NSString *errorCopy = [applyError copy];

        // Apple ISO TLDE/LSGT swap (single layout only, see writeUserAutostart...)
        if (success && isApple && !multipleSources && [keyboardType isEqualToString:@"ISO"]) {
            NSDebugLog(@"[Keyboard] Applying TLDE/LSGT swap for Apple ISO keyboard");
            /* If xmodmap is not installed xmodmapPath is nil, xmodmapTask stays
               nil and every message below is a harmless no-op. */
            NSString *xmodmapPath = [self pathForTool:@"xmodmap"];
            NSTask *xmodmapTask = xmodmapPath ? [[NSTask alloc] init] : nil;
            [xmodmapTask setLaunchPath:xmodmapPath];
            [xmodmapTask setArguments:[NSArray arrayWithObjects:
                @"-e", @"keycode 49 = less greater less greater bar dagger bar",
                @"-e", @"keycode 94 = asciicircum degree asciicircum degree notsign notsign notsign",
                nil]];
            [xmodmapTask launch];
            [xmodmapTask waitUntilExit];
            [xmodmapTask release];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                [self showAlertWithTitle:@"Could not set layout" text:errorCopy];
                [self updateStatus:[NSString stringWithFormat:@"Failed to apply layout (%@)", errorCopy ? errorCopy : @"unknown error"]];
                [errorCopy release];
                [layoutCopy release];
                [variantCopy release];
                [optionsCopy release];
                [summaryCopy release];
                [keyboardType release];
                return;
            }
            [errorCopy release];

            [self persistUserDefaultsLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple];
            [self writeUserAutostartWithLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple];

            NSString *systemError = nil;
            BOOL systemUpdated = [self updateSystemKeyboardFileWithLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple error:&systemError];

            NSMutableString *status = [NSMutableString stringWithFormat:@"Active layouts: %@", summaryCopy];
            if ([keyboardType length]) {
                [status appendFormat:@" (%@)", keyboardType];
            }

            if (systemUpdated) {
                [status appendString:@" - saved to /etc/default/keyboard."];
            } else {
                [status appendString:@" - saved for this user. System file not updated."];
                if ([systemError length]) {
                    [status appendFormat:@" (%@)", systemError];
                }
            }
            if (isApple && multipleSources && [keyboardType isEqualToString:@"ISO"]) {
                [status appendString:@" Apple ISO key swap is not applied with several layouts."];
            }

            [self updateStatus:status];

            /* Let other components (menu extra, switcher) know. */
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:KeyboardInputSourcesDidChangeNotification
                              object:nil
                            userInfo:nil];

            [layoutCopy release];
            [variantCopy release];
            [optionsCopy release];
            [summaryCopy release];
            [keyboardType release];
        });
    });
}

- (void)refreshFromSystem
{
    NSDebugLog(@"[Keyboard] refreshFromSystem: START");
    [self ensureMetadataLoaded];
    isRefreshing = YES;
    NSDebugLog(@"[Keyboard] isRefreshing set to YES");

    // Gather data that can be read synchronously (file reads, user defaults)
    NSDictionary *system = [self systemKeyboardDefaults];
    NSDictionary *saved  = [self savedPreferences];

    // Move the potentially blocking setxkbmap query off the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *xkbCurrent = [self currentXkbmapSettingsSync];

        // Come back to the main thread for all UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *layout = [system objectForKey:@"XKBLAYOUT"];
            NSString *variant = [system objectForKey:@"XKBVARIANT"];
            NSString *options = [system objectForKey:@"XKBOPTIONS"];
            NSString *keyboardType = nil;
            NSNumber *savedIsApple = nil;
            NSDebugLog(@"[Keyboard] System config file: layout='%@' variant='%@' options='%@'", layout, variant, options);

            // If system config is empty, try current XKB settings
            if (![layout length]) {
                NSDebugLog(@"[Keyboard] System config empty, trying current XKB settings");
                layout = [xkbCurrent objectForKey:@"layout"];
                variant = [xkbCurrent objectForKey:@"variant"];
                options = [xkbCurrent objectForKey:@"options"];
                NSDebugLog(@"[Keyboard] Current XKB: layout='%@' variant='%@' options='%@'", layout, variant, options);
            }

            // If still empty, try saved preferences
            if (![layout length]) {
                NSDebugLog(@"[Keyboard] Still empty, trying saved preferences");
                layout = [saved objectForKey:@"layout"];
                variant = [saved objectForKey:@"variant"];
                options = [saved objectForKey:@"options"];
                keyboardType = [saved objectForKey:@"keyboardType"];
                savedIsApple = [saved objectForKey:@"isApple"];
                if (savedIsApple) {
                    [isAppleKeyboardCheckbox setState:([savedIsApple boolValue] ? NSOnState : NSOffState)];
                }
            }

            // If keyboardType not found in saved prefs, try to infer from system model
            if (!keyboardType) {
                NSString *model = [system objectForKey:@"XKBMODEL"];
                if ([model isEqualToString:@"pc104"] || [model isEqualToString:@"applealu_ansi"]) {
                    keyboardType = @"ANSI";
                } else if ([model isEqualToString:@"pc105"] || [model isEqualToString:@"applealu_iso"]) {
                    keyboardType = @"ISO";
                } else if ([model isEqualToString:@"pc106"] || [model isEqualToString:@"applealu_jis"]) {
                    keyboardType = @"JIS";
                } else {
                    keyboardType = @"ANSI";
                }
            }

            /* Input sources: the list saved by this pane wins; otherwise
               build it from the comma separated XKB layout/variant strings. */
            NSArray *newSources = [self sanitizedSources:[saved objectForKey:@"inputSources"]];
            if ([newSources count] == 0) {
                newSources = [self sourcesFromLayoutString:layout variantString:variant];
                if ([newSources count] > kMaxInputSources) {
                    newSources = [newSources subarrayWithRange:NSMakeRange(0, kMaxInputSources)];
                }
            }
            if ([newSources count] == 0) {
                newSources = [NSArray arrayWithObject:
                    [NSDictionary dictionaryWithObjectsAndKeys:@"us", @"layout", @"", @"variant", nil]];
            }
            [inputSources removeAllObjects];
            [inputSources addObjectsFromArray:newSources];
            [sourcesTable reloadData];
            [sourcesTable deselectAll:nil];
            [self updateSourceButtons];

            NSDebugLog(@"[Keyboard] Final values to select: layout='%@' variant='%@' options='%@' keyboardType='%@'", layout, variant, options, keyboardType);

            // Determine Apple state
            BOOL modelIndicatesApple = NO;
            NSString *modelVal = [system objectForKey:@"XKBMODEL"];
            if (modelVal && [modelVal hasPrefix:@"apple"]) {
                modelIndicatesApple = YES;
            }
            BOOL isApple = NO;
            if (savedIsApple) {
                isApple = [savedIsApple boolValue];
            } else if (modelIndicatesApple) {
                isApple = YES;
            } else if ([options isEqualToString:@"altwin:swap_alt_win"]) {
                isApple = YES;
            }

            [isAppleKeyboardCheckbox setState:(isApple ? NSOnState : NSOffState)];

            if ([keyboardType length]) {
                [keyboardTypePopup selectItemWithTitle:keyboardType];
            } else {
                [keyboardTypePopup selectItemAtIndex:0];
            }

            NSMutableString *status = [NSMutableString stringWithFormat:@"Current layouts: %@", [self summaryForSources:inputSources]];
            if ([keyboardType length]) {
                [status appendFormat:@" (%@)", keyboardType];
            }
            if ([options length]) {
                [status appendFormat:@" (%@)", options];
            }

            [status appendString:@". Changes apply instantly."];
            [self updateStatus:status];

            isRefreshing = NO;
            NSDebugLog(@"[Keyboard] refreshFromSystem: END");
        });
    });
}

@end
