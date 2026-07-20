// RectZones core: the parts of the app that are just arithmetic and data.
//
// Zone geometry, placement math, and config encoding live here. Nothing in this
// file may touch the screen, the window server, the filesystem, the user's
// settings, or AppKit — every input arrives as an argument. That restriction is
// the whole point: it is what lets a test target link this file and exercise the
// math with no display, no running app, and no Accessibility grant.
//
// If a function here starts needing NSScreen, RZStore, or a file path, it has
// stopped being core logic and belongs back in main.m, with the system state
// passed in as a parameter instead.
//
// Foundation only — NSRect/NSPoint come from NSGeometry, CGRect/CGPoint from
// CoreGraphics underneath it. Do not import Cocoa or AppKit.

#import <Foundation/Foundation.h>

#pragma mark - Model

// Zone: relative to the screen's visible area (0-1), origin TOP-LEFT.
NSMutableDictionary *RZZone(double x, double y, double w, double h);

@interface RZTemplate : NSObject
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *zones;
@end

// Deep (mutable) copy of zone dictionaries. valueForKey: on an array of
// NSDictionary does a dictionary lookup, so an explicit loop is required.
NSMutableArray<NSMutableDictionary *> *RZCopyZones(NSArray *zones);

RZTemplate *RZMakeTemplate(NSString *name, NSArray *zones);

// The templates a fresh install starts with.
NSArray<RZTemplate *> *RZPresetTemplates(void);

// Editor grid quantisation: two decimal places.
double RZSnap(double v);

#pragma mark - Coordinates

// CG/AX: origin at the primary screen's TOP-LEFT, y grows down.
// AppKit:  origin at the primary screen's BOTTOM-LEFT, y grows up.
// primaryHeight is NSMaxY of the primary screen's frame; the caller reads it
// from NSScreen so that the conversion itself stays testable.
NSPoint RZNSPointFromCG(CGPoint p, CGFloat primaryHeight);
CGRect  RZCGRectFromNS(NSRect r, CGFloat primaryHeight);

#pragma mark - Placement

// Placement gap: insets the target rect on all sides (like Rectangle's gaps).
// Skipped when the rect is too small to survive the inset.
NSRect RZPadRect(NSRect r, CGFloat gap);

// The zone's AppKit rect within a screen's visible frame.
NSRect RZZoneRectInFrame(NSDictionary *zone, NSRect visibleFrame);

// Index of the zone under an AppKit point, or -1. The point is clamped into the
// visible frame first: zones span visibleFrame but the cursor roams the whole
// screen, so a cursor in the menu bar or over the Dock would otherwise match
// nothing at exactly the moment the user is aiming for an edge.
NSInteger RZZoneIndexAtPoint(NSPoint p, NSRect visibleFrame, NSArray *zones);

// Index of the screen containing an AppKit point, or -1. frames holds each
// screen's full frame as an NSValue, in NSScreen.screens order.
//
// Falls back to an inclusive test on the max edges after the strict one fails:
// a cursor shoved to the top row arrives as CG y == 0, which converts to exactly
// NSMaxY(frame), and NSPointInRect treats the max edge as OUTSIDE — so the top
// row of the screen used to resolve to no screen at all. The other three edges
// clamp to width-1 / height-1 and never hit the exclusive bound.
NSInteger RZScreenIndexAtPoint(NSPoint p, NSArray<NSValue *> *frames);

#pragma mark - Config

// AppKit's NSEventModifierFlagControl / NSEventModifierFlagOption. Duplicated as
// plain numbers so this file need not import AppKit; main.m asserts at compile
// time that they still agree. An enum rather than `extern const` because only a
// constant expression can be checked by _Static_assert.
enum : NSUInteger {
    RZModControl = 1UL << 18,
    RZModOption  = 1UL << 19,
};

// Defaults: ⌃⌥↩ maximize, ⌃⌥→ sixths cycle.
NSDictionary *RZDefaultShortcuts(void);

// Decoding a config dictionary. Every one of these tolerates nil, a missing key,
// or a value of the wrong type — a truncated or hand-edited config.json must
// leave the app running on defaults rather than taking it down at launch.
NSMutableArray<RZTemplate *> *RZTemplatesFromConfig(NSDictionary *cfg);
NSString            *RZTriggerFromConfig(NSDictionary *cfg);   // default "cmd"
NSInteger            RZCustomKeyFromConfig(NSDictionary *cfg);  // default 0
NSInteger            RZGapFromConfig(NSDictionary *cfg);        // default 8
NSMutableDictionary *RZShortcutsFromConfig(NSDictionary *cfg);

// Picks wanted if it names a live template, else the first one.
NSString *RZResolveActiveUUID(NSString *wanted, NSArray<RZTemplate *> *templates);

// Encoding, ready for NSJSONSerialization.
NSDictionary *RZConfigDictionary(NSArray<RZTemplate *> *templates,
                                 NSString *activeUUID,
                                 NSString *trigger,
                                 NSInteger customKey,
                                 NSInteger gap,
                                 NSDictionary *shortcuts);

// Three-way merge, so a second running copy cannot silently undo your settings.
//
// config.json lives at a fixed path derived from the string "RectZones" rather
// than the bundle identifier, so two builds share one file. Writing the whole
// document from memory means the last writer wins with whatever state it happened
// to load hours ago — change the gap in one copy, touch anything in the other, and
// the old value comes back with no warning.
//
// baseline is the document as we last read or wrote it, disk is what is there now,
// mine is what we are about to write. Per key: if we did not touch it, whatever is
// on disk wins; if we did, ours does. Untouched keys therefore survive another
// copy's edits, and a key we genuinely changed is not silently reverted.
NSDictionary *RZMergeConfig(NSDictionary *baseline, NSDictionary *disk, NSDictionary *mine);
