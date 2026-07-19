// RectZones — hold the trigger key while dragging a window and zones appear on
// screen; every zone you sweep over while the key is held joins the selection and
// the window fills their union on drop. Release the key before dropping to cancel.
// Templates are managed in the Settings window.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

// Diagnostic log: /tmp/rectzones.log — see what actually happened when debugging.
static void RZLog(NSString *fmt, ...) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; });
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/rectzones.log", "a");
    if (f) {
        fprintf(f, "%s %s\n", [df stringFromDate:NSDate.date].UTF8String, s.UTF8String);
        fclose(f);
    }
}

#pragma mark - Model

// Zone: relative to the screen's visible area (0-1), origin TOP-LEFT.
static NSMutableDictionary *RZZone(double x, double y, double w, double h) {
    return [@{@"x": @(x), @"y": @(y), @"w": @(w), @"h": @(h)} mutableCopy];
}

@interface RZTemplate : NSObject
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *zones;
@end
@implementation RZTemplate
@end

// Deep (mutable) copy of zone dictionaries. valueForKey: on an array of
// NSDictionary does a dictionary lookup, so an explicit loop is required.
static NSMutableArray<NSMutableDictionary *> *RZCopyZones(NSArray *zones) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:zones.count];
    for (NSDictionary *z in zones) [out addObject:[z mutableCopy]];
    return out;
}

static RZTemplate *RZMakeTemplate(NSString *name, NSArray *zones) {
    RZTemplate *t = [RZTemplate new];
    t.uuid = [[NSUUID UUID] UUIDString];
    t.name = name;
    t.zones = RZCopyZones(zones);
    return t;
}

@interface RZStore : NSObject
@property (nonatomic, strong) NSMutableArray<RZTemplate *> *templates;
@property (nonatomic, copy) NSString *activeUUID;
@property (nonatomic, copy) NSString *trigger; // cmd | alt | ctrl | fn | custom
@property (nonatomic) NSInteger customKey;     // key held down while trigger=custom
@property (nonatomic) NSInteger gap;           // placement gap (px, all four sides)
// action id → {key: keyCode, mods: NSEventModifierFlags}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *shortcuts;
+ (instancetype)shared;
- (RZTemplate *)active;
- (void)save;
- (void)upsert:(RZTemplate *)t;
- (void)removeUUID:(NSString *)uuid;
@end

@implementation RZStore

+ (instancetype)shared {
    static RZStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZStore new]; [s load]; });
    return s;
}

- (NSString *)path {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0]
                     stringByAppendingPathComponent:@"RectZones"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"config.json"];
}

- (NSArray<RZTemplate *> *)presets {
    double u = 1.0 / 3.0;
    return @[
        RZMakeTemplate(@"Halves", @[RZZone(0, 0, .5, 1), RZZone(.5, 0, .5, 1)]),
        RZMakeTemplate(@"Three Columns", @[RZZone(0, 0, u, 1), RZZone(u, 0, u, 1), RZZone(2 * u, 0, u, 1)]),
        RZMakeTemplate(@"2×2", @[RZZone(0, 0, .5, .5), RZZone(.5, 0, .5, .5),
                                 RZZone(0, .5, .5, .5), RZZone(.5, .5, .5, .5)]),
        RZMakeTemplate(@"Left Wide", @[RZZone(0, 0, .62, 1), RZZone(.62, 0, .38, .5), RZZone(.62, .5, .38, .5)]),
        RZMakeTemplate(@"Sixths (3×2)", @[RZZone(0, 0, u, .5), RZZone(u, 0, u, .5), RZZone(2 * u, 0, u, .5),
                                          RZZone(0, .5, u, .5), RZZone(u, .5, u, .5), RZZone(2 * u, .5, u, .5)]),
    ];
}

- (void)load {
    self.templates = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:[self path]];
    NSDictionary *cfg = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    for (NSDictionary *td in cfg[@"templates"]) {
        RZTemplate *t = [RZTemplate new];
        t.uuid = td[@"uuid"] ?: [[NSUUID UUID] UUIDString];
        t.name = td[@"name"] ?: @"Untitled";
        t.zones = [NSMutableArray array];
        for (NSDictionary *z in td[@"zones"]) {
            [t.zones addObject:[z mutableCopy]];
        }
        if (t.zones.count) [self.templates addObject:t];
    }
    if (!self.templates.count) {
        [self.templates addObjectsFromArray:[self presets]];
    }
    self.activeUUID = cfg[@"active"] ?: self.templates[0].uuid;
    if (![self findUUID:self.activeUUID]) self.activeUUID = self.templates[0].uuid;
    self.trigger = cfg[@"trigger"] ?: @"cmd";
    self.customKey = [cfg[@"customKey"] integerValue];
    self.gap = cfg[@"gap"] ? [cfg[@"gap"] integerValue] : 8;
    self.shortcuts = [NSMutableDictionary dictionary];
    NSDictionary *sc = cfg[@"shortcuts"];
    if ([sc isKindOfClass:NSDictionary.class]) {
        [self.shortcuts addEntriesFromDictionary:sc];
    } else {
        // Defaults: ⌃⌥↩ maximize, ⌃⌥→ sixths cycle
        NSUInteger co = NSEventModifierFlagControl | NSEventModifierFlagOption;
        self.shortcuts[@"maximize"] = @{@"key": @36,  @"mods": @(co)};
        self.shortcuts[@"grid32"]   = @{@"key": @124, @"mods": @(co)};
    }
    [self save];
}

- (RZTemplate *)findUUID:(NSString *)uuid {
    for (RZTemplate *t in self.templates)
        if ([t.uuid isEqualToString:uuid]) return t;
    return nil;
}

- (RZTemplate *)active {
    return [self findUUID:self.activeUUID] ?: self.templates[0];
}

- (void)save {
    NSMutableArray *ts = [NSMutableArray array];
    for (RZTemplate *t in self.templates) {
        [ts addObject:@{@"uuid": t.uuid, @"name": t.name, @"zones": t.zones}];
    }
    NSDictionary *cfg = @{@"templates": ts, @"active": self.activeUUID,
                          @"trigger": self.trigger ?: @"cmd",
                          @"customKey": @(self.customKey),
                          @"gap": @(self.gap),
                          @"shortcuts": self.shortcuts ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self path] atomically:YES];
}

- (void)upsert:(RZTemplate *)t {
    if (![self findUUID:t.uuid]) [self.templates addObject:t];
    [self save];
}

- (void)removeUUID:(NSString *)uuid {
    if (self.templates.count <= 1) return;
    RZTemplate *t = [self findUUID:uuid];
    if (t) [self.templates removeObject:t];
    if ([self.activeUUID isEqualToString:uuid]) self.activeUUID = self.templates[0].uuid;
    [self save];
}

@end

// Trigger key: user-selectable (keyboard remaps mean ⌘ isn't the same physical key for everyone).
static CGEventFlags RZTriggerMask(void) {
    NSString *t = RZStore.shared.trigger;
    if ([t isEqualToString:@"alt"])    return kCGEventFlagMaskAlternate;
    if ([t isEqualToString:@"ctrl"])   return kCGEventFlagMaskControl;
    if ([t isEqualToString:@"fn"])     return kCGEventFlagMaskSecondaryFn;
    if ([t isEqualToString:@"custom"]) return 0; // tracked via key code
    return kCGEventFlagMaskCommand;
}

static NSString *RZTriggerSymbol(void) {
    NSString *t = RZStore.shared.trigger;
    if ([t isEqualToString:@"alt"])  return @"⌥";
    if ([t isEqualToString:@"ctrl"]) return @"⌃";
    if ([t isEqualToString:@"fn"])   return @"🌐 fn";
    return @"⌘";
}

#pragma mark - Coordinates
// CG/AX: origin at the primary screen's TOP-LEFT, y grows down. AppKit: BOTTOM-LEFT, y grows up.

static CGFloat RZPrimaryHeight(void) {
    return NSMaxY(NSScreen.screens.firstObject.frame);
}

static NSPoint RZNSFromCG(CGPoint p) {
    return NSMakePoint(p.x, RZPrimaryHeight() - p.y);
}

static CGRect RZCGFromNS(NSRect r) {
    return CGRectMake(NSMinX(r), RZPrimaryHeight() - NSMaxY(r), NSWidth(r), NSHeight(r));
}

static NSScreen *RZScreenAtCG(CGPoint p) {
    NSPoint ns = RZNSFromCG(p);
    for (NSScreen *s in NSScreen.screens)
        if (NSPointInRect(ns, s.frame)) return s;
    // Nothing matched, so the cursor sits on a max edge. This is not an exotic case:
    // a cursor shoved to the top row arrives as CG y == 0, which converts to exactly
    // NSMaxY(frame), and NSPointInRect treats the max edge as OUTSIDE — so the topmost
    // row of the screen resolved to no screen at all and both the zone overlay and
    // edge snapping went dead precisely where the user aims for a top corner. (The
    // other three edges are unaffected: the cursor clamps to width-1 / height-1 there,
    // never to the exclusive bound.) Retry with the max edges included — strict
    // containment already had its pass, so no screen that owns the point loses it.
    for (NSScreen *s in NSScreen.screens) {
        NSRect f = s.frame;
        if (ns.x >= NSMinX(f) && ns.x <= NSMaxX(f) &&
            ns.y >= NSMinY(f) && ns.y <= NSMaxY(f)) return s;
    }
    return nil;
}

// Placement gap: insets the target rect on all sides (like Rectangle's gaps).
static NSRect RZPaddedNS(NSRect r) {
    CGFloat g = (CGFloat)RZStore.shared.gap;
    if (g > 0 && r.size.width > 3 * g && r.size.height > 3 * g) {
        return NSInsetRect(r, g, g);
    }
    return r;
}

// The zone's AppKit rect on the given screen.
static NSRect RZZoneNSRect(NSDictionary *z, NSScreen *screen) {
    NSRect vf = screen.visibleFrame;
    double zx = [z[@"x"] doubleValue], zy = [z[@"y"] doubleValue];
    double zw = [z[@"w"] doubleValue], zh = [z[@"h"] doubleValue];
    return NSMakeRect(NSMinX(vf) + zx * NSWidth(vf),
                      NSMinY(vf) + (1 - zy - zh) * NSHeight(vf),
                      zw * NSWidth(vf), zh * NSHeight(vf));
}

static NSInteger RZZoneIndexAtCG(CGPoint p, NSScreen *screen, NSArray *zones) {
    NSPoint ns = RZNSFromCG(p);
    NSRect vf = screen.visibleFrame;
    if (NSWidth(vf) <= 0 || NSHeight(vf) <= 0) return -1;
    double rx = (ns.x - NSMinX(vf)) / NSWidth(vf);
    double ry = (NSMaxY(vf) - ns.y) / NSHeight(vf); // ratio from top
    // Zones span visibleFrame, but the cursor roams the whole frame: pushed into the
    // menu bar ry goes negative, over the Dock it passes 1, and nothing matched — the
    // overlay simply stopped highlighting at the exact moment the user shoved the
    // window into a top corner. Clamp instead: the strip above the zones belongs to
    // the top row, the strip below to the bottom row.
    rx = fmin(fmax(rx, 0.0), 1.0);
    ry = fmin(fmax(ry, 0.0), 1.0);
    for (NSUInteger i = 0; i < zones.count; i++) {
        NSDictionary *z = zones[i];
        double zx = [z[@"x"] doubleValue], zy = [z[@"y"] doubleValue];
        double zw = [z[@"w"] doubleValue], zh = [z[@"h"] doubleValue];
        if (rx >= zx && rx <= zx + zw && ry >= zy && ry <= zy + zh) return (NSInteger)i;
    }
    return -1;
}

#pragma mark - Overlay

@interface RZZoneView : NSView
@property (nonatomic, strong) NSArray *zones;
@property (nonatomic) NSInteger hovered;
@property (nonatomic, strong) NSIndexSet *selected;
@property (nonatomic, strong) NSIndexSet *covered; // not selected but covered by the union
@end

@implementation RZZoneView

- (void)drawRect:(NSRect)dirtyRect {
    NSSize sz = self.bounds.size;
    NSColor *accent = NSColor.controlAccentColor;
    for (NSUInteger i = 0; i < self.zones.count; i++) {
        NSDictionary *z = self.zones[i];
        double zx = [z[@"x"] doubleValue], zy = [z[@"y"] doubleValue];
        double zw = [z[@"w"] doubleValue], zh = [z[@"h"] doubleValue];
        NSRect r = NSInsetRect(NSMakeRect(zx * sz.width, (1 - zy - zh) * sz.height,
                                          zw * sz.width, zh * sz.height), 5, 5);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10];
        BOOL isSel = [self.selected containsIndex:i];
        BOOL isCov = !isSel && [self.covered containsIndex:i];
        BOOL isHov = (NSInteger)i == self.hovered;
        if (isSel)      [[accent colorWithAlphaComponent:0.42] setFill];
        else if (isCov) [[accent colorWithAlphaComponent:0.33] setFill];
        else if (isHov) [[accent colorWithAlphaComponent:0.30] setFill];
        else            [[[NSColor grayColor] colorWithAlphaComponent:0.14] setFill];
        [path fill];
        if (isSel || isCov || isHov) {
            [[accent colorWithAlphaComponent:0.95] setStroke];
            path.lineWidth = isSel ? 3 : 2.5;
        } else {
            [[[NSColor grayColor] colorWithAlphaComponent:0.55] setStroke];
            path.lineWidth = 1.5;
        }
        [path stroke];
    }
}

@end

// Footprint showing the single target rect during edge/corner snapping.
@interface RZFootprintView : NSView
@end

@implementation RZFootprintView
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 4)
                                                      xRadius:10 yRadius:10];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.28] setFill];
    [p fill];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.9] setStroke];
    p.lineWidth = 3;
    [p stroke];
}
@end

@interface RZFootprint : NSObject
@property (nonatomic, strong) NSPanel *panel;
+ (instancetype)shared;
- (void)showRect:(NSRect)nsRect;
- (void)hide;
@end

@implementation RZFootprint

+ (instancetype)shared {
    static RZFootprint *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZFootprint new]; });
    return s;
}

- (void)showRect:(NSRect)nsRect {
    if (!self.panel) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:nsRect
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        p.opaque = NO;
        p.backgroundColor = NSColor.clearColor;
        p.hasShadow = NO;
        p.ignoresMouseEvents = YES;
        p.level = NSStatusWindowLevel;
        p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorTransient;
        p.contentView = [RZFootprintView new];
        self.panel = p;
    }
    [self.panel setFrame:nsRect display:YES];
    [self.panel orderFrontRegardless];
}

- (void)hide {
    [self.panel orderOut:nil];
}

@end

@interface RZOverlay : NSObject
@property (nonatomic, strong) NSMutableArray<NSPanel *> *windows;
+ (instancetype)shared;
- (void)showZones:(NSArray *)zones
    hoveredScreen:(NSScreen *)hovScreen
          hovered:(NSInteger)hovered
         selected:(NSDictionary<NSNumber *, NSIndexSet *> *)selected
          covered:(NSDictionary<NSNumber *, NSIndexSet *> *)covered;
- (void)hide;
@end

@implementation RZOverlay

+ (instancetype)shared {
    static RZOverlay *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZOverlay new]; s.windows = [NSMutableArray array]; });
    return s;
}

- (void)showZones:(NSArray *)zones hoveredScreen:(NSScreen *)hovScreen
          hovered:(NSInteger)hovered selected:(NSDictionary<NSNumber *, NSIndexSet *> *)selected
          covered:(NSDictionary<NSNumber *, NSIndexSet *> *)covered {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (self.windows.count != screens.count) {
        for (NSPanel *w in self.windows) [w orderOut:nil];
        [self.windows removeAllObjects];
        for (NSScreen *s in screens) {
            NSPanel *p = [[NSPanel alloc] initWithContentRect:s.visibleFrame
                                                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
            p.opaque = NO;
            p.backgroundColor = NSColor.clearColor;
            p.hasShadow = NO;
            p.ignoresMouseEvents = YES;
            p.level = NSStatusWindowLevel;
            p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorTransient;
            p.contentView = [RZZoneView new];
            [self.windows addObject:p];
        }
    }
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSScreen *s = screens[i];
        NSPanel *p = self.windows[i];
        [p setFrame:s.visibleFrame display:NO];
        RZZoneView *v = (RZZoneView *)p.contentView;
        v.zones = zones;
        v.hovered = (s == hovScreen) ? hovered : -1;
        v.selected = selected[@(i)] ?: [NSIndexSet indexSet];
        v.covered = covered[@(i)] ?: [NSIndexSet indexSet];
        v.needsDisplay = YES;
        [p orderFrontRegardless];
    }
}

- (void)hide {
    for (NSPanel *w in self.windows) [w orderOut:nil];
}

@end

#pragma mark - AX helpers

static AXUIElementRef RZSystemWide(void) {
    static AXUIElementRef sw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sw = AXUIElementCreateSystemWide(); });
    return sw;
}

// Window at position; returned reference is retained, caller releases.
static AXUIElementRef RZWindowAt(CGPoint p) {
    AXUIElementRef el = NULL;
    if (AXUIElementCopyElementAtPosition(RZSystemWide(), (float)p.x, (float)p.y, &el) != kAXErrorSuccess || !el)
        return NULL;
    CFTypeRef win = NULL;
    if (AXUIElementCopyAttributeValue(el, CFSTR("AXWindow"), &win) == kAXErrorSuccess && win) {
        CFRelease(el);
        return (AXUIElementRef)win;
    }
    // Climb up until the role is AXWindow
    AXUIElementRef cur = el;
    for (int i = 0; i < 12 && cur; i++) {
        CFTypeRef role = NULL;
        if (AXUIElementCopyAttributeValue(cur, CFSTR("AXRole"), &role) == kAXErrorSuccess && role) {
            BOOL isWin = CFEqual(role, CFSTR("AXWindow"));
            CFRelease(role);
            if (isWin) return cur;
        }
        CFTypeRef parent = NULL;
        if (AXUIElementCopyAttributeValue(cur, CFSTR("AXParent"), &parent) != kAXErrorSuccess || !parent) break;
        CFRelease(cur);
        cur = (AXUIElementRef)parent;
    }
    if (cur) CFRelease(cur);
    return NULL;
}

static BOOL RZWindowPos(AXUIElementRef win, CGPoint *out) {
    CFTypeRef ref = NULL;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXPosition"), &ref) != kAXErrorSuccess || !ref) return NO;
    BOOL ok = AXValueGetValue((AXValueRef)ref, kAXValueTypeCGPoint, out);
    CFRelease(ref);
    return ok;
}

static BOOL RZWindowFrameGet(AXUIElementRef win, CGRect *out) {
    CGPoint p;
    if (!RZWindowPos(win, &p)) return NO;
    CFTypeRef szRef = NULL;
    CGSize sz = CGSizeZero;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXSize"), &szRef) != kAXErrorSuccess || !szRef) return NO;
    BOOL ok = AXValueGetValue((AXValueRef)szRef, kAXValueTypeCGSize, &sz);
    CFRelease(szRef);
    if (!ok) return NO;
    *out = CGRectMake(p.x, p.y, sz.width, sz.height);
    return YES;
}

static void RZSetWindowFrame(AXUIElementRef win, CGRect rect) {
    CGPoint pt = rect.origin;
    CGSize sz = rect.size;
    AXValueRef pv = AXValueCreate(kAXValueTypeCGPoint, &pt);
    AXValueRef sv = AXValueCreate(kAXValueTypeCGSize, &sz);
    if (pv) AXUIElementSetAttributeValue(win, CFSTR("AXPosition"), pv);
    if (sv) AXUIElementSetAttributeValue(win, CFSTR("AXSize"), sv);
    // Some apps shift position on resize; write position once more
    if (pv) AXUIElementSetAttributeValue(win, CFSTR("AXPosition"), pv);
    if (pv) CFRelease(pv);
    if (sv) CFRelease(sv);
}

#pragma mark - Drag monitor

@interface RZDrag : NSObject
@property (nonatomic) CFMachPortRef tap;
@property (nonatomic) BOOL mouseDownFlag, dragging, triggerDown, overlayActive;
@property (nonatomic) BOOL logTrig;
@property (nonatomic) NSInteger logHover;
@property (nonatomic) BOOL windowMoving, titleGrab, loggedInactive, customDown;
@property (nonatomic) NSInteger acquireAttempts;
@property (nonatomic) CFAbsoluteTime lastAcquire;
// Edge/corner snapping (no trigger key)
@property (nonatomic, copy) NSString *snapKind;
@property (nonatomic) CFAbsoluteTime snapSince;
@property (nonatomic) BOOL snapActive;
@property (nonatomic) NSRect snapTarget;
@property (nonatomic) CGPoint downPos, windowStart;
@property (nonatomic) AXUIElementRef window; // retained
@property (nonatomic, strong) NSScreen *hovScreen;
@property (nonatomic) NSInteger hovIndex;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *selected;
+ (instancetype)shared;
- (void)start;
- (BOOL)running;
@end

static CGEventRef RZTapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);

@implementation RZDrag

+ (instancetype)shared {
    static RZDrag *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [RZDrag new];
        s.selected = [NSMutableDictionary dictionary];
        s.hovIndex = -1;
    });
    return s;
}

- (BOOL)running { return self.tap != NULL; }

- (void)start {
    if (self.tap || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp);
    self.tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                mask, RZTapCB, (__bridge void *)self);
    if (!self.tap) return;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(self.tap, true);
    RZLog(@"event tap installed");
}

- (void)dropWindowRef {
    if (self.window) { CFRelease(self.window); self.window = NULL; }
}

- (void)handleType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self.tap) CGEventTapEnable(self.tap, true);
        return;
    }
    CGPoint p = CGEventGetLocation(event);

    // Modifier state is read from EVERY event: trusting flagsChanged alone
    // misses remapped keys (e.g. 🌐fn→⌘); mouse events always carry the
    // effective modifiers.
    CGEventFlags flags = CGEventGetFlags(event);
    BOOL customTrigger = [RZStore.shared.trigger isEqualToString:@"custom"];
    if (customTrigger && (type == kCGEventKeyDown || type == kCGEventKeyUp)) {
        NSInteger kc = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (kc == RZStore.shared.customKey) {
            self.customDown = (type == kCGEventKeyDown);
        }
    }
    self.triggerDown = customTrigger ? self.customDown : ((flags & RZTriggerMask()) != 0);
    if (self.triggerDown != self.logTrig) {
        self.logTrig = self.triggerDown;
        RZLog(@"flags: trigger=%d (raw=0x%llx)", self.triggerDown, (unsigned long long)flags);
    }
    if (!self.triggerDown && self.overlayActive) [self endSessionPlacing:NO];

    switch (type) {
        case kCGEventFlagsChanged:
            break;
        case kCGEventLeftMouseDown:
            self.mouseDownFlag = YES;
            self.dragging = NO;
            self.downPos = p;
            self.windowMoving = NO;
            self.titleGrab = NO;
            self.loggedInactive = NO;
            self.acquireAttempts = 0;
            self.lastAcquire = 0;
            [self dropWindowRef];
            self.window = RZWindowAt(p);
            if (self.window) {
                CGPoint wp;
                if (RZWindowPos(self.window, &wp)) {
                    self.windowStart = wp;
                    // Grabbed by the title strip? (top ~34px of the window)
                    CFTypeRef szRef = NULL;
                    CGSize wsz = CGSizeZero;
                    if (AXUIElementCopyAttributeValue(self.window, CFSTR("AXSize"), &szRef) == kAXErrorSuccess && szRef) {
                        AXValueGetValue((AXValueRef)szRef, kAXValueTypeCGSize, &wsz);
                        CFRelease(szRef);
                    }
                    self.titleGrab = (p.y - wp.y) >= 0 && (p.y - wp.y) <= 34 &&
                                     p.x >= wp.x && p.x <= wp.x + wsz.width;
                    if (self.triggerDown)
                        RZLog(@"mouseDown: window found pos=(%.0f,%.0f) titlebar=%d",
                              wp.x, wp.y, self.titleGrab);
                } else {
                    [self dropWindowRef];
                    if (self.triggerDown) RZLog(@"mouseDown: could not read window position");
                }
            } else if (self.triggerDown) {
                RZLog(@"mouseDown: no window at cursor");
            }
            break;
        case kCGEventLeftMouseDragged: {
            if (!self.mouseDownFlag) break;
            if (!self.dragging && hypot(p.x - self.downPos.x, p.y - self.downPos.y) > 6)
                self.dragging = YES;
            if (!self.dragging) break;
            // If the window wasn't acquired on mouseDown, keep retrying during
            // the drag (Rectangle's approach: 20 attempts, 0.1s apart)
            if (!self.window && self.acquireAttempts < 20) {
                CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
                if (nowT - self.lastAcquire > 0.1) {
                    self.lastAcquire = nowT;
                    self.acquireAttempts++;
                    self.window = RZWindowAt(p);
                    if (self.window) {
                        CGPoint wp;
                        if (RZWindowPos(self.window, &wp)) {
                            self.windowStart = wp;
                            RZLog(@"window acquired mid-drag (attempt %ld)",
                                  (long)self.acquireAttempts);
                        } else {
                            [self dropWindowRef];
                        }
                    }
                }
            }
            // Is the window actually moving? No threshold, checked on every
            // event (Rectangle's approach): any change from the start means yes.
            if (!self.windowMoving && self.window) {
                CGPoint now;
                if (RZWindowPos(self.window, &now) &&
                    (fabs(now.x - self.windowStart.x) > 1 || fabs(now.y - self.windowStart.y) > 1)) {
                    self.windowMoving = YES;
                    RZLog(@"window is moving (AX confirmed)");
                }
            }
            [self updateWithMouse:p];
            [self updateSnapWithMouse:p];
            break;
        }
        case kCGEventLeftMouseUp: {
            BOOL place = self.overlayActive;
            BOOL snap = self.snapActive;
            self.mouseDownFlag = NO;
            self.dragging = NO;
            if (place) {
                [self clearSnap];
                [self endSessionPlacing:YES];
            } else if (snap) {
                [self placeSnap];
            } else {
                [self clearSnap];
                [self dropWindowRef];
            }
            break;
        }
        default:
            break;
    }
}

- (void)updateWithMouse:(CGPoint)p {
    BOOL active = self.dragging && self.triggerDown && self.window &&
                  (self.windowMoving || self.titleGrab);
    if (!active) {
        if (self.dragging && self.triggerDown && !self.loggedInactive) {
            self.loggedInactive = YES;
            RZLog(@"session not started: window=%d moving=%d titlebar=%d",
                  self.window != NULL, self.windowMoving, self.titleGrab);
        }
        if (self.overlayActive && !self.triggerDown) [self endSessionPlacing:NO];
        return;
    }
    if (!self.overlayActive) {
        RZLog(@"session started: template=%@ zones=%lu", RZStore.shared.active.name,
              (unsigned long)RZStore.shared.active.zones.count);
        self.logHover = -2;
        [self clearSnap]; // trigger overlay takes priority: hide the edge footprint
    }
    self.overlayActive = YES;

    NSScreen *screen = RZScreenAtCG(p);
    NSInteger idx = -1;
    NSArray *zones = RZStore.shared.active.zones;
    if (screen) idx = RZZoneIndexAtCG(p, screen, zones);
    self.hovScreen = screen;
    self.hovIndex = idx;

    if (idx != self.logHover) {
        self.logHover = idx;
        RZLog(@"hover: zone=%ld", (long)idx);
    }
    if (screen && idx >= 0) {
        NSNumber *sid = @([NSScreen.screens indexOfObject:screen]);
        // Every zone swept while the trigger is held joins the selection — no second
        // modifier. Accumulation starts when the key goes down, so the path taken
        // before that does not pollute the pick; releasing the key clears everything.
        // Selection stays on one screen: crossing displays would union into a rect
        // spanning both, which is never what the sweep meant.
        if (self.selected.count && !self.selected[sid]) {
            [self.selected removeAllObjects];
            RZLog(@"selection reset: moved to screen %@", sid);
        }
        NSMutableIndexSet *set = self.selected[sid] ?: [NSMutableIndexSet indexSet];
        if (![set containsIndex:(NSUInteger)idx]) RZLog(@"added: zone=%ld", (long)idx);
        [set addIndex:(NSUInteger)idx];
        self.selected[sid] = set;
    }

    NSDictionary *sel = [self.selected copy];
    NSInteger hi = self.hovIndex;
    NSScreen *hs = self.hovScreen;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlayActive) return;
        // Zones inside the selection's union rect also light up even when not
        // selected: with an L-shaped pick, the user sees the real coverage before dropping.
        NSMutableDictionary *covered = [NSMutableDictionary dictionary];
        NSArray<NSScreen *> *screens = NSScreen.screens;
        NSRect uni = NSZeroRect;
        BOOL has = NO;
        for (NSNumber *sid in sel) {
            NSUInteger si = sid.unsignedIntegerValue;
            if (si >= screens.count) continue;
            NSIndexSet *set = sel[sid];
            for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i]) {
                if (i >= zones.count) continue;
                NSRect r = RZZoneNSRect(zones[i], screens[si]);
                uni = has ? NSUnionRect(uni, r) : r;
                has = YES;
            }
        }
        if (has) {
            NSRect probe = NSInsetRect(uni, 3, 3);
            for (NSUInteger si = 0; si < screens.count; si++) {
                NSMutableIndexSet *cov = [NSMutableIndexSet indexSet];
                for (NSUInteger i = 0; i < zones.count; i++) {
                    NSRect inter = NSIntersectionRect(RZZoneNSRect(zones[i], screens[si]), probe);
                    if (inter.size.width > 4 && inter.size.height > 4) [cov addIndex:i];
                }
                if (cov.count) covered[@(si)] = cov;
            }
        }
        [RZOverlay.shared showZones:zones hoveredScreen:hs hovered:hi selected:sel covered:covered];
    });
}

// Edge/corner snapping: while dragging without the trigger key, resting the
// cursor at a screen edge shows the target footprint after a short dwell;
// dropping places the window. Corners: quarters · top: maximize · bottom:
// thirds (two-thirds between bands) · sides: halves.
- (void)updateSnapWithMouse:(CGPoint)p {
    BOOL eligible = self.dragging && self.window && !self.overlayActive && !self.triggerDown &&
                    (self.windowMoving || self.titleGrab);
    if (!eligible) {
        if (self.snapActive || self.snapKind) [self clearSnap];
        return;
    }
    NSScreen *screen = RZScreenAtCG(p);
    if (!screen) { [self clearSnap]; return; }

    NSPoint ns = RZNSFromCG(p);
    NSRect f = screen.frame;
    CGFloat m = 16;
    // The top edge is not reachable the way the other three are: macOS stops a
    // dragged window at the menu bar, and the cursor rides on the title strip, so
    // it stalls ~menuH+34 px below the screen top and a plain 16 px band never
    // fires — `left`/`right` wins instead and a corner push reads as a half.
    // Corners get the full title-strip allowance; the maximize band stays tight so
    // it cannot be hit by accident (a corner also demands a side edge, so it can).
    CGFloat menuH = NSMaxY(f) - NSMaxY(screen.visibleFrame);
    CGFloat topM = menuH + m;
    CGFloat topCornerM = menuH + 34; // 34 = the title-strip depth used by titleGrab
    BOOL left = ns.x - NSMinX(f) <= m;
    BOOL right = NSMaxX(f) - ns.x <= m;
    BOOL top = NSMaxY(f) - ns.y <= topM;
    BOOL topCorner = NSMaxY(f) - ns.y <= topCornerM;
    BOOL bottom = ns.y - NSMinY(f) <= m;

    NSDictionary *zone = nil;
    NSString *kind = nil;
    if (topCorner && left)    { zone = RZZone(0, 0, .5, .5);   kind = @"tl"; }
    else if (topCorner && right) { zone = RZZone(.5, 0, .5, .5);  kind = @"tr"; }
    else if (bottom && left)  { zone = RZZone(0, .5, .5, .5);   kind = @"bl"; }
    else if (bottom && right) { zone = RZZone(.5, .5, .5, .5);  kind = @"br"; }
    else if (top)             { zone = RZZone(0, 0, 1, 1);      kind = @"top"; }
    else if (bottom) {
        NSRect vf = screen.visibleFrame;
        double rx = (ns.x - NSMinX(vf)) / MAX(NSWidth(vf), 1);
        if (rx < 0.20)       { zone = RZZone(0, 0, 1.0 / 3, 1);       kind = @"b0"; }
        else if (rx < 0.40)  { zone = RZZone(0, 0, 2.0 / 3, 1);       kind = @"b01"; }
        else if (rx <= 0.60) { zone = RZZone(1.0 / 3, 0, 1.0 / 3, 1); kind = @"b1"; }
        else if (rx < 0.80)  { zone = RZZone(1.0 / 3, 0, 2.0 / 3, 1); kind = @"b12"; }
        else                 { zone = RZZone(2.0 / 3, 0, 1.0 / 3, 1); kind = @"b2"; }
    }
    else if (left)            { zone = RZZone(0, 0, .5, 1);    kind = @"left"; }
    else if (right)           { zone = RZZone(.5, 0, .5, 1);   kind = @"right"; }

    if (!kind) { [self clearSnap]; return; }

    if (![kind isEqualToString:self.snapKind]) {
        self.snapKind = kind;
        self.snapSince = CFAbsoluteTimeGetCurrent();
    }
    if (CFAbsoluteTimeGetCurrent() - self.snapSince < 0.12) return; // short dwell

    NSRect target = RZZoneNSRect(zone, screen);
    self.snapTarget = target;
    if (!self.snapActive) RZLog(@"edge snap: %@", kind);
    self.snapActive = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.snapActive) [RZFootprint.shared showRect:target];
    });
}

- (void)clearSnap {
    self.snapKind = nil;
    self.snapActive = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [RZFootprint.shared hide];
    });
}

- (void)placeSnap {
    AXUIElementRef win = self.window;
    self.window = NULL;
    NSRect target = self.snapTarget;
    self.snapKind = nil;
    self.snapActive = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [RZFootprint.shared hide];
        if (win) {
            RZLog(@"edge snap placed: %@", NSStringFromRect(target));
            RZSetWindowFrame(win, RZCGFromNS(RZPaddedNS(target)));
            CFRelease(win);
        }
    });
}

- (void)endSessionPlacing:(BOOL)place {
    AXUIElementRef win = self.window; // transfer ownership to the block
    self.window = NULL;
    NSDictionary *sel = [self.selected copy];
    NSScreen *hs = self.hovScreen;
    NSInteger hi = self.hovIndex;

    self.overlayActive = NO;
    [self.selected removeAllObjects];
    self.hovScreen = nil;
    self.hovIndex = -1;
    self.windowMoving = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [RZOverlay.shared hide];
        if (place && win) {
            NSArray *zones = RZStore.shared.active.zones;
            NSArray<NSScreen *> *screens = NSScreen.screens;
            NSRect uni = NSZeroRect;
            BOOL has = NO;
            for (NSNumber *sid in sel) {
                NSUInteger si = sid.unsignedIntegerValue;
                if (si >= screens.count) continue;
                NSIndexSet *set = sel[sid];
                for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i]) {
                    if (i >= zones.count) continue;
                    NSRect r = RZZoneNSRect(zones[i], screens[si]);
                    uni = has ? NSUnionRect(uni, r) : r;
                    has = YES;
                }
            }
            if (!has && hs && hi >= 0 && hi < (NSInteger)zones.count) {
                uni = RZZoneNSRect(zones[hi], hs);
                has = YES;
            }
            RZLog(@"dropped: place=%d selection=%@ target=%@", has,
                  sel.count ? sel : @"(hover)", has ? NSStringFromRect(uni) : @"-");
            if (has) RZSetWindowFrame(win, RZCGFromNS(RZPaddedNS(uni)));
        }
        if (win) CFRelease(win);
    });
}

@end

static CGEventRef RZTapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    RZDrag *drag = (__bridge RZDrag *)refcon;
    [drag handleType:type event:event];
    return event;
}

#pragma mark - Shortcuts

// Actions: order is used in the UI and in hotkey ids.
static NSArray<NSArray *> *RZActions(void) {
    return @[
        @[@"maximize",  @"Maximize (fill visible area)"],
        @[@"almostMax", @"Almost maximize (~90%, centered)"],
        @[@"displayNext", @"Move to next display"],
        @[@"grid21", @"Half cell (2×1)"],
        @[@"grid31", @"Third cell (3×1)"],
        @[@"twoThirds", @"Two thirds (⅔ width)"],
        @[@"cornerHop", @"Corner hop (grow, shrink, next corner)"],
        @[@"grid41", @"Quarter column (4×1)"],
        @[@"grid14", @"Quarter row (1×4)"],
        @[@"grid22", @"Quarter cell (2×2)"],
        @[@"grid24", @"Eighth cell (2×4)"],
        @[@"grid32", @"Sixth cell (3×2)"],
        @[@"grid42", @"Eighth cell (4×2)"],
    ];
}

static NSString *RZKeyName(int keyCode) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{@0: @"A", @1: @"S", @2: @"D", @3: @"F", @4: @"H", @5: @"G", @6: @"Z",
                  @7: @"X", @8: @"C", @9: @"V", @11: @"B", @12: @"Q", @13: @"W", @14: @"E",
                  @15: @"R", @16: @"Y", @17: @"T", @18: @"1", @19: @"2", @20: @"3", @21: @"4",
                  @22: @"6", @23: @"5", @24: @"=", @25: @"9", @26: @"7", @27: @"-", @28: @"8",
                  @29: @"0", @30: @"]", @31: @"O", @32: @"U", @33: @"[", @34: @"I", @35: @"P",
                  @36: @"↩", @37: @"L", @38: @"J", @39: @"'", @40: @"K", @41: @";", @42: @"\\",
                  @43: @",", @44: @"/", @45: @"N", @46: @"M", @47: @".", @48: @"⇥", @49: @"Space",
                  @50: @"`", @51: @"⌫", @53: @"⎋", @96: @"F5", @97: @"F6", @98: @"F7", @99: @"F3",
                  @100: @"F8", @101: @"F9", @103: @"F11", @109: @"F10", @111: @"F12",
                  @115: @"Home", @116: @"PgUp", @117: @"⌦", @118: @"F4", @119: @"End",
                  @120: @"F2", @121: @"PgDn", @122: @"F1", @123: @"←", @124: @"→",
                  @125: @"↓", @126: @"↑"};
    });
    return names[@(keyCode)] ?: [NSString stringWithFormat:@"key %d", keyCode];
}

static NSString *RZComboName(NSDictionary *combo) {
    if (!combo) return @"—";
    NSUInteger m = [combo[@"mods"] unsignedIntegerValue];
    NSMutableString *s = [NSMutableString string];
    if (m & NSEventModifierFlagControl)  [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption)   [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift)    [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand)  [s appendString:@"⌘"];
    [s appendString:RZKeyName([combo[@"key"] intValue])];
    return s;
}

static UInt32 RZCarbonMods(NSUInteger nsMods) {
    UInt32 m = 0;
    if (nsMods & NSEventModifierFlagCommand) m |= cmdKey;
    if (nsMods & NSEventModifierFlagShift)   m |= shiftKey;
    if (nsMods & NSEventModifierFlagOption)  m |= optionKey;
    if (nsMods & NSEventModifierFlagControl) m |= controlKey;
    return m;
}

@interface RZHotkeys : NSObject
@property (nonatomic, strong) NSMutableArray *refs; // NSValue<EventHotKeyRef>
@property (nonatomic) AXUIElementRef lastWin;       // cycle memory (retained)
@property (nonatomic) NSInteger lastIndex;
@property (nonatomic, copy) NSString *lastAction;   // which cycle owns the memory (template/gridNN)
+ (instancetype)shared;
- (void)reload;
- (void)resetCycle;
@end

static OSStatus RZHotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData);

@implementation RZHotkeys

+ (instancetype)shared {
    static RZHotkeys *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [RZHotkeys new];
        s.refs = [NSMutableArray array];
        s.lastIndex = -1;
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallEventHandler(GetEventDispatcherTarget(), RZHotKeyHandler, 1, &spec, NULL, NULL);
    });
    return s;
}

- (void)reload {
    for (NSValue *v in self.refs) UnregisterEventHotKey(v.pointerValue);
    [self.refs removeAllObjects];

    NSArray *actions = RZActions();
    for (NSUInteger i = 0; i < actions.count; i++) {
        NSDictionary *combo = RZStore.shared.shortcuts[actions[i][0]];
        if (!combo) continue;
        EventHotKeyID hkid = {'RZHK', (UInt32)i};
        EventHotKeyRef ref = NULL;
        OSStatus st = RegisterEventHotKey([combo[@"key"] unsignedIntValue],
                                          RZCarbonMods([combo[@"mods"] unsignedIntegerValue]),
                                          hkid, GetEventDispatcherTarget(), 0, &ref);
        if (st == noErr && ref) [self.refs addObject:[NSValue valueWithPointer:ref]];
    }
}

- (void)resetCycle {
    if (self.lastWin) { CFRelease(self.lastWin); self.lastWin = NULL; }
    self.lastIndex = -1;
    self.lastAction = nil;
}

// Focused window of the frontmost app; returned retained.
- (AXUIElementRef)focusedWindow {
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!app) return NULL;
    AXUIElementRef appEl = AXUIElementCreateApplication(app.processIdentifier);
    if (!appEl) return NULL;
    CFTypeRef win = NULL;
    AXUIElementCopyAttributeValue(appEl, CFSTR("AXFocusedWindow"), &win);
    CFRelease(appEl);
    return (AXUIElementRef)win;
}

// Screen containing the window (by its center); falls back to the primary screen.
- (NSScreen *)screenOf:(AXUIElementRef)win {
    CGPoint pos;
    CFTypeRef szRef = NULL;
    CGSize size = CGSizeZero;
    if (RZWindowPos(win, &pos) &&
        AXUIElementCopyAttributeValue(win, CFSTR("AXSize"), &szRef) == kAXErrorSuccess && szRef) {
        AXValueGetValue((AXValueRef)szRef, kAXValueTypeCGSize, &size);
        CFRelease(szRef);
        CGPoint center = CGPointMake(pos.x + size.width / 2, pos.y + size.height / 2);
        NSScreen *s = RZScreenAtCG(center);
        if (s) return s;
    }
    return NSScreen.screens.firstObject;
}

// Cycle within the given zone list: pressing again with the same window and the
// same scope advances to the next cell; a scope change restarts the cycle.
- (void)cycleWindow:(AXUIElementRef)win zones:(NSArray *)zones scope:(NSString *)scope forward:(BOOL)fwd {
    NSInteger n = (NSInteger)zones.count;
    if (n == 0) return;
    BOOL same = self.lastWin && CFEqual(self.lastWin, win) &&
                [scope isEqualToString:self.lastAction ?: @""];
    NSInteger idx = (same && self.lastIndex >= 0) ? (self.lastIndex + (fwd ? 1 : -1) + n) % n
                                                  : (fwd ? 0 : n - 1);
    NSScreen *screen = [self screenOf:win];
    RZSetWindowFrame(win, RZCGFromNS(RZPaddedNS(RZZoneNSRect(zones[idx], screen))));
    if (self.lastWin) CFRelease(self.lastWin);
    self.lastWin = (AXUIElementRef)CFRetain(win);
    self.lastIndex = idx;
    self.lastAction = scope;
}

- (void)perform:(NSString *)actionID {
    AXUIElementRef win = [self focusedWindow];
    if (!win) return;

    if ([actionID isEqualToString:@"maximize"]) {
        NSScreen *screen = [self screenOf:win];
        RZSetWindowFrame(win, RZCGFromNS(RZPaddedNS(screen.visibleFrame)));
        [self resetCycle];
    } else if ([actionID isEqualToString:@"displayNext"]) {
        // Move the window to the next display, preserving its relative position
        NSArray<NSScreen *> *screens = NSScreen.screens;
        CGRect wf;
        if (screens.count > 1 && RZWindowFrameGet(win, &wf)) {
            NSScreen *cur = [self screenOf:win];
            NSUInteger ci = [screens indexOfObject:cur];
            NSScreen *next = screens[(ci + 1) % screens.count];
            CGRect cvf = RZCGFromNS(cur.visibleFrame);
            CGRect nvf = RZCGFromNS(next.visibleFrame);
            if (cvf.size.width > 0 && cvf.size.height > 0) {
                double rx = (wf.origin.x - cvf.origin.x) / cvf.size.width;
                double ry = (wf.origin.y - cvf.origin.y) / cvf.size.height;
                double rw = MIN(1.0, wf.size.width / cvf.size.width);
                double rh = MIN(1.0, wf.size.height / cvf.size.height);
                RZSetWindowFrame(win, CGRectMake(nvf.origin.x + rx * nvf.size.width,
                                                 nvf.origin.y + ry * nvf.size.height,
                                                 rw * nvf.size.width, rh * nvf.size.height));
            }
        }
        [self resetCycle];
    } else if ([actionID isEqualToString:@"almostMax"]) {
        // Almost maximize: ~90% of the visible area, centered
        NSScreen *screen = [self screenOf:win];
        NSRect vf = screen.visibleFrame;
        RZSetWindowFrame(win, RZCGFromNS(NSInsetRect(vf, vf.size.width * 0.05, vf.size.height * 0.05)));
        [self resetCycle];
    } else if ([actionID isEqualToString:@"cycleNext"] || [actionID isEqualToString:@"cyclePrev"]) {
        [self cycleWindow:win zones:RZStore.shared.active.zones scope:@"template"
                  forward:[actionID isEqualToString:@"cycleNext"]];
    } else if ([actionID isEqualToString:@"twoThirds"]) {
        // ⅔ width, full height: cycles between left ⅔ and right ⅔
        NSArray *cells = @[RZZone(0, 0, 2.0 / 3, 1), RZZone(1.0 / 3, 0, 2.0 / 3, 1)];
        [self cycleWindow:win zones:cells scope:actionID forward:YES];
    } else if ([actionID isEqualToString:@"cornerHop"]) {
        // Corner hop, small to large: sixth (⅓×½) → quarter (½×½) → ⅔×½ →
        // 6 boxes of a 4×3 layout (¾×⅔); then the next corner (TL → TR → BL → BR).
        static NSArray *cells;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            double sizes[4][2] = {{1.0 / 3, .5}, {.5, .5}, {2.0 / 3, .5}, {3.0 / 4, 2.0 / 3}};
            int corners[4][2] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}}; // (isRight, isBottom)
            NSMutableArray *a = [NSMutableArray array];
            for (int c = 0; c < 4; c++) {
                for (int s = 0; s < 4; s++) {
                    double w = sizes[s][0], h = sizes[s][1];
                    [a addObject:RZZone(corners[c][0] ? 1 - w : 0,
                                        corners[c][1] ? 1 - h : 0, w, h)];
                }
            }
            cells = a;
        });
        [self cycleWindow:win zones:cells scope:actionID forward:YES];
    } else if ([actionID hasPrefix:@"grid"] && actionID.length == 6) {
        // Fixed matrix cells (template-independent): each press moves to the next cell
        NSInteger cols = [[actionID substringWithRange:NSMakeRange(4, 1)] integerValue];
        NSInteger rows = [[actionID substringWithRange:NSMakeRange(5, 1)] integerValue];
        if (cols >= 1 && rows >= 1) {
            NSMutableArray *cells = [NSMutableArray array];
            for (NSInteger r = 0; r < rows; r++) {
                for (NSInteger col = 0; col < cols; col++) {
                    [cells addObject:RZZone((double)col / cols, (double)r / rows,
                                            1.0 / cols, 1.0 / rows)];
                }
            }
            [self cycleWindow:win zones:cells scope:actionID forward:YES];
        }
    } else if ([actionID hasPrefix:@"zone"]) {
        NSInteger idx = [[actionID substringFromIndex:4] integerValue] - 1;
        NSArray *zones = RZStore.shared.active.zones;
        if (idx >= 0 && idx < (NSInteger)zones.count) {
            NSScreen *screen = [self screenOf:win];
            RZSetWindowFrame(win, RZCGFromNS(RZPaddedNS(RZZoneNSRect(zones[idx], screen))));
            if (self.lastWin) CFRelease(self.lastWin);
            self.lastWin = (AXUIElementRef)CFRetain(win);
            self.lastIndex = idx;
            self.lastAction = @"template";
        }
    }
    CFRelease(win);
}

@end

static OSStatus RZHotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    EventHotKeyID hkid;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hkid), NULL, &hkid) != noErr || hkid.signature != 'RZHK')
        return eventNotHandledErr;
    NSArray *actions = RZActions();
    if (hkid.id < actions.count) {
        [RZHotkeys.shared perform:actions[hkid.id][0]];
    }
    return noErr;
}

#pragma mark - Template editor

@interface RZEditorCanvas : NSView
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *zones;
@property (nonatomic) NSInteger selectedZone;
@property (nonatomic) int mode; // 0 none, 1 move, 2 resize
@property (nonatomic) int rdx, rdy; // resize direction: -1 left/top, 1 right/bottom
@property (nonatomic) NSPoint dragStart;
@property (nonatomic, strong) NSDictionary *zoneStart;
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation RZEditorCanvas

- (BOOL)isFlipped { return YES; } // top-left origin: matches the zone model
- (BOOL)acceptsFirstResponder { return YES; }

- (NSRect)rectOf:(NSDictionary *)z {
    NSSize s = self.bounds.size;
    return NSMakeRect([z[@"x"] doubleValue] * s.width, [z[@"y"] doubleValue] * s.height,
                      [z[@"w"] doubleValue] * s.width, [z[@"h"] doubleValue] * s.height);
}

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    [NSColor.separatorColor setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, .5, .5)] stroke];

    NSColor *accent = NSColor.controlAccentColor;
    for (NSUInteger i = 0; i < self.zones.count; i++) {
        NSRect r = NSInsetRect([self rectOf:self.zones[i]], 2, 2);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
        BOOL sel = (NSInteger)i == self.selectedZone;
        [(sel ? [accent colorWithAlphaComponent:0.38] : [accent colorWithAlphaComponent:0.16]) setFill];
        [path fill];
        [(sel ? accent : [accent colorWithAlphaComponent:0.5]) setStroke];
        path.lineWidth = sel ? 2.5 : 1.5;
        [path stroke];

        NSString *label = [NSString stringWithFormat:@"%lu", i + 1];
        NSDictionary *attrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
                                NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.6]};
        NSSize ls = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(NSMidX(r) - ls.width / 2, NSMidY(r) - ls.height / 2)
            withAttributes:attrs];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.dragStart = p;
    CGFloat margin = 8;

    // Hit-test the selected zone first, then the rest in order
    NSMutableArray *order = [NSMutableArray array];
    if (self.selectedZone >= 0 && self.selectedZone < (NSInteger)self.zones.count)
        [order addObject:@(self.selectedZone)];
    for (NSUInteger i = 0; i < self.zones.count; i++)
        if ((NSInteger)i != self.selectedZone) [order addObject:@(i)];

    for (NSNumber *ni in order) {
        NSUInteger i = ni.unsignedIntegerValue;
        NSRect r = [self rectOf:self.zones[i]];
        if (!NSPointInRect(p, NSInsetRect(r, -margin, -margin))) continue;
        self.selectedZone = (NSInteger)i;
        self.zoneStart = [self.zones[i] copy];
        NSRect inner = NSInsetRect(r, margin, margin);
        if (NSPointInRect(p, inner)) {
            self.mode = 1;
        } else {
            self.mode = 2;
            self.rdx = p.x < NSMinX(inner) ? -1 : (p.x > NSMaxX(inner) ? 1 : 0);
            self.rdy = p.y < NSMinY(inner) ? -1 : (p.y > NSMaxY(inner) ? 1 : 0);
        }
        self.needsDisplay = YES;
        return;
    }
    self.selectedZone = -1;
    self.mode = 0;
    self.needsDisplay = YES;
}

static double RZSnap(double v) { return round(v * 100) / 100; }

- (void)mouseDragged:(NSEvent *)event {
    if (self.selectedZone < 0 || self.selectedZone >= (NSInteger)self.zones.count || self.mode == 0) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    double ddx = (p.x - self.dragStart.x) / self.bounds.size.width;
    double ddy = (p.y - self.dragStart.y) / self.bounds.size.height;
    double sx = [self.zoneStart[@"x"] doubleValue], sy = [self.zoneStart[@"y"] doubleValue];
    double sw = [self.zoneStart[@"w"] doubleValue], sh = [self.zoneStart[@"h"] doubleValue];
    double minS = 0.05;
    double x = sx, y = sy, w = sw, h = sh;

    if (self.mode == 1) {
        x = MIN(MAX(0, sx + ddx), 1 - w);
        y = MIN(MAX(0, sy + ddy), 1 - h);
    } else {
        if (self.rdx == -1) {
            double nx = MIN(MAX(0, sx + ddx), sx + sw - minS);
            w = sw + (sx - nx);
            x = nx;
        } else if (self.rdx == 1) {
            w = MIN(MAX(minS, sw + ddx), 1 - sx);
        }
        if (self.rdy == -1) {
            double ny = MIN(MAX(0, sy + ddy), sy + sh - minS);
            h = sh + (sy - ny);
            y = ny;
        } else if (self.rdy == 1) {
            h = MIN(MAX(minS, sh + ddy), 1 - sy);
        }
    }
    NSMutableDictionary *z = self.zones[self.selectedZone];
    z[@"x"] = @(RZSnap(x));
    z[@"y"] = @(RZSnap(y));
    z[@"w"] = @(RZSnap(w));
    z[@"h"] = @(RZSnap(h));
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    if (self.mode != 0 && self.onChange) self.onChange();
    self.mode = 0;
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 && self.selectedZone >= 0 &&
        self.selectedZone < (NSInteger)self.zones.count) { // delete
        [self.zones removeObjectAtIndex:self.selectedZone];
        self.selectedZone = self.zones.count ? 0 : -1;
        self.needsDisplay = YES;
        if (self.onChange) self.onChange();
        return;
    }
    [super keyDown:event];
}

@end

@class RZApp;
static RZApp *gApp;

@interface RZEditor : NSObject
@property (nonatomic, strong) NSView *view;
@property (nonatomic, strong) RZEditorCanvas *canvas;
@property (nonatomic, strong) NSPopUpButton *popup;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *colsField;
@property (nonatomic, strong) NSTextField *rowsField;
@property (nonatomic, strong) NSTextField *gapField;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) RZTemplate *editing;
+ (instancetype)shared;
- (NSView *)viewRefreshed;
@end

@interface RZApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *permissionTimer;
- (void)rebuildMenu;
@end

@implementation RZEditor

+ (instancetype)shared {
    static RZEditor *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZEditor new]; });
    return s;
}

- (NSButton *)button:(NSString *)title action:(SEL)sel {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

- (NSView *)viewRefreshed {
    if (!self.view) [self build];
    self.editing = RZStore.shared.active;
    [self reloadPopup];
    [self loadEditing];
    return self.view;
}

- (void)build {
    // Window height is computed from content: a fixed height used to clip the
    // help text under the canvas into "little blue dots".
    CGFloat W0 = 840, pad0 = 12;
    NSSize vfs = NSScreen.screens.firstObject.visibleFrame.size;
    CGFloat ch0 = (W0 - 2 * pad0) * (vfs.height / MAX(vfs.width, 1));
    NSRect frame = NSMakeRect(0, 0, W0, ch0 + 154);
    NSView *c = [[NSView alloc] initWithFrame:frame];

    CGFloat W = frame.size.width, pad = 12;

    self.popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(pad, frame.size.height - 42, 180, 26) pullsDown:NO];
    self.popup.target = self;
    self.popup.action = @selector(templatePicked);
    [c addSubview:self.popup];

    self.nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(pad + 188, frame.size.height - 41, 170, 24)];
    self.nameField.placeholderString = @"Template name";
    [c addSubview:self.nameField];

    CGFloat bx = pad + 366;
    for (NSArray *def in @[@[@"New Template", NSStringFromSelector(@selector(newTemplate))],
                           @[@"Duplicate", NSStringFromSelector(@selector(copyTemplate))],
                           @[@"Delete Template", NSStringFromSelector(@selector(deleteTemplate))]]) {
        NSButton *b = [self button:def[0] action:NSSelectorFromString(def[1])];
        [b sizeToFit];
        NSRect bf = b.frame;
        bf.origin = NSMakePoint(bx, frame.size.height - 43);
        b.frame = bf;
        [c addSubview:b];
        bx += bf.size.width + 6;
    }

    // Canvas: aspect ratio of the main screen
    NSSize vf = NSScreen.screens.firstObject.visibleFrame.size;
    CGFloat cw = W - 2 * pad;
    CGFloat ch = cw * (vf.height / MAX(vf.width, 1));
    self.canvas = [[RZEditorCanvas alloc] initWithFrame:NSMakeRect(pad, frame.size.height - 54 - ch, cw, ch)];
    self.canvas.zones = [NSMutableArray array];
    self.canvas.selectedZone = -1;
    [c addSubview:self.canvas];

    CGFloat by = frame.size.height - 54 - ch - 36;
    CGFloat bx2 = pad;
    for (NSArray *def in @[@[@"+ Zone", NSStringFromSelector(@selector(addZone))],
                           @[@"Delete Zone", NSStringFromSelector(@selector(removeZone))]]) {
        NSButton *b = [self button:def[0] action:NSSelectorFromString(def[1])];
        [b sizeToFit];
        NSRect bf = b.frame;
        bf.origin = NSMakePoint(bx2, by);
        b.frame = bf;
        [c addSubview:b];
        bx2 += bf.size.width + 8;
    }

    // Grid definition: enter columns × rows, build an evenly divided grid
    bx2 += 10;
    NSTextField *colLabel = [NSTextField labelWithString:@"Cols"];
    colLabel.frame = NSMakeRect(bx2, by + 5, 42, 18);
    [c addSubview:colLabel];
    bx2 += 44;
    self.colsField = [[NSTextField alloc] initWithFrame:NSMakeRect(bx2, by + 1, 34, 24)];
    self.colsField.stringValue = @"3";
    [c addSubview:self.colsField];
    bx2 += 40;
    NSTextField *rowLabel = [NSTextField labelWithString:@"Rows"];
    rowLabel.frame = NSMakeRect(bx2, by + 5, 36, 18);
    [c addSubview:rowLabel];
    bx2 += 38;
    self.rowsField = [[NSTextField alloc] initWithFrame:NSMakeRect(bx2, by + 1, 34, 24)];
    self.rowsField.stringValue = @"2";
    [c addSubview:self.rowsField];
    bx2 += 42;
    NSButton *gridBtn = [self button:@"Apply Grid" action:@selector(applyGrid)];
    [gridBtn sizeToFit];
    NSRect gf = gridBtn.frame;
    gf.origin = NSMakePoint(bx2, by);
    gridBtn.frame = gf;
    [c addSubview:gridBtn];
    bx2 += gf.size.width + 14;

    NSButton *saveBtn = [self button:@"Save & Use" action:@selector(saveTemplate)];
    saveBtn.keyEquivalent = @"\r";
    [saveBtn sizeToFit];
    NSRect sf = saveBtn.frame;
    sf.origin = NSMakePoint(bx2, by);
    saveBtn.frame = sf;
    [c addSubview:saveBtn];
    self.saveButton = saveBtn;
    bx2 += sf.size.width + 14;

    NSTextField *gapLabel = [NSTextField labelWithString:@"Gap"];
    gapLabel.frame = NSMakeRect(bx2, by + 5, 46, 18);
    [c addSubview:gapLabel];
    bx2 += 48;
    self.gapField = [[NSTextField alloc] initWithFrame:NSMakeRect(bx2, by + 1, 36, 24)];
    self.gapField.target = self;
    self.gapField.action = @selector(gapChanged);
    [c addSubview:self.gapField];
    bx2 += 40;
    NSTextField *pxLabel = [NSTextField labelWithString:@"px"];
    pxLabel.frame = NSMakeRect(bx2, by + 5, 22, 18);
    [c addSubview:pxLabel];

    __weak typeof(self) ws = self;
    self.canvas.onChange = ^{ [ws markDirty]; };

    NSTextField *help = [NSTextField wrappingLabelWithString:
        @"Drag zone: move · drag edge/corner: resize · click: select · delete key: remove zone. "
        @"Saving makes the template active; hold the trigger key while dragging a window to show zones. Sweep across zones to select several — release the key before dropping to cancel."];
    help.frame = NSMakeRect(pad, 8, W - 2 * pad, by - 14);
    help.font = [NSFont systemFontOfSize:11];
    help.textColor = NSColor.secondaryLabelColor;
    [c addSubview:help];

    self.view = c;
}

- (void)reloadPopup {
    [self.popup removeAllItems];
    NSInteger sel = 0, i = 0;
    for (RZTemplate *t in RZStore.shared.templates) {
        BOOL isActive = [t.uuid isEqualToString:RZStore.shared.activeUUID];
        // NSPopUpButton dedupes equal titles; add menu items directly to keep indexes stable
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:isActive ? [t.name stringByAppendingString:@"  ✓"] : t.name
                                                      action:nil keyEquivalent:@""];
        [self.popup.menu addItem:item];
        if ([t.uuid isEqualToString:self.editing.uuid]) sel = i;
        i++;
    }
    [self.popup selectItemAtIndex:sel];
}

- (void)loadEditing {
    self.nameField.stringValue = self.editing.name;
    self.canvas.zones = RZCopyZones(self.editing.zones);
    self.canvas.selectedZone = self.canvas.zones.count ? 0 : -1;
    self.canvas.needsDisplay = YES;
    self.gapField.integerValue = RZStore.shared.gap;
    [self clearDirty];
}

- (void)markDirty {
    self.saveButton.title = @"● Save & Use";
}

- (void)clearDirty {
    self.saveButton.title = @"Save & Use";
}

- (void)gapChanged {
    RZStore.shared.gap = MAX(0, MIN(40, self.gapField.integerValue));
    self.gapField.integerValue = RZStore.shared.gap;
    [RZStore.shared save];
}

- (void)templatePicked {
    NSInteger i = self.popup.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)RZStore.shared.templates.count) return;
    self.editing = RZStore.shared.templates[i];
    // Selecting a template makes it active
    RZStore.shared.activeUUID = self.editing.uuid;
    [RZStore.shared save];
    [RZHotkeys.shared resetCycle];
    [self reloadPopup];
    [self loadEditing];
}

- (void)newTemplate {
    self.editing = RZMakeTemplate(@"New Template", @[RZZone(.1, .1, .35, .6)]);
    [RZStore.shared upsert:self.editing];
    [self reloadPopup];
    [self loadEditing];
    [gApp rebuildMenu];
}

- (void)copyTemplate {
    self.editing = RZMakeTemplate([self.editing.name stringByAppendingString:@" copy"],
                                  self.canvas.zones);
    [RZStore.shared upsert:self.editing];
    [self reloadPopup];
    [self loadEditing];
    [gApp rebuildMenu];
}

- (void)deleteTemplate {
    [RZStore.shared removeUUID:self.editing.uuid];
    self.editing = RZStore.shared.active;
    [self reloadPopup];
    [self loadEditing];
    [gApp rebuildMenu];
}

- (void)addZone {
    [self.canvas.zones addObject:RZZone(.3, .3, .4, .4)];
    self.canvas.selectedZone = (NSInteger)self.canvas.zones.count - 1;
    self.canvas.needsDisplay = YES;
    [self markDirty];
}

- (void)removeZone {
    NSInteger s = self.canvas.selectedZone;
    if (s >= 0 && s < (NSInteger)self.canvas.zones.count) {
        [self.canvas.zones removeObjectAtIndex:s];
        self.canvas.selectedZone = self.canvas.zones.count ? 0 : -1;
        self.canvas.needsDisplay = YES;
        [self markDirty];
    }
}

- (void)applyGrid {
    NSInteger cols = MAX(1, MIN(8, self.colsField.integerValue));
    NSInteger rows = MAX(1, MIN(8, self.rowsField.integerValue));
    self.colsField.integerValue = cols;
    self.rowsField.integerValue = rows;
    [self.canvas.zones removeAllObjects];
    for (NSInteger r = 0; r < rows; r++) {
        for (NSInteger col = 0; col < cols; col++) {
            [self.canvas.zones addObject:RZZone((double)col / cols, (double)r / rows,
                                                1.0 / cols, 1.0 / rows)];
        }
    }
    self.canvas.selectedZone = 0;
    self.canvas.needsDisplay = YES;
    // Auto-name from the grid unless the user typed a custom name
    NSString *cur = self.nameField.stringValue;
    BOOL autoName = cur.length == 0 || [cur isEqualToString:@"New Template"] ||
        [cur rangeOfString:@"^\\d+×\\d+ (Grid)$" options:NSRegularExpressionSearch].location != NSNotFound;
    if (autoName) {
        self.nameField.stringValue = [NSString stringWithFormat:@"%ld×%ld Grid", (long)cols, (long)rows];
    }
    [self markDirty];
}

- (void)saveTemplate {
    if (!self.canvas.zones.count) return;
    self.editing.name = self.nameField.stringValue.length ? self.nameField.stringValue : @"Untitled";
    self.editing.zones = RZCopyZones(self.canvas.zones);
    [RZStore.shared upsert:self.editing];
    RZStore.shared.activeUUID = self.editing.uuid;
    [RZStore.shared save];
    [RZHotkeys.shared resetCycle];
    [self reloadPopup];
    [self clearDirty];
    [gApp rebuildMenu];
}

@end

#pragma mark - Shortcuts UI

// Mini preview for shortcut rows: grid with first cell filled, or a fill preview
// (cols=0) showing how much of the screen maximize/almost-maximize covers.
@interface RZMiniGridView : NSView
@property (nonatomic) NSInteger cols, rows;
@property (nonatomic) NSInteger fillSpan; // how many columns the first cell spans (default 1)
@property (nonatomic) CGFloat fillInset;  // used when cols=0
@property (nonatomic) BOOL arrowMode;     // two displays + arrow (move to next display)
@end

@implementation RZMiniGridView

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    if (self.arrowMode) {
        // two displays with an arrow: window moves to the next display
        CGFloat bw = b.size.width * 0.34;
        NSRect l = NSMakeRect(NSMinX(b), NSMinY(b) + 2, bw, b.size.height - 4);
        NSRect r = NSMakeRect(NSMaxX(b) - bw, NSMinY(b) + 2, bw, b.size.height - 4);
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.7] setStroke];
        NSBezierPath *lb = [NSBezierPath bezierPathWithRect:l];
        lb.lineWidth = 1;
        [lb stroke];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.55] setFill];
        NSRectFillUsingOperation(NSInsetRect(r, 1, 1), NSCompositingOperationSourceOver);
        NSBezierPath *arrow = [NSBezierPath new];
        arrow.lineWidth = 1.5;
        CGFloat cy = NSMidY(b), ax0 = NSMaxX(l) + 2, ax1 = NSMinX(r) - 2;
        [arrow moveToPoint:NSMakePoint(ax0, cy)];
        [arrow lineToPoint:NSMakePoint(ax1, cy)];
        [arrow moveToPoint:NSMakePoint(ax1 - 3, cy + 3)];
        [arrow lineToPoint:NSMakePoint(ax1, cy)];
        [arrow lineToPoint:NSMakePoint(ax1 - 3, cy - 3)];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.9] setStroke];
        [arrow stroke];
        return;
    }
    if (self.cols < 1 || self.rows < 1) {
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.7] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:b];
        border.lineWidth = 1;
        [border stroke];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.55] setFill];
        NSRectFillUsingOperation(NSInsetRect(b, b.size.width * self.fillInset,
                                             b.size.height * self.fillInset),
                                 NSCompositingOperationSourceOver);
        return;
    }
    CGFloat cw = b.size.width / self.cols, ch = b.size.height / self.rows;
    NSInteger span = MAX(1, self.fillSpan);

    [[NSColor.controlAccentColor colorWithAlphaComponent:0.55] setFill];
    NSRectFillUsingOperation(NSMakeRect(NSMinX(b), NSMaxY(b) - ch, cw * span, ch), NSCompositingOperationSourceOver);

    [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.7] setStroke];
    NSBezierPath *p = [NSBezierPath new];
    p.lineWidth = 1;
    [p appendBezierPathWithRect:b];
    for (NSInteger i = 1; i < self.cols; i++) {
        [p moveToPoint:NSMakePoint(NSMinX(b) + i * cw, NSMinY(b))];
        [p lineToPoint:NSMakePoint(NSMinX(b) + i * cw, NSMaxY(b))];
    }
    for (NSInteger j = 1; j < self.rows; j++) {
        [p moveToPoint:NSMakePoint(NSMinX(b), NSMinY(b) + j * ch)];
        [p lineToPoint:NSMakePoint(NSMaxX(b), NSMinY(b) + j * ch)];
    }
    [p stroke];
}

@end

@interface RZShortcutsUI : NSObject
@property (nonatomic, strong) NSView *view;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *comboButtons;
@property (nonatomic, copy) NSString *recordingAction;
@property (nonatomic, strong) id keyMonitor;
+ (instancetype)shared;
- (NSView *)viewRefreshed;
- (void)cancelRecording;
@end

@implementation RZShortcutsUI

+ (instancetype)shared {
    static RZShortcutsUI *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZShortcutsUI new]; s.comboButtons = [NSMutableDictionary dictionary]; });
    return s;
}

- (NSView *)viewRefreshed {
    if (!self.view) [self build];
    [self refreshTitles];
    return self.view;
}

- (void)cancelRecording {
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; self.keyMonitor = nil; }
    self.recordingAction = nil;
    if (self.view) [self refreshTitles];
}

- (void)build {
    NSArray *actions = RZActions();
    CGFloat rowH = 30, pad = 14;
    CGFloat h = pad * 2 + rowH * actions.count + 46;
    NSRect frame = NSMakeRect(0, 0, 560, h);
    NSView *c = [[NSView alloc] initWithFrame:frame];

    NSTextField *info = [NSTextField wrappingLabelWithString:
        @"Click a shortcut button, then press your key combo (⎋ to cancel). "
        @"Cycling: pressing the same combo again moves the window to the next cell of that grid."];
    info.font = [NSFont systemFontOfSize:11];
    info.textColor = NSColor.secondaryLabelColor;
    info.frame = NSMakeRect(pad, h - 40, frame.size.width - 2 * pad, 30);
    [c addSubview:info];

    CGFloat y = h - 52 - rowH;
    for (NSArray *a in actions) {
        NSString *aid = a[0];
        NSTextField *label = [NSTextField labelWithString:a[1]];
        label.frame = NSMakeRect(pad, y + 5, 278, 20);
        label.font = [NSFont systemFontOfSize:12];
        [c addSubview:label];

        if (([aid hasPrefix:@"grid"] && aid.length == 6) ||
            [aid isEqualToString:@"maximize"] || [aid isEqualToString:@"almostMax"] ||
            [aid isEqualToString:@"twoThirds"] || [aid isEqualToString:@"displayNext"] ||
            [aid isEqualToString:@"cornerHop"]) {
            RZMiniGridView *mini = [[RZMiniGridView alloc] initWithFrame:NSMakeRect(296, y + 2, 36, 22)];
            if ([aid isEqualToString:@"displayNext"]) {
                mini.arrowMode = YES;
            } else if ([aid isEqualToString:@"cornerHop"]) {
                mini.cols = 2;
                mini.rows = 2;
            } else if ([aid hasPrefix:@"grid"]) {
                mini.cols = [[aid substringWithRange:NSMakeRange(4, 1)] integerValue];
                mini.rows = [[aid substringWithRange:NSMakeRange(5, 1)] integerValue];
            } else if ([aid isEqualToString:@"twoThirds"]) {
                mini.cols = 3;
                mini.rows = 1;
                mini.fillSpan = 2;
            } else {
                mini.cols = 0;
                mini.fillInset = [aid isEqualToString:@"maximize"] ? 0.04 : 0.15;
            }
            [c addSubview:mini];
        }

        NSButton *combo = [NSButton buttonWithTitle:@"—" target:self action:@selector(recordPressed:)];
        combo.bezelStyle = NSBezelStyleRounded;
        combo.frame = NSMakeRect(340, y, 140, 26);
        combo.identifier = aid;
        [c addSubview:combo];
        self.comboButtons[aid] = combo;

        NSButton *clear = [NSButton buttonWithTitle:@"✕" target:self action:@selector(clearPressed:)];
        clear.bezelStyle = NSBezelStyleRounded;
        clear.frame = NSMakeRect(486, y, 32, 26);
        clear.identifier = aid;
        [c addSubview:clear];

        y -= rowH;
    }
    self.view = c;
}

- (void)refreshTitles {
    for (NSString *aid in self.comboButtons) {
        NSDictionary *combo = RZStore.shared.shortcuts[aid];
        NSString *t = [self.recordingAction isEqualToString:aid] ? @"press keys…" : RZComboName(combo);
        self.comboButtons[aid].title = t;
    }
}

- (void)recordPressed:(NSButton *)sender {
    self.recordingAction = sender.identifier;
    [self refreshTitles];
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    __weak typeof(self) ws = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *e) {
        [ws captureEvent:e];
        return nil; // swallow the event
    }];
}

- (void)captureEvent:(NSEvent *)e {
    NSString *aid = self.recordingAction;
    if (!aid) return;
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; self.keyMonitor = nil; }
    self.recordingAction = nil;
    NSUInteger mods = e.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagShift |
         NSEventModifierFlagOption | NSEventModifierFlagControl);
    // Only a BARE ⎋ cancels; combos like ⌘⎋ are recorded
    if (e.keyCode != 53 || mods != 0) {
        RZStore.shared.shortcuts[aid] = @{@"key": @(e.keyCode), @"mods": @(mods)};
        [RZStore.shared save];
        [RZHotkeys.shared reload];
    }
    [self refreshTitles];
}

- (void)clearPressed:(NSButton *)sender {
    [RZStore.shared.shortcuts removeObjectForKey:sender.identifier];
    [RZStore.shared save];
    [RZHotkeys.shared reload];
    [self refreshTitles];
}

@end

#pragma mark - Settings window

@interface RZSettings : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTabView *tabs;
@property (nonatomic, strong) NSMutableArray<NSButton *> *triggerRadios;
@property (nonatomic, strong) id keyMonitor;
+ (instancetype)shared;
- (void)open;
@end

@implementation RZSettings

+ (instancetype)shared {
    static RZSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RZSettings new]; });
    return s;
}

- (void)open {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (!self.window) [self build];
    [self.tabs tabViewItemAtIndex:0].view = [RZEditor.shared viewRefreshed];
    [self.tabs tabViewItemAtIndex:2].view = [RZShortcutsUI.shared viewRefreshed];
    [self refreshTriggerRadios];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)build {
    NSView *editorView = [RZEditor.shared viewRefreshed];
    NSView *shortcutView = [RZShortcutsUI.shared viewRefreshed];
    NSSize es = editorView.frame.size;
    CGFloat maxH = MAX(es.height, shortcutView.frame.size.height);
    NSRect frame = NSMakeRect(0, 0, es.width + 28, maxH + 74);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"RectZones — Settings";
    w.delegate = self;
    w.releasedWhenClosed = NO;

    self.tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(((NSView *)w.contentView).bounds, 10, 10)];

    NSTabViewItem *t1 = [[NSTabViewItem alloc] initWithIdentifier:@"templates"];
    t1.label = @"Template Editor";
    t1.view = editorView;
    [self.tabs addTabViewItem:t1];

    NSTabViewItem *t2 = [[NSTabViewItem alloc] initWithIdentifier:@"trigger"];
    t2.label = @"Trigger Key";
    t2.view = [self buildTriggerView];
    [self.tabs addTabViewItem:t2];

    NSTabViewItem *t3 = [[NSTabViewItem alloc] initWithIdentifier:@"shortcuts"];
    t3.label = @"Shortcuts";
    t3.view = [RZShortcutsUI.shared viewRefreshed];
    [self.tabs addTabViewItem:t3];

    [w.contentView addSubview:self.tabs];
    self.window = w;
}

- (NSArray<NSString *> *)triggerKeys {
    return @[@"cmd", @"alt", @"ctrl", @"fn", @"custom"];
}

- (NSView *)buildTriggerView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 340)];
    self.triggerRadios = [NSMutableArray array];
    NSArray *titles = @[@"⌘ Command", @"⌥ Option", @"⌃ Control", @"🌐 fn (Globe)", @"Custom key"];
    CGFloat y = 270;
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:titles[i] target:self action:@selector(triggerPicked:)];
        r.frame = NSMakeRect(28, y, 250, 22);
        r.tag = (NSInteger)i;
        [v addSubview:r];
        [self.triggerRadios addObject:r];
        if (i == 4) {
            NSButton *rec = [NSButton buttonWithTitle:@"Choose Key" target:self action:@selector(recordTriggerKey:)];
            rec.bezelStyle = NSBezelStyleRounded;
            rec.frame = NSMakeRect(288, y - 3, 90, 26);
            [v addSubview:rec];
        }
        y -= 32;
    }
    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Trigger key: zones appear while you drag a window holding this key. "
        @"If you remap modifier keys in macOS settings, pick the modifier your key PRODUCES — "
        @"e.g. if your 🌐 key emits ⌘, the correct choice is '⌘ Command'. "
        @"Custom key: hold a non-modifier key (like F13) while dragging; "
        @"letters/digits may type into the app while dragging, so function keys are recommended."];
    note.frame = NSMakeRect(28, 24, 464, 96);
    note.font = [NSFont systemFontOfSize:11];
    note.textColor = NSColor.secondaryLabelColor;
    [v addSubview:note];
    return v;
}

- (void)refreshTriggerRadios {
    NSArray *keys = [self triggerKeys];
    for (NSButton *r in self.triggerRadios) {
        NSString *key = keys[(NSUInteger)r.tag];
        if ([key isEqualToString:@"custom"]) {
            r.title = RZStore.shared.customKey > 0
                ? [NSString stringWithFormat:@"Custom key: %@", RZKeyName((int)RZStore.shared.customKey)]
                : @"Custom key: —";
        }
        r.state = [RZStore.shared.trigger isEqualToString:key]
                  ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)triggerPicked:(NSButton *)sender {
    NSString *key = [self triggerKeys][(NSUInteger)sender.tag];
    if ([key isEqualToString:@"custom"] && RZStore.shared.customKey <= 0) {
        [self recordTriggerKey:sender]; // have them pick a key first
        return;
    }
    RZStore.shared.trigger = key;
    [RZStore.shared save];
    [self refreshTriggerRadios];
}

- (void)recordTriggerKey:(NSButton *)sender {
    sender.title = @"press a key…";
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    __weak typeof(self) ws = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *e) {
        [ws captureTriggerKey:e button:sender];
        return nil;
    }];
}

- (void)captureTriggerKey:(NSEvent *)e button:(NSButton *)b {
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; self.keyMonitor = nil; }
    b.title = @"Choose Key";
    if (e.keyCode != 53) { // ⎋ = cancel
        RZStore.shared.customKey = e.keyCode;
        RZStore.shared.trigger = @"custom";
        [RZStore.shared save];
    }
    [self refreshTriggerRadios];
}

- (void)windowWillClose:(NSNotification *)notification {
    [RZShortcutsUI.shared cancelRecording];
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; self.keyMonitor = nil; }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

@end

#pragma mark - Application

@implementation RZApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Single instance: stale copies used to hold the tap without seeing settings changes
    for (NSRunningApplication *ra in [NSRunningApplication
             runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]) {
        if (ra.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
            RZLog(@"terminating stale instance pid=%d", ra.processIdentifier);
            [ra forceTerminate];
        }
    }
    RZLog(@"launched pid=%d trusted=%d template=%@ trigger=%@",
          NSProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted(),
          RZStore.shared.active.name, RZStore.shared.trigger);

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = AXIsProcessTrusted() ? @"▦" : @"▦⚠";
    [self rebuildMenu];

    // Trigger the system dialog if Accessibility permission is missing
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);

    [RZHotkeys.shared reload];
    [RZDrag.shared start];
    if (!RZDrag.shared.running) {
        __block NSInteger polls = 0;
        self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2.5 repeats:YES block:^(NSTimer *t) {
            [RZDrag.shared start];
            if (RZDrag.shared.running) {
                [t invalidate];
                self.statusItem.button.title = @"▦";
                RZLog(@"permission granted, layer active");
                [self rebuildMenu];
            } else {
                self.statusItem.button.title = @"▦⚠";
                if (++polls % 10 == 0) RZLog(@"still no permission (poll %ld)", (long)polls);
            }
        }];
    }
}

- (void)rebuildMenu {
    NSMenu *menu = [NSMenu new];

    if (!AXIsProcessTrusted()) {
        NSMenuItem *warn = [[NSMenuItem alloc] initWithTitle:@"⚠︎ Waiting for Accessibility permission…"
                                                      action:@selector(openAXSettings) keyEquivalent:@""];
        warn.target = self;
        [menu addItem:warn];
        [menu addItem:NSMenuItem.separatorItem];
    }

    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                      action:@selector(openSettings) keyEquivalent:@","];
    settings.target = self;
    [menu addItem:settings];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]];

    self.statusItem.menu = menu;
}

- (void)openSettings {
    [RZSettings.shared open];
}

- (void)openAXSettings {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

@end

#ifndef RZ_SNAPSHOT
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        gApp = [RZApp new];
        app.delegate = gApp;
        [app run];
    }
    return 0;
}
#endif

#ifdef RZ_SNAPSHOT
#pragma mark - README screenshot generator
// Renders the real UI views to PNG offscreen (for README/docs).
// Derleme: clang -DRZ_SNAPSHOT -fobjc-arc src/main.m -o /tmp/rz-snap \
//          -framework Cocoa -framework Carbon -framework ApplicationServices

@interface RZSettings (RZSnap)
- (NSView *)buildTriggerView;
@end

@interface RZSnapBG : NSView
@property (nonatomic) NSRect winRel; // temsili pencerenin oransal konumu (boşsa merkez)
@end

@implementation RZSnapBG
- (void)drawRect:(NSRect)dirtyRect {
    NSGradient *g = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithCalibratedRed:0.36 green:0.43 blue:0.56 alpha:1]
                  endingColor:[NSColor colorWithCalibratedRed:0.17 green:0.21 blue:0.31 alpha:1]];
    [g drawInRect:self.bounds angle:-90];
    // mock window being dragged
    NSRect rel = NSIsEmptyRect(self.winRel) ? NSMakeRect(0.31, 0.27, 0.36, 0.42) : self.winRel;
    NSRect w = NSMakeRect(self.bounds.size.width * rel.origin.x,
                          self.bounds.size.height * rel.origin.y,
                          self.bounds.size.width * rel.size.width,
                          self.bounds.size.height * rel.size.height);
    [[NSColor colorWithCalibratedWhite:0.98 alpha:0.93] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:w xRadius:12 yRadius:12] fill];
    NSRect tb = NSMakeRect(w.origin.x, NSMaxY(w) - 34, w.size.width, 34);
    [[NSColor colorWithCalibratedWhite:0.88 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tb xRadius:12 yRadius:12] fill];
    NSArray *lights = @[NSColor.systemRedColor, NSColor.systemYellowColor, NSColor.systemGreenColor];
    for (int i = 0; i < 3; i++) {
        [[lights[i] colorWithAlphaComponent:0.9] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(tb.origin.x + 12 + i * 20, NSMidY(tb) - 6, 12, 12)] fill];
    }
}
@end

// Settings views are transparent; on a dark page their labels vanish.
// Wrap them on an opaque light card before rendering.
@interface RZSnapCard : NSView
@end

@implementation RZSnapCard
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedWhite:0.96 alpha:1] setFill];
    NSRectFill(self.bounds);
}
@end

static void RZSnapWrite(NSView *v, NSString *path) {
    v.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:v.frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.contentView = v;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    fprintf(stdout, "wrote: %s\n", path.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *out = argc > 1 ? @(argv[1]) : @"docs";
        [NSFileManager.defaultManager createDirectoryAtPath:out
                                withIntermediateDirectories:YES attributes:nil error:nil];

        // Hero shot: drag + zones + swept multi-zone selection preview
        NSRect hero = NSMakeRect(0, 0, 1200, 750);
        NSView *heroV = [[NSView alloc] initWithFrame:hero];
        [heroV addSubview:[[RZSnapBG alloc] initWithFrame:hero]];
        RZZoneView *zones = [[RZZoneView alloc] initWithFrame:hero];
        double u = 1.0 / 3.0;
        zones.zones = @[RZZone(0, 0, u, .5), RZZone(u, 0, u, .5), RZZone(2 * u, 0, u, .5),
                        RZZone(0, .5, u, .5), RZZone(u, .5, u, .5), RZZone(2 * u, .5, u, .5)];
        zones.hovered = 4;
        NSMutableIndexSet *sel = [NSMutableIndexSet indexSet];
        [sel addIndex:3];
        [sel addIndex:4];
        zones.selected = sel;
        zones.covered = [NSIndexSet indexSet];
        [heroV addSubview:zones];
        RZSnapWrite(heroV, [out stringByAppendingPathComponent:@"shot-zones.png"]);

        // Drag & snap: Left Wide şablonu, büyük bölge hover'da
        NSRect fs = NSMakeRect(0, 0, 1000, 625);
        NSView *dragV = [[NSView alloc] initWithFrame:fs];
        [dragV addSubview:[[RZSnapBG alloc] initWithFrame:fs]];
        RZZoneView *dragZones = [[RZZoneView alloc] initWithFrame:fs];
        dragZones.zones = @[RZZone(0, 0, .62, 1), RZZone(.62, 0, .38, .5), RZZone(.62, .5, .38, .5)];
        dragZones.hovered = 0;
        dragZones.selected = [NSIndexSet indexSet];
        dragZones.covered = [NSIndexSet indexSet];
        [dragV addSubview:dragZones];
        RZSnapWrite(dragV, [out stringByAppendingPathComponent:@"shot-drag.png"]);

        // Süpürme: 2×2'de L-seçim, dördüncü hücre kaplama önizlemesiyle yanıyor
        NSView *spanV = [[NSView alloc] initWithFrame:fs];
        [spanV addSubview:[[RZSnapBG alloc] initWithFrame:fs]];
        RZZoneView *spanZones = [[RZZoneView alloc] initWithFrame:fs];
        spanZones.zones = @[RZZone(0, 0, .5, .5), RZZone(.5, 0, .5, .5),
                            RZZone(0, .5, .5, .5), RZZone(.5, .5, .5, .5)];
        NSMutableIndexSet *spanSel = [NSMutableIndexSet indexSet];
        [spanSel addIndex:0];
        [spanSel addIndex:1];
        [spanSel addIndex:2];
        spanZones.selected = spanSel;
        spanZones.hovered = 2;
        spanZones.covered = [NSIndexSet indexSetWithIndex:3];
        [spanV addSubview:spanZones];
        RZSnapWrite(spanV, [out stringByAppendingPathComponent:@"shot-span.png"]);

        // Edge snap: köşeye ittirilen pencere + çeyrek footprint
        NSView *edgeV = [[NSView alloc] initWithFrame:fs];
        RZSnapBG *edgeBG = [[RZSnapBG alloc] initWithFrame:fs];
        edgeBG.winRel = NSMakeRect(0.05, 0.42, 0.34, 0.4);
        [edgeV addSubview:edgeBG];
        RZFootprintView *fp = [[RZFootprintView alloc] initWithFrame:
            NSMakeRect(0, fs.size.height * 0.5, fs.size.width * 0.5, fs.size.height * 0.5)];
        [edgeV addSubview:fp];
        RZSnapWrite(edgeV, [out stringByAppendingPathComponent:@"shot-edge.png"]);

        NSArray *panels = @[
            @[[RZEditor.shared viewRefreshed], @"shot-editor.png"],
            @[[RZShortcutsUI.shared viewRefreshed], @"shot-shortcuts.png"],
            @[[RZSettings.shared buildTriggerView], @"shot-trigger.png"],
        ];
        for (NSArray *pair in panels) {
            NSView *v = pair[0];
            CGFloat pad = 20;
            RZSnapCard *card = [[RZSnapCard alloc] initWithFrame:
                NSMakeRect(0, 0, v.frame.size.width + 2 * pad, v.frame.size.height + 2 * pad)];
            v.frame = NSMakeRect(pad, pad, v.frame.size.width, v.frame.size.height);
            [card addSubview:v];
            RZSnapWrite(card, [out stringByAppendingPathComponent:pair[1]]);
        }
    }
    return 0;
}
#endif
