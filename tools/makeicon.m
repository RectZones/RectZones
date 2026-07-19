// RectZones app icon generator: rounded dark tile with a 3×2 grid,
// top-left cell filled with accent blue. Outputs an .iconset directory.
#import <Cocoa/Cocoa.h>

static void drawIcon(CGFloat s) {
    CGFloat m = s * 0.08;
    NSRect bg = NSMakeRect(m, m, s - 2 * m, s - 2 * m);
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:bg
                                                           xRadius:s * 0.18 yRadius:s * 0.18];
    NSGradient *g = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithCalibratedRed:0.17 green:0.21 blue:0.30 alpha:1]
                  endingColor:[NSColor colorWithCalibratedRed:0.09 green:0.12 blue:0.18 alpha:1]];
    [g drawInBezierPath:bgPath angle:-90];

    CGFloat gap = s * 0.045;
    NSRect grid = NSInsetRect(bg, s * 0.10, s * 0.14);
    NSInteger cols = 3, rows = 2;
    CGFloat cw = (grid.size.width - (cols - 1) * gap) / cols;
    CGFloat ch = (grid.size.height - (rows - 1) * gap) / rows;
    for (NSInteger r = 0; r < rows; r++) {
        for (NSInteger c = 0; c < cols; c++) {
            NSRect cell = NSMakeRect(grid.origin.x + c * (cw + gap),
                                     grid.origin.y + r * (ch + gap), cw, ch);
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:cell
                                                              xRadius:s * 0.045 yRadius:s * 0.045];
            BOOL hot = (r == rows - 1 && c == 0); // top-left cell
            if (hot) {
                [[NSColor colorWithCalibratedRed:0.26 green:0.56 blue:1.0 alpha:1] setFill];
                [p fill];
            } else {
                [[NSColor colorWithCalibratedWhite:1 alpha:0.20] setFill];
                [p fill];
                [[NSColor colorWithCalibratedWhite:1 alpha:0.40] setStroke];
                p.lineWidth = MAX(1, s * 0.008);
                [p stroke];
            }
        }
    }
}

static void writePNG(CGFloat s, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)s pixelsHigh:(NSInteger)s
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    drawIcon(s);
    [NSGraphicsContext.currentContext flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dir = argc > 1 ? @(argv[1]) : @"AppIcon.iconset";
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            writePNG(sizes[i], [dir stringByAppendingFormat:@"/icon_%dx%d.png", sizes[i], sizes[i]]);
            writePNG(sizes[i] * 2, [dir stringByAppendingFormat:@"/icon_%dx%d@2x.png", sizes[i], sizes[i]]);
        }
    }
    return 0;
}
