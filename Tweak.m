#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <substrate.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include "webp/decode.h"

#ifndef API_AVAILABLE
#define API_AVAILABLE(...)
#endif

#define WLOG(fmt, ...) NSLog(@"[WebPSafari] " fmt, ##__VA_ARGS__)

#pragma mark - Constants / helpers

#define WEBP_UTI CFSTR("org.webmproject.webp")
#define WEBP_MIME CFSTR("image/webp")
#define UTI_MIME_CLASS CFSTR("public.mime-type")

static BOOL WebPHeaderMatches(const UInt8 *bytes, CFIndex length) {
    return bytes && length >= 12 &&
           memcmp(bytes, "RIFF", 4) == 0 &&
           memcmp(bytes + 8, "WEBP", 4) == 0;
}

static void LogLoadedProcess(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    WLOG(@"loaded into process: %@ (%@), pid=%d",
         bundle.bundleIdentifier ?: @"<no-bundle>",
         [NSProcessInfo processInfo].processName ?: @"<no-name>",
         getpid());
}

#pragma mark - MIME / UTI registration

/*
 * WebKit asks ImageIO what image UTIs are readable and maps those UTIs back
 * to MIME types.  On old iOS versions ImageIO has no native WebP decoder, so
 * advertise the standard WebP UTI here.  The actual decode is handled below
 * by converting WebP -> PNG before ImageIO sees the bytes.
 */
static CFArrayRef (*orig_CGImageSourceCopyTypeIdentifiers)(void);

static CFArrayRef hook_CGImageSourceCopyTypeIdentifiers(void) {
    if (!orig_CGImageSourceCopyTypeIdentifiers) {
        return NULL;
    }

    CFArrayRef origList = orig_CGImageSourceCopyTypeIdentifiers();
    NSMutableArray *list = origList
        ? [(__bridge_transfer NSArray *)origList mutableCopy]
        : [NSMutableArray array];

    if (![list containsObject:(__bridge NSString *)WEBP_UTI]) {
        [list addObject:(__bridge NSString *)WEBP_UTI];
    }

    WLOG(@"CopyTypeIdentifiers -> %lu types (WebP advertised)",
         (unsigned long)list.count);
    return (__bridge_retained CFArrayRef)list;
}

static CFStringRef (*orig_UTTypeCopyPreferredTagWithClass)(CFStringRef, CFStringRef);

static CFStringRef hook_UTTypeCopyPreferredTagWithClass(CFStringRef uti,
                                                        CFStringRef tagClass) {
    if (uti && tagClass &&
        CFStringCompare(uti, WEBP_UTI, 0) == kCFCompareEqualTo &&
        CFStringCompare(tagClass, UTI_MIME_CLASS, 0) == kCFCompareEqualTo) {
        WLOG(@"UTI->MIME: image/webp");
        return CFRetain(WEBP_MIME);
    }

    return orig_UTTypeCopyPreferredTagWithClass
        ? orig_UTTypeCopyPreferredTagWithClass(uti, tagClass)
        : NULL;
}

static CFStringRef (*orig_UTTypeCreatePreferredIdentifierForTag)(CFStringRef, CFStringRef, CFStringRef);

static CFStringRef hook_UTTypeCreatePreferredIdentifierForTag(CFStringRef tagClass,
                                                              CFStringRef tag,
                                                              CFStringRef conforming) {
    if (tagClass && tag &&
        CFStringCompare(tagClass, UTI_MIME_CLASS, 0) == kCFCompareEqualTo &&
        CFStringCompare(tag, WEBP_MIME, 0) == kCFCompareEqualTo) {
        WLOG(@"MIME->UTI: image/webp");
        return CFRetain(WEBP_UTI);
    }

    return orig_UTTypeCreatePreferredIdentifierForTag
        ? orig_UTTypeCreatePreferredIdentifierForTag(tagClass, tag, conforming)
        : NULL;
}

#pragma mark - WebP -> PNG

static CFDataRef CreatePNGFromWebP(CFDataRef webp) {
    if (!webp) {
        return NULL;
    }

    const UInt8 *in = CFDataGetBytePtr(webp);
    size_t inLen = (size_t)CFDataGetLength(webp);

    int width = 0;
    int height = 0;
    if (!WebPGetInfo(in, inLen, &width, &height)) {
        WLOG(@"WebPGetInfo failed (len=%lu)", (unsigned long)inLen);
        return NULL;
    }

    WLOG(@"WebP detected: %dx%d, %lu bytes",
         width, height, (unsigned long)inLen);

    uint8_t *rgba = WebPDecodeRGBA(in, inLen, &width, &height);
    if (!rgba) {
        WLOG(@"WebPDecodeRGBA failed");
        return NULL;
    }

    size_t rowBytes = (size_t)width * 4;
    size_t pixelBytes = rowBytes * (size_t)height;

    CFDataRef pixels = CFDataCreate(kCFAllocatorDefault, rgba, (CFIndex)pixelBytes);
    WebPFree(rgba);
    if (!pixels) {
        WLOG(@"CFDataCreate for decoded pixels failed");
        return NULL;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = NULL;

    if (provider && colorSpace) {
        image = CGImageCreate(width,
                              height,
                              8,
                              32,
                              rowBytes,
                              colorSpace,
                              kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                              provider,
                              NULL,
                              false,
                              kCGRenderingIntentDefault);
    }

    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    if (provider) {
        CGDataProviderRelease(provider);
    }
    CFRelease(pixels);

    if (!image) {
        WLOG(@"CGImageCreate failed");
        return NULL;
    }

    CFMutableDataRef png = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = NULL;

    if (png) {
        destination = CGImageDestinationCreateWithData(png, CFSTR("public.png"), 1, NULL);
    }

    BOOL finalized = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }

    CGImageRelease(image);

    if (!finalized || !png || CFDataGetLength(png) == 0) {
        WLOG(@"PNG conversion failed");
        if (png) {
            CFRelease(png);
        }
        return NULL;
    }

    WLOG(@"WebP -> PNG: %ld bytes", (long)CFDataGetLength(png));
    return png;
}

#pragma mark - One-shot ImageIO path

static CGImageSourceRef (*orig_CGImageSourceCreateWithData)(CFDataRef, CFDictionaryRef);

static CGImageSourceRef hook_CGImageSourceCreateWithData(CFDataRef data,
                                                         CFDictionaryRef options) {
    CFIndex length = data ? CFDataGetLength(data) : -1;
    WLOG(@"CGImageSourceCreateWithData len=%ld", (long)length);

    if (data && WebPHeaderMatches(CFDataGetBytePtr(data), CFDataGetLength(data))) {
        WLOG(@"WebP detected in CreateWithData");
        CFDataRef png = CreatePNGFromWebP(data);
        if (png) {
            CGImageSourceRef source = orig_CGImageSourceCreateWithData(png, options);
            CFRelease(png);
            return source;
        }
    }

    return orig_CGImageSourceCreateWithData
        ? orig_CGImageSourceCreateWithData(data, options)
        : NULL;
}

#pragma mark - Incremental ImageIO path

typedef NS_ENUM(NSInteger, WebPStreamState) {
    WebPStreamUnknown = 0,
    WebPStreamIsWebP = 1,
    WebPStreamIsNotWebP = 2,
};

static NSMutableDictionary *gStreamState;

static NSNumber *StateKey(CGImageSourceRef source) {
    return [NSNumber numberWithUnsignedLong:(unsigned long)source];
}

static CGImageSourceRef (*orig_CGImageSourceCreateIncremental)(CFDictionaryRef);

static CGImageSourceRef hook_CGImageSourceCreateIncremental(CFDictionaryRef options) {
    CGImageSourceRef source = orig_CGImageSourceCreateIncremental
        ? orig_CGImageSourceCreateIncremental(options)
        : NULL;

    WLOG(@"CGImageSourceCreateIncremental -> %p", source);

    if (source && gStreamState) {
        @synchronized(gStreamState) {
            gStreamState[StateKey(source)] = @(WebPStreamUnknown);
        }
    }

    return source;
}

static void (*orig_CGImageSourceUpdateData)(CGImageSourceRef, CFDataRef, bool);

static void hook_CGImageSourceUpdateData(CGImageSourceRef source,
                                         CFDataRef data,
                                         bool final) {
    CFIndex length = data ? CFDataGetLength(data) : -1;
    WLOG(@"CGImageSourceUpdateData src=%p len=%ld final=%d",
         source, (long)length, (int)final);

    if (!source || !data) {
        if (orig_CGImageSourceUpdateData) {
            orig_CGImageSourceUpdateData(source, data, final);
        }
        return;
    }

    NSNumber *key = StateKey(source);
    WebPStreamState state = WebPStreamUnknown;

    @synchronized(gStreamState) {
        NSNumber *stored = gStreamState[key];
        if (stored) {
            state = (WebPStreamState)stored.integerValue;
        }
    }

    /*
     * ImageDecoderCG feeds ImageIO the complete accumulated buffer on every
     * update.  Do not let ImageIO see the first 1..11 bytes until we know
     * whether this is WebP.  Once 12 bytes are available, classify the whole
     * stream and then either pass it through normally or intercept it.
     */
    if (state == WebPStreamUnknown) {
        if (length < 12) {
            if (final) {
                WLOG(@"Short final image (%ld bytes), passing through", (long)length);
                @synchronized(gStreamState) {
                    [gStreamState removeObjectForKey:key];
                }
                orig_CGImageSourceUpdateData(source, data, true);
            }
            return;
        }

        BOOL isWebP = WebPHeaderMatches(CFDataGetBytePtr(data), length);
        state = isWebP ? WebPStreamIsWebP : WebPStreamIsNotWebP;

        @synchronized(gStreamState) {
            gStreamState[key] = @(state);
        }

        WLOG(@"incremental stream classified: %@",
             isWebP ? @"WebP" : @"non-WebP");
    }

    if (state == WebPStreamIsWebP) {
        if (!final) {
            /* Keep WebP bytes away from the native ImageIO decoder. */
            return;
        }

        CFDataRef png = CreatePNGFromWebP(data);
        if (png) {
            orig_CGImageSourceUpdateData(source, png, true);
            CFRelease(png);
        } else {
            WLOG(@"WebP conversion failed; passing original data to ImageIO");
            orig_CGImageSourceUpdateData(source, data, true);
        }

        @synchronized(gStreamState) {
            [gStreamState removeObjectForKey:key];
        }
        return;
    }

    orig_CGImageSourceUpdateData(source, data, final);

    if (final) {
        @synchronized(gStreamState) {
            [gStreamState removeObjectForKey:key];
        }
    }
}

#pragma mark - Setup

__attribute__((constructor))
static void WebPSafariInit(void) {
    gStreamState = [[NSMutableDictionary alloc] init];

    LogLoadedProcess();

    MSHookFunction((void *)CGImageSourceCopyTypeIdentifiers,
                   (void *)hook_CGImageSourceCopyTypeIdentifiers,
                   (void **)&orig_CGImageSourceCopyTypeIdentifiers);

    void *p1 = dlsym(RTLD_DEFAULT, "UTTypeCopyPreferredTagWithClass");
    void *p2 = dlsym(RTLD_DEFAULT, "UTTypeCreatePreferredIdentifierForTag");
    WLOG(@"UTType symbols: %p %p", p1, p2);

    if (p1) {
        MSHookFunction(p1,
                       (void *)hook_UTTypeCopyPreferredTagWithClass,
                       (void **)&orig_UTTypeCopyPreferredTagWithClass);
    }

    if (p2) {
        MSHookFunction(p2,
                       (void *)hook_UTTypeCreatePreferredIdentifierForTag,
                       (void **)&orig_UTTypeCreatePreferredIdentifierForTag);
    }

    MSHookFunction((void *)CGImageSourceCreateWithData,
                   (void *)hook_CGImageSourceCreateWithData,
                   (void **)&orig_CGImageSourceCreateWithData);

    MSHookFunction((void *)CGImageSourceCreateIncremental,
                   (void *)hook_CGImageSourceCreateIncremental,
                   (void **)&orig_CGImageSourceCreateIncremental);

    MSHookFunction((void *)CGImageSourceUpdateData,
                   (void *)hook_CGImageSourceUpdateData,
                   (void **)&orig_CGImageSourceUpdateData);

    WLOG(@"hooks installed");
}
