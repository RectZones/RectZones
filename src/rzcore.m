// See rzcore.h for what may and may not live in this file.

#import "rzcore.h"

#pragma mark - Model

NSMutableDictionary *RZZone(double x, double y, double w, double h) {
    return [@{@"x": @(x), @"y": @(y), @"w": @(w), @"h": @(h)} mutableCopy];
}

@implementation RZTemplate
@end

NSMutableArray<NSMutableDictionary *> *RZCopyZones(NSArray *zones) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:zones.count];
    for (NSDictionary *z in zones) [out addObject:[z mutableCopy]];
    return out;
}

RZTemplate *RZMakeTemplate(NSString *name, NSArray *zones) {
    RZTemplate *t = [RZTemplate new];
    t.uuid = [[NSUUID UUID] UUIDString];
    t.name = name;
    t.zones = RZCopyZones(zones);
    return t;
}

NSArray<RZTemplate *> *RZPresetTemplates(void) {
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

// DELIBERATE BREAK — reverted in the next commit.
double RZSnap(double v) { return round(v * 10) / 10; }

#pragma mark - Coordinates

NSPoint RZNSPointFromCG(CGPoint p, CGFloat primaryHeight) {
    return NSMakePoint(p.x, primaryHeight - p.y);
}

CGRect RZCGRectFromNS(NSRect r, CGFloat primaryHeight) {
    return CGRectMake(NSMinX(r), primaryHeight - NSMaxY(r), NSWidth(r), NSHeight(r));
}

#pragma mark - Placement

NSRect RZPadRect(NSRect r, CGFloat gap) {
    if (gap > 0 && r.size.width > 3 * gap && r.size.height > 3 * gap) {
        return NSInsetRect(r, gap, gap);
    }
    return r;
}

NSRect RZZoneRectInFrame(NSDictionary *zone, NSRect vf) {
    double zx = [zone[@"x"] doubleValue], zy = [zone[@"y"] doubleValue];
    double zw = [zone[@"w"] doubleValue], zh = [zone[@"h"] doubleValue];
    return NSMakeRect(NSMinX(vf) + zx * NSWidth(vf),
                      NSMinY(vf) + (1 - zy - zh) * NSHeight(vf),
                      zw * NSWidth(vf), zh * NSHeight(vf));
}

NSInteger RZZoneIndexAtPoint(NSPoint p, NSRect vf, NSArray *zones) {
    if (NSWidth(vf) <= 0 || NSHeight(vf) <= 0) return -1;
    double rx = (p.x - NSMinX(vf)) / NSWidth(vf);
    double ry = (NSMaxY(vf) - p.y) / NSHeight(vf); // ratio from top
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

NSInteger RZScreenIndexAtPoint(NSPoint p, NSArray<NSValue *> *frames) {
    for (NSUInteger i = 0; i < frames.count; i++) {
        if (NSPointInRect(p, frames[i].rectValue)) return (NSInteger)i;
    }
    // Strict containment already had its pass, so no screen that owns the point
    // loses it by retrying with the max edges included.
    for (NSUInteger i = 0; i < frames.count; i++) {
        NSRect f = frames[i].rectValue;
        if (p.x >= NSMinX(f) && p.x <= NSMaxX(f) &&
            p.y >= NSMinY(f) && p.y <= NSMaxY(f)) return (NSInteger)i;
    }
    return -1;
}

#pragma mark - Config

NSDictionary *RZDefaultShortcuts(void) {
    NSUInteger co = RZModControl | RZModOption;
    return @{@"maximize": @{@"key": @36,  @"mods": @(co)},
             @"grid32":   @{@"key": @124, @"mods": @(co)}};
}

// A config value is only usable if it is present AND the type we expect. An
// NSNull or a nested object reaching -integerValue is an unrecognised selector,
// i.e. a launch crash driven by the contents of a file the user can edit.
static id RZConfigValue(NSDictionary *cfg, NSString *key, Class expected) {
    if (![cfg isKindOfClass:NSDictionary.class]) return nil;
    id v = cfg[key];
    return [v isKindOfClass:expected] ? v : nil;
}

NSMutableArray<RZTemplate *> *RZTemplatesFromConfig(NSDictionary *cfg) {
    NSMutableArray<RZTemplate *> *out = [NSMutableArray array];
    NSArray *raw = RZConfigValue(cfg, @"templates", NSArray.class);
    for (id entry in raw) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *td = entry;
        RZTemplate *t = [RZTemplate new];
        NSString *uuid = [td[@"uuid"] isKindOfClass:NSString.class] ? td[@"uuid"] : nil;
        NSString *name = [td[@"name"] isKindOfClass:NSString.class] ? td[@"name"] : nil;
        t.uuid = uuid ?: [[NSUUID UUID] UUIDString];
        t.name = name ?: @"Untitled";
        t.zones = [NSMutableArray array];
        if ([td[@"zones"] isKindOfClass:NSArray.class]) {
            for (id z in td[@"zones"]) {
                if ([z isKindOfClass:NSDictionary.class]) [t.zones addObject:[z mutableCopy]];
            }
        }
        // A template with no zones is unusable and would strand the user on an
        // empty overlay, so it is dropped rather than repaired.
        if (t.zones.count) [out addObject:t];
    }
    if (!out.count) [out addObjectsFromArray:RZPresetTemplates()];
    return out;
}

NSString *RZTriggerFromConfig(NSDictionary *cfg) {
    return RZConfigValue(cfg, @"trigger", NSString.class) ?: @"cmd";
}

NSInteger RZCustomKeyFromConfig(NSDictionary *cfg) {
    return [(NSNumber *)RZConfigValue(cfg, @"customKey", NSNumber.class) integerValue];
}

NSInteger RZGapFromConfig(NSDictionary *cfg) {
    NSNumber *g = RZConfigValue(cfg, @"gap", NSNumber.class);
    return g ? g.integerValue : 8;
}

NSMutableDictionary *RZShortcutsFromConfig(NSDictionary *cfg) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *sc = RZConfigValue(cfg, @"shortcuts", NSDictionary.class);
    if (sc) {
        [out addEntriesFromDictionary:sc];
    } else {
        [out addEntriesFromDictionary:RZDefaultShortcuts()];
    }
    return out;
}

NSString *RZResolveActiveUUID(NSString *wanted, NSArray<RZTemplate *> *templates) {
    if (!templates.count) return nil;
    for (RZTemplate *t in templates) {
        if (wanted && [t.uuid isEqualToString:wanted]) return wanted;
    }
    return templates[0].uuid;
}

NSDictionary *RZConfigDictionary(NSArray<RZTemplate *> *templates,
                                 NSString *activeUUID,
                                 NSString *trigger,
                                 NSInteger customKey,
                                 NSInteger gap,
                                 NSDictionary *shortcuts) {
    NSMutableArray *ts = [NSMutableArray array];
    for (RZTemplate *t in templates) {
        if (!t.uuid || !t.name || !t.zones) continue;
        [ts addObject:@{@"uuid": t.uuid, @"name": t.name, @"zones": t.zones}];
    }
    return @{@"templates": ts,
             @"active": activeUUID ?: @"",
             @"trigger": trigger ?: @"cmd",
             @"customKey": @(customKey),
             @"gap": @(gap),
             @"shortcuts": shortcuts ?: @{}};
}
