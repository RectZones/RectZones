// Tests for src/rzcore.m — the pure half of RectZones.
//
// Deliberately dependency-free: no XCTest, no SwiftPM, no Xcode project. This is
// a plain executable built by the same clang invocation as the app, so it runs
// anywhere the app builds, needs no display and no Accessibility grant, and
// leaves the reproducible app build untouched. `./test.sh` builds and runs it;
// a non-zero exit means something failed.

#import "rzcore.h"

#pragma mark - Harness

static int gChecks = 0, gFails = 0;
static const char *gGroup = "";

static void group(const char *name) { gGroup = name; }

static void ok(BOOL cond, const char *what) {
    gChecks++;
    if (!cond) { gFails++; fprintf(stderr, "FAIL  [%s] %s\n", gGroup, what); }
}

static void eqd(double got, double want, const char *what) {
    gChecks++;
    // Ratio math on screen sizes; anything looser would hide real drift.
    if (fabs(got - want) > 1e-9) {
        gFails++;
        fprintf(stderr, "FAIL  [%s] %s: got %.10f want %.10f\n", gGroup, what, got, want);
    }
}

static void eqi(NSInteger got, NSInteger want, const char *what) {
    gChecks++;
    if (got != want) {
        gFails++;
        fprintf(stderr, "FAIL  [%s] %s: got %ld want %ld\n", gGroup, what, (long)got, (long)want);
    }
}

static void eqrect(NSRect got, NSRect want, const char *what) {
    gChecks++;
    if (fabs(got.origin.x - want.origin.x) > 1e-9 || fabs(got.origin.y - want.origin.y) > 1e-9 ||
        fabs(got.size.width - want.size.width) > 1e-9 || fabs(got.size.height - want.size.height) > 1e-9) {
        gFails++;
        fprintf(stderr, "FAIL  [%s] %s:\n        got  {%g %g %g %g}\n        want {%g %g %g %g}\n",
                gGroup, what, got.origin.x, got.origin.y, got.size.width, got.size.height,
                want.origin.x, want.origin.y, want.size.width, want.size.height);
    }
}

static NSArray<NSValue *> *frames(NSRect a) { return @[[NSValue valueWithRect:a]]; }
static NSArray<NSValue *> *frames2(NSRect a, NSRect b) {
    return @[[NSValue valueWithRect:a], [NSValue valueWithRect:b]];
}

#pragma mark - Zone geometry

static void test_zone_rects(void) {
    group("zone geometry");
    NSRect vf = NSMakeRect(0, 0, 1000, 800);

    // Zones are ratios with a TOP-LEFT origin; AppKit rects have a BOTTOM-LEFT
    // origin, so a zone at y=0 must come back at the TOP of the frame.
    eqrect(RZZoneRectInFrame(RZZone(0, 0, .5, 1), vf), NSMakeRect(0, 0, 500, 800), "left half");
    eqrect(RZZoneRectInFrame(RZZone(.5, 0, .5, 1), vf), NSMakeRect(500, 0, 500, 800), "right half");
    eqrect(RZZoneRectInFrame(RZZone(0, 0, .5, .5), vf), NSMakeRect(0, 400, 500, 400), "top-left quarter sits high");
    eqrect(RZZoneRectInFrame(RZZone(0, .5, .5, .5), vf), NSMakeRect(0, 0, 500, 400), "bottom-left quarter sits low");
    eqrect(RZZoneRectInFrame(RZZone(0, 0, 1, 1), vf), vf, "full-screen zone equals the frame");

    // Thirds: the preset uses 1/3, which is not representable in binary. The
    // three columns must still tile the frame without a seam or an overlap.
    double u = 1.0 / 3.0;
    NSRect c0 = RZZoneRectInFrame(RZZone(0, 0, u, 1), vf);
    NSRect c1 = RZZoneRectInFrame(RZZone(u, 0, u, 1), vf);
    NSRect c2 = RZZoneRectInFrame(RZZone(2 * u, 0, u, 1), vf);
    eqd(NSMinX(c0), 0, "first third starts at the left edge");
    eqd(NSMaxX(c0), NSMinX(c1), "no seam between first and second third");
    eqd(NSMaxX(c1), NSMinX(c2), "no seam between second and third third");
    eqd(NSMaxX(c2), 1000, "third third ends at the right edge");

    // A screen that is not at the origin: the menu bar and Dock inset the visible
    // frame, and a second display can sit at a negative origin.
    NSRect off = NSMakeRect(-1920, 25, 1920, 1055);
    eqrect(RZZoneRectInFrame(RZZone(0, 0, 1, 1), off), off, "offset frame maps identically");
    eqrect(RZZoneRectInFrame(RZZone(.5, 0, .5, .5), off),
           NSMakeRect(-960, 25 + 1055.0 / 2, 960, 1055.0 / 2), "offset top-right quarter");

    // Fractional point sizes: scaled displays produce non-integer visible frames.
    NSRect frac = NSMakeRect(0, 0, 1512.5, 944.5);
    eqd(NSWidth(RZZoneRectInFrame(RZZone(0, 0, .5, 1), frac)), 1512.5 / 2, "half of a fractional width");
    eqd(NSMaxY(RZZoneRectInFrame(RZZone(0, 0, 1, 1), frac)), 944.5, "fractional frame keeps its top edge");

    group("zone geometry / degenerate");
    NSRect zero = NSMakeRect(0, 0, 0, 0);
    eqrect(RZZoneRectInFrame(RZZone(0, 0, 1, 1), zero), zero, "zero-size frame yields a zero rect");
    // A zone wider than the frame is a config the editor cannot produce but a
    // hand-edited file can. It should scale, not trap.
    eqd(NSWidth(RZZoneRectInFrame(RZZone(0, 0, 2, 1), vf)), 2000, "oversized zone scales rather than clamping");
    eqd(NSWidth(RZZoneRectInFrame(RZZone(0, 0, -1, 1), vf)), -1000, "negative width passes through as-is");
    // Missing keys read as 0 through -doubleValue; the result must be a zero rect
    // rather than garbage.
    eqrect(RZZoneRectInFrame(@{}, vf), NSMakeRect(0, 800, 0, 0), "empty zone dictionary is inert");
}

#pragma mark - Hit testing

static void test_zone_hit(void) {
    group("zone hit testing");
    NSRect vf = NSMakeRect(0, 0, 1000, 800);
    NSArray *halves = @[RZZone(0, 0, .5, 1), RZZone(.5, 0, .5, 1)];

    eqi(RZZoneIndexAtPoint(NSMakePoint(100, 400), vf, halves), 0, "left half");
    eqi(RZZoneIndexAtPoint(NSMakePoint(900, 400), vf, halves), 1, "right half");

    NSArray *quad = @[RZZone(0, 0, .5, .5), RZZone(.5, 0, .5, .5),
                      RZZone(0, .5, .5, .5), RZZone(.5, .5, .5, .5)];
    // AppKit y grows up, zone y grows down: a high y is the TOP row.
    eqi(RZZoneIndexAtPoint(NSMakePoint(250, 700), vf, quad), 0, "top-left quadrant");
    eqi(RZZoneIndexAtPoint(NSMakePoint(750, 700), vf, quad), 1, "top-right quadrant");
    eqi(RZZoneIndexAtPoint(NSMakePoint(250, 100), vf, quad), 2, "bottom-left quadrant");
    eqi(RZZoneIndexAtPoint(NSMakePoint(750, 100), vf, quad), 3, "bottom-right quadrant");

    group("zone hit testing / out of bounds");
    // Zones span the visible frame but the cursor roams the whole screen. Above
    // the frame is the menu bar, below is the Dock; both must clamp into the
    // nearest row instead of matching nothing — this is exactly where a user
    // aiming at a top corner ends up.
    eqi(RZZoneIndexAtPoint(NSMakePoint(250, 5000), vf, quad), 0, "far above clamps to the top row");
    eqi(RZZoneIndexAtPoint(NSMakePoint(250, -5000), vf, quad), 2, "far below clamps to the bottom row");
    eqi(RZZoneIndexAtPoint(NSMakePoint(-5000, 700), vf, quad), 0, "far left clamps to the left column");
    eqi(RZZoneIndexAtPoint(NSMakePoint(5000, 700), vf, quad), 1, "far right clamps to the right column");

    eqi(RZZoneIndexAtPoint(NSMakePoint(10, 10), NSMakeRect(0, 0, 0, 800), halves), -1, "zero-width frame matches nothing");
    eqi(RZZoneIndexAtPoint(NSMakePoint(10, 10), NSMakeRect(0, 0, 1000, 0), halves), -1, "zero-height frame matches nothing");
    eqi(RZZoneIndexAtPoint(NSMakePoint(10, 10), NSMakeRect(0, 0, -100, 800), halves), -1, "negative frame matches nothing");
    eqi(RZZoneIndexAtPoint(NSMakePoint(500, 400), vf, @[]), -1, "no zones matches nothing");

    // A template covering only part of the screen leaves a genuine gap; the
    // clamp must not invent a match there.
    NSArray *partial = @[RZZone(0, 0, .25, .25)];
    eqi(RZZoneIndexAtPoint(NSMakePoint(500, 400), vf, partial), -1, "point in an uncovered gap matches nothing");
}

#pragma mark - Screen resolution

static void test_screen_hit(void) {
    group("screen hit testing");
    NSRect main_ = NSMakeRect(0, 0, 1920, 1080);
    NSRect left  = NSMakeRect(-1920, 0, 1920, 1080);

    eqi(RZScreenIndexAtPoint(NSMakePoint(10, 10), frames(main_)), 0, "point inside the only screen");
    eqi(RZScreenIndexAtPoint(NSMakePoint(-10, 500), frames2(main_, left)), 1, "point on the second display");
    eqi(RZScreenIndexAtPoint(NSMakePoint(500, 500), frames2(main_, left)), 0, "point on the primary display");
    eqi(RZScreenIndexAtPoint(NSMakePoint(0, 0), @[]), -1, "no screens at all");

    // The regression this fallback exists for: a cursor shoved to the top row
    // arrives as CG y == 0, which converts to exactly NSMaxY(frame). NSPointInRect
    // treats the max edge as OUTSIDE, so the top row of the screen used to resolve
    // to no screen — killing the overlay precisely where the user aims for a top
    // corner. The inclusive retry must recover it.
    eqi(RZScreenIndexAtPoint(NSMakePoint(500, 1080), frames(main_)), 0, "top edge (CG y==0) still finds its screen");
    eqi(RZScreenIndexAtPoint(NSMakePoint(1920, 500), frames(main_)), 0, "right edge still finds its screen");
    eqi(RZScreenIndexAtPoint(NSMakePoint(1920, 1080), frames(main_)), 0, "top-right corner still finds its screen");
    eqi(RZScreenIndexAtPoint(NSMakePoint(9999, 9999), frames(main_)), -1, "a point on no screen is still unmatched");

    // Strict containment gets its full pass first, so an interior point never
    // loses to a neighbour that merely touches it edge-on.
    eqi(RZScreenIndexAtPoint(NSMakePoint(0, 500), frames2(left, main_)), 1,
        "shared edge goes to the screen that strictly contains the point");
}

#pragma mark - Coordinates and padding

static void test_coordinates(void) {
    group("coordinate conversion");
    CGFloat h = 1080;
    NSPoint p = RZNSPointFromCG(CGPointMake(100, 0), h);
    eqd(p.y, 1080, "CG top maps to AppKit top");
    eqd(RZNSPointFromCG(CGPointMake(100, 1080), h).y, 0, "CG bottom maps to AppKit bottom");
    eqd(p.x, 100, "x is unchanged");

    // Round trip: a rect converted out and back must land where it started.
    NSRect r = NSMakeRect(10, 20, 300, 400);
    CGRect cg = RZCGRectFromNS(r, h);
    eqd(cg.origin.y, 1080 - 420, "CG y is measured from the top of the primary screen");
    NSPoint back = RZNSPointFromCG(CGPointMake(cg.origin.x, cg.origin.y), h);
    eqd(back.y, NSMaxY(r), "converting back recovers the top edge");
    eqd(cg.size.width, 300, "width survives conversion");
    eqd(cg.size.height, 400, "height survives conversion");

    group("placement gap");
    NSRect big = NSMakeRect(0, 0, 1000, 800);
    eqrect(RZPadRect(big, 8), NSMakeRect(8, 8, 984, 784), "gap insets all four sides");
    eqrect(RZPadRect(big, 0), big, "zero gap is a no-op");
    eqrect(RZPadRect(big, -5), big, "negative gap is ignored");
    // A gap must never consume the window it is padding.
    eqrect(RZPadRect(NSMakeRect(0, 0, 20, 20), 8), NSMakeRect(0, 0, 20, 20), "gap skipped when the rect is too small");
    eqrect(RZPadRect(NSMakeRect(0, 0, 25, 20), 8), NSMakeRect(0, 0, 25, 20), "gap skipped when only one side would survive");
    eqrect(RZPadRect(NSMakeRect(0, 0, 0, 0), 8), NSMakeRect(0, 0, 0, 0), "zero rect is left alone");
    eqrect(RZPadRect(NSMakeRect(0, 0, -100, -100), 8), NSMakeRect(0, 0, -100, -100), "negative rect is left alone");

    group("editor snap");
    eqd(RZSnap(0.333333333), 0.33, "snaps to two decimals");
    eqd(RZSnap(0.335), 0.34, "rounds half up");
    eqd(RZSnap(0), 0, "zero stays zero");
    eqd(RZSnap(1), 1, "one stays one");
    eqd(RZSnap(-0.126), -0.13, "negatives round away from zero");
}

#pragma mark - Config

static void test_config(void) {
    group("config defaults");
    eqi((NSInteger)RZTemplatesFromConfig(nil).count, 5, "nil config yields the presets");
    ok([RZTriggerFromConfig(nil) isEqualToString:@"cmd"], "trigger defaults to cmd");
    eqi(RZGapFromConfig(nil), 8, "gap defaults to 8");
    eqi(RZCustomKeyFromConfig(nil), 0, "customKey defaults to 0");
    eqi((NSInteger)RZShortcutsFromConfig(nil).count, 2, "two default shortcuts");

    // An explicit 0 is a real setting, not an absent one.
    eqi(RZGapFromConfig(@{@"gap": @0}), 0, "explicit gap 0 survives");
    eqi(RZGapFromConfig(@{@"gap": @24}), 24, "explicit gap is read");
    ok([RZTriggerFromConfig(@{@"trigger": @"fn"}) isEqualToString:@"fn"], "explicit trigger is read");

    group("config round trip");
    NSDictionary *cfg = RZConfigDictionary(RZPresetTemplates(), @"abc", @"alt", 7, 12, RZDefaultShortcuts());
    ok([NSJSONSerialization isValidJSONObject:cfg], "encoded config is serialisable");
    eqi((NSInteger)[cfg[@"templates"] count], 5, "all templates encoded");
    ok([cfg[@"trigger"] isEqualToString:@"alt"], "trigger encoded");
    eqi([cfg[@"gap"] integerValue], 12, "gap encoded");
    eqi([cfg[@"customKey"] integerValue], 7, "customKey encoded");

    // Encode then decode must be lossless for the fields the app relies on.
    NSMutableArray<RZTemplate *> *back = RZTemplatesFromConfig(cfg);
    eqi((NSInteger)back.count, 5, "decode recovers every template");
    eqi(RZGapFromConfig(cfg), 12, "decode recovers the gap");
    ok([RZTriggerFromConfig(cfg) isEqualToString:@"alt"], "decode recovers the trigger");
    eqi((NSInteger)back[0].zones.count, 2, "Halves still has two zones after a round trip");

    group("config corruption");
    // config.json is a plain file in Application Support that a user is free to
    // edit or truncate. None of this may take the app down at launch — the old
    // inline decoder sent whatever JSON held straight to -integerValue.
    NSDictionary *junk[] = {
        @{},
        @{@"templates": @"not-an-array"},
        @{@"templates": @[@"nope", @42, @{}]},
        @{@"gap": [NSNull null], @"trigger": @99, @"customKey": @"seven", @"shortcuts": @[]},
        @{@"templates": @[@{@"zones": @[]}]},
        @{@"templates": @[@{@"uuid": @7, @"name": @[], @"zones": @[@{@"x": @0, @"y": @0, @"w": @1, @"h": @1}]}]},
    };
    for (int i = 0; i < 6; i++) {
        NSDictionary *g = junk[i];
        ok(RZTemplatesFromConfig(g).count > 0, "corrupt config still yields usable templates");
        ok(RZTriggerFromConfig(g) != nil, "corrupt config still yields a trigger");
        RZGapFromConfig(g);
        RZCustomKeyFromConfig(g);
        ok(RZShortcutsFromConfig(g) != nil, "corrupt config still yields shortcuts");
    }
    // A zone-less template is unusable — it would strand the user on an empty
    // overlay — so it must be dropped rather than carried through. When dropping
    // it empties the list, the presets take over.
    NSMutableArray<RZTemplate *> *emptied = RZTemplatesFromConfig(@{@"templates": @[@{@"name": @"Ghost", @"zones": @[]}]});
    eqi((NSInteger)emptied.count, 5, "a template with no zones is dropped and the presets fill in");
    for (RZTemplate *t in emptied) ok(t.zones.count > 0, "no surviving template is zone-less");

    // Dropping the empty one must not take valid siblings with it.
    NSDictionary *mixed = @{@"templates": @[@{@"name": @"Ghost", @"zones": @[]},
                                            @{@"name": @"Real", @"zones": @[@{@"x": @0, @"y": @0, @"w": @1, @"h": @1}]}]};
    NSMutableArray<RZTemplate *> *kept = RZTemplatesFromConfig(mixed);
    eqi((NSInteger)kept.count, 1, "only the zone-less template is dropped");
    ok([kept[0].name isEqualToString:@"Real"], "the valid sibling survives");

    // Wrong-typed uuid/name are replaced, but the valid zones are kept.
    NSMutableArray<RZTemplate *> *repaired = RZTemplatesFromConfig(junk[5]);
    eqi((NSInteger)repaired.count, 1, "template with junk metadata but real zones is kept");
    ok([repaired[0].name isEqualToString:@"Untitled"], "junk name replaced with a placeholder");
    ok(repaired[0].uuid.length > 0, "junk uuid replaced with a generated one");

    group("active template resolution");
    NSMutableArray<RZTemplate *> *ts = RZTemplatesFromConfig(nil);
    ok([RZResolveActiveUUID(ts[2].uuid, ts) isEqualToString:ts[2].uuid], "a live uuid is kept");
    ok([RZResolveActiveUUID(@"missing", ts) isEqualToString:ts[0].uuid], "a dangling uuid falls back to the first");
    ok([RZResolveActiveUUID(nil, ts) isEqualToString:ts[0].uuid], "no uuid falls back to the first");
    ok(RZResolveActiveUUID(@"anything", @[]) == nil, "no templates yields nil rather than a crash");

    group("zone model");
    NSArray *orig = @[RZZone(0, 0, .5, 1)];
    NSMutableArray *copy = RZCopyZones(orig);
    copy[0][@"x"] = @(0.9);
    eqd([orig[0][@"x"] doubleValue], 0, "copying zones is deep, not shared");
    eqi((NSInteger)RZCopyZones(@[]).count, 0, "copying an empty zone list is fine");

    RZTemplate *a = RZMakeTemplate(@"A", orig);
    RZTemplate *b = RZMakeTemplate(@"A", orig);
    ok(![a.uuid isEqualToString:b.uuid], "each template gets its own uuid");
    eqi((NSInteger)RZPresetTemplates().count, 5, "five presets ship");
}

#pragma mark -

int main(void) {
    @autoreleasepool {
        test_zone_rects();
        test_zone_hit();
        test_screen_hit();
        test_coordinates();
        test_config();

        printf("\n%d checks, %d failed\n", gChecks, gFails);
        if (gFails) { printf("FAILED\n"); return 1; }
        printf("PASSED\n");
        return 0;
    }
}
