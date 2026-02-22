/*
 * fs-ios-bridge: Low-level iOS Simulator HID event injection
 *
 * Uses Apple's private SimulatorKit + CoreSimulator frameworks to inject
 * touch, keyboard, and button events directly into the iOS Simulator,
 * bypassing osascript/Accessibility permissions.
 *
 * Based on the approach used by Facebook's idb (MIT license).
 *
 * Usage:
 *   fs-ios-bridge tap <x> <y> [--udid <udid>]
 *   fs-ios-bridge long-press <x> <y> [--duration <ms>] [--udid <udid>]
 *   fs-ios-bridge swipe <x1> <y1> <x2> <y2> [--duration <ms>] [--udid <udid>]
 *   fs-ios-bridge key <keycode> [--udid <udid>]
 *   fs-ios-bridge button <home|lock|siri|apple-pay|side> [--udid <udid>]
 *   fs-ios-bridge gesture <scroll-up|scroll-down|...> [--udid <udid>]
 *   fs-ios-bridge list
 *   fs-ios-bridge snapshot [--udid <udid>]
 *   fs-ios-bridge screenshot [--path <file>] [--udid <udid>]
 *
 * Output: JSON to stdout
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>

// ============================================================================
// Indigo HID types (from SimulatorKit private framework)
// ============================================================================

// Opaque message struct - we only care about size for malloc/send
typedef struct _IndigoMessage {
    uint32_t innerSize;
    uint32_t eventType;
    char payload[];
} IndigoMessage;

// Function pointer types matching SimulatorKit exports
typedef IndigoMessage *(*FnIndigoButton)(int keyCode, int op, int target);
typedef IndigoMessage *(*FnIndigoKeyboard)(uint32_t keyCode, int op);
typedef IndigoMessage *(*FnIndigoMouse)(CGPoint *p0, CGPoint *p1, int target, NSUInteger eventType, CGSize size, int edge);

// HID direction constants (matching idb)
enum {
    HIDDirectionDown = 1,
    HIDDirectionUp = 2,
};

// Button key codes (from SimulatorKit/Indigo.h)
enum {
    ButtonKeyCodeApplePay   = 1,
    ButtonKeyCodeHome       = 2,
    ButtonKeyCodeLock       = 3,
    ButtonKeyCodeSideButton = 4,
    ButtonKeyCodeSiri       = 5,
};

// Button event target
enum {
    ButtonTargetHardware = 1,
};

// Mouse event types for touch simulation
enum {
    MouseEventDown = 1,  // NSEventTypeLeftMouseDown
    MouseEventUp   = 2,  // NSEventTypeLeftMouseUp
    MouseEventDrag = 6,  // NSEventTypeLeftMouseDragged
};

// Key codes (USB HID usage codes)
enum {
    kHIDKeyA = 4, kHIDKeyB = 5, kHIDKeyC = 6, kHIDKeyD = 7, kHIDKeyE = 8,
    kHIDKeyF = 9, kHIDKeyG = 10, kHIDKeyH = 11, kHIDKeyI = 12, kHIDKeyJ = 13,
    kHIDKeyK = 14, kHIDKeyL = 15, kHIDKeyM = 16, kHIDKeyN = 17, kHIDKeyO = 18,
    kHIDKeyP = 19, kHIDKeyQ = 20, kHIDKeyR = 21, kHIDKeyS = 22, kHIDKeyT = 23,
    kHIDKeyU = 24, kHIDKeyV = 25, kHIDKeyW = 26, kHIDKeyX = 27, kHIDKeyY = 28,
    kHIDKeyZ = 29,
    kHIDKey1 = 30, kHIDKey2 = 31, kHIDKey3 = 32, kHIDKey4 = 33, kHIDKey5 = 34,
    kHIDKey6 = 35, kHIDKey7 = 36, kHIDKey8 = 37, kHIDKey9 = 38, kHIDKey0 = 39,
    kHIDKeyReturn = 40,
    kHIDKeyEscape = 41,
    kHIDKeyBackspace = 42,
    kHIDKeyTab = 43,
    kHIDKeySpace = 44,
    kHIDKeyDelete = 76,
    kHIDKeyRight = 79,
    kHIDKeyLeft = 80,
    kHIDKeyDown = 81,
    kHIDKeyUp = 82,
    kHIDKeyHome = 74,
    kHIDKeyEnd = 77,
    kHIDKeyPageUp = 75,
    kHIDKeyPageDown = 78,
    kHIDKeyVolumeUp = 128,   // 0x80
    kHIDKeyVolumeDown = 129, // 0x81
    // Modifier keys
    kHIDKeyLeftControl = 224,
    kHIDKeyLeftShift = 225,
    kHIDKeyLeftAlt = 226,
    kHIDKeyLeftGUI = 227, // Command
    kHIDKeyRightControl = 228,
    kHIDKeyRightShift = 229,
    kHIDKeyRightAlt = 230,
    kHIDKeyRightGUI = 231,
};

// ============================================================================
// Global state
// ============================================================================

static void *simKitHandle = NULL;
static FnIndigoButton fnButton = NULL;
static FnIndigoKeyboard fnKeyboard = NULL;
static FnIndigoMouse fnMouse = NULL;

// ============================================================================
// Framework loading
// ============================================================================

static BOOL loadFrameworks(void) {
    // Load CoreSimulator
    NSBundle *coreSimBundle = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
    if (![coreSimBundle load]) {
        fprintf(stderr, "Failed to load CoreSimulator.framework\n");
        return NO;
    }

    // Load SimulatorKit
    NSBundle *simKitBundle = [NSBundle bundleWithPath:
        @"/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework"];
    if (![simKitBundle load]) {
        fprintf(stderr, "Failed to load SimulatorKit.framework\n");
        return NO;
    }

    // Get Indigo HID function pointers
    simKitHandle = dlopen(simKitBundle.executablePath.UTF8String, RTLD_NOW);
    if (!simKitHandle) {
        fprintf(stderr, "Failed to dlopen SimulatorKit: %s\n", dlerror());
        return NO;
    }

    fnButton = (FnIndigoButton)dlsym(simKitHandle, "IndigoHIDMessageForButton");
    fnKeyboard = (FnIndigoKeyboard)dlsym(simKitHandle, "IndigoHIDMessageForKeyboardArbitrary");
    fnMouse = (FnIndigoMouse)dlsym(simKitHandle, "IndigoHIDMessageForMouseNSEvent");

    if (!fnButton || !fnKeyboard || !fnMouse) {
        fprintf(stderr, "Failed to resolve Indigo HID symbols\n");
        return NO;
    }

    return YES;
}

// ============================================================================
// Device discovery
// ============================================================================

// Get booted device info via simctl (reliable, no private API needed for discovery)
static NSDictionary *getSimctlDevices(void) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcrun";
    task.arguments = @[@"simctl", @"list", @"devices", @"-j"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static NSString *getBootedUDID(NSString *targetUdid) {
    NSDictionary *json = getSimctlDevices();
    if (!json) return nil;
    NSDictionary *devices = json[@"devices"];
    for (NSString *runtime in devices) {
        for (NSDictionary *device in devices[runtime]) {
            if ([device[@"state"] isEqualToString:@"Booted"]) {
                NSString *udid = device[@"udid"];
                if (!targetUdid || [targetUdid isEqualToString:udid]) {
                    return udid;
                }
            }
        }
    }
    return nil;
}

// Get device screen size and scale from simctl device type
static void getDeviceScreenInfo(NSString *udid, CGSize *outSize, float *outScale) {
    // Default iPhone 15 Pro dimensions
    *outSize = CGSizeMake(1179, 2556);
    *outScale = 3.0;

    // Get device info to find device type
    NSDictionary *json = getSimctlDevices();
    if (!json) return;
    NSDictionary *devices = json[@"devices"];
    for (NSString *runtime in devices) {
        for (NSDictionary *device in devices[runtime]) {
            if ([device[@"udid"] isEqualToString:udid]) {
                // Try to get screen info from screenshot dimensions
                NSString *tempPath = [NSString stringWithFormat:@"%@/fs_calibrate_%llu.png",
                                      NSTemporaryDirectory(), (uint64_t)mach_absolute_time()];
                NSTask *task = [[NSTask alloc] init];
                task.launchPath = @"/usr/bin/xcrun";
                task.arguments = @[@"simctl", @"io", udid, @"screenshot", tempPath];
                task.standardOutput = [NSPipe pipe];
                task.standardError = [NSPipe pipe];
                [task launch];
                [task waitUntilExit];

                if (task.terminationStatus == 0) {
                    NSData *imgData = [NSData dataWithContentsOfFile:tempPath];
                    if (imgData.length >= 24) {
                        const uint8_t *bytes = imgData.bytes;
                        // PNG IHDR: width at offset 16, height at offset 20 (big-endian)
                        if (bytes[0] == 0x89 && bytes[1] == 0x50) {
                            uint32_t w = (bytes[16]<<24)|(bytes[17]<<16)|(bytes[18]<<8)|bytes[19];
                            uint32_t h = (bytes[20]<<24)|(bytes[21]<<16)|(bytes[22]<<8)|bytes[23];
                            *outSize = CGSizeMake(w, h);
                            // Scale is already baked into pixel dimensions
                            *outScale = 1.0;
                        }
                    }
                    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                }
                return;
            }
        }
    }
}

// Device info struct (replaces SimDevice object)
typedef struct {
    CGSize screenSize;  // In device pixels
    float scale;        // Already 1.0 since screenSize is in pixels
    char udid[64];
} DeviceInfo;

// ============================================================================
// HID Client
// ============================================================================

// Get SimDevice object from CoreSimulator using UDID
static id getSimDevice(NSString *udid) {
    // SimServiceContext.sharedServiceContextForDeveloperDir:error:
    Class ctxClass = NSClassFromString(@"SimServiceContext");
    if (!ctxClass) {
        fprintf(stderr, "SimServiceContext not found\n");
        return nil;
    }

    NSString *devDir = @"/Applications/Xcode.app/Contents/Developer";
    NSError *error = nil;

    // Use objc_msgSend directly to avoid NSInvocation ARC issues
    typedef id (*MsgSendType)(id, SEL, id, NSError **);
    MsgSendType msgSend = (MsgSendType)objc_msgSend;

    id ctx = msgSend((id)ctxClass,
                     NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
                     devDir, &error);
    if (!ctx) {
        fprintf(stderr, "Failed to get service context: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
        return nil;
    }

    // ctx.defaultDeviceSetWithError:
    typedef id (*MsgSendErr)(id, SEL, NSError **);
    MsgSendErr msgSendErr = (MsgSendErr)objc_msgSend;
    id deviceSet = msgSendErr(ctx,
                              NSSelectorFromString(@"defaultDeviceSetWithError:"),
                              &error);
    if (!deviceSet) {
        fprintf(stderr, "Failed to get device set: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
        return nil;
    }

    // deviceSet.devices
    typedef id (*MsgSendNoArgs)(id, SEL);
    MsgSendNoArgs msgSendNA = (MsgSendNoArgs)objc_msgSend;
    NSArray *devices = msgSendNA(deviceSet, NSSelectorFromString(@"devices"));

    for (id device in devices) {
        NSUUID *deviceUUID = msgSendNA(device, NSSelectorFromString(@"UDID"));
        if ([[deviceUUID UUIDString] isEqualToString:udid]) {
            return device;
        }
    }
    return nil;
}

static id createHIDClient(NSString *udid) {
    id device = getSimDevice(udid);
    if (!device) {
        fprintf(stderr, "SimDevice not found for UDID: %s\n", udid.UTF8String);
        return nil;
    }

    Class clientClass = NSClassFromString(@"SimDeviceLegacyHIDClient");
    if (!clientClass) {
        // Try the Swift class name
        clientClass = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient");
        if (!clientClass) {
            fprintf(stderr, "SimDeviceLegacyHIDClient class not found\n");
            return nil;
        }
    }

    NSError *error = nil;
    typedef id (*InitWithDeviceType)(id, SEL, id, NSError **);
    InitWithDeviceType initWithDevice = (InitWithDeviceType)objc_msgSend;

    id client = initWithDevice([clientClass alloc],
                               NSSelectorFromString(@"initWithDevice:error:"),
                               device, &error);

    if (!client || error) {
        fprintf(stderr, "Failed to create HID client: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
        return nil;
    }
    return client;
}

static BOOL sendHIDMessage(id client, IndigoMessage *message) {
    if (!client || !message) return NO;

    size_t messageSize = malloc_size(message);

    // Copy the message (client will free it)
    IndigoMessage *copy = malloc(messageSize);
    memcpy(copy, message, messageSize);

    // sendWithMessage:freeWhenDone:completionQueue:completion:
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = YES;

    SEL sendSel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    NSMethodSignature *sig = [[client class] instanceMethodSignatureForSelector:sendSel];

    if (!sig) {
        // Try simpler send method
        SEL simpleSel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:");
        sig = [[client class] instanceMethodSignatureForSelector:simpleSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:simpleSel];
            [inv setTarget:client];
            [inv setArgument:&copy atIndex:2];
            BOOL freeWhenDone = YES;
            [inv setArgument:&freeWhenDone atIndex:3];
            [inv invoke];
            return YES;
        }
        fprintf(stderr, "No suitable send method found on HID client\n");
        free(copy);
        return NO;
    }

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    void (^completion)(NSError *) = ^(NSError *error) {
        if (error) {
            fprintf(stderr, "HID send error: %s\n", error.localizedDescription.UTF8String);
            success = NO;
        }
        dispatch_semaphore_signal(sem);
    };

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sendSel];
    [inv setTarget:client];
    [inv setArgument:&copy atIndex:2];
    BOOL freeWhenDone = YES;
    [inv setArgument:&freeWhenDone atIndex:3];
    [inv setArgument:&queue atIndex:4];
    [inv setArgument:&completion atIndex:5];
    [inv invoke];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return success;
}

// ============================================================================
// Output helpers
// ============================================================================

static void printJSON(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
}

static void printSuccess(NSString *message) {
    printJSON(@{@"success": @YES, @"message": message});
}

static void printError(NSString *message) {
    printJSON(@{@"success": @NO, @"error": message});
}

// ============================================================================
// Commands
// ============================================================================

static int cmdTap(id client, DeviceInfo *dev, double x, double y) {
    CGSize screenSize = dev->screenSize;
    float scale = dev->scale;

    // Convert device coordinates to ratio (0-1)
    CGPoint ratio = CGPointMake(
        (x * scale) / screenSize.width,
        (y * scale) / screenSize.height
    );

    // Touch down
    CGPoint zero = CGPointZero;
    IndigoMessage *down = fnMouse(&ratio, &zero, 0x32, MouseEventDown, CGSizeZero, 0);
    if (!sendHIDMessage(client, down)) {
        printError(@"Failed to send touch down");
        return 1;
    }
    free(down);

    usleep(50000); // 50ms between down/up

    // Touch up
    IndigoMessage *up = fnMouse(&ratio, &zero, 0x32, MouseEventUp, CGSizeZero, 0);
    if (!sendHIDMessage(client, up)) {
        printError(@"Failed to send touch up");
        return 1;
    }
    free(up);

    printSuccess([NSString stringWithFormat:@"Tapped at (%.0f, %.0f)", x, y]);
    return 0;
}

static int cmdLongPress(id client, DeviceInfo *dev, double x, double y, int durationMs) {
    CGSize screenSize = dev->screenSize;
    float scale = dev->scale;

    CGPoint ratio = CGPointMake(
        (x * scale) / screenSize.width,
        (y * scale) / screenSize.height
    );
    CGPoint zero = CGPointZero;

    // Touch down
    IndigoMessage *down = fnMouse(&ratio, &zero, 0x32, MouseEventDown, CGSizeZero, 0);
    if (!sendHIDMessage(client, down)) {
        printError(@"Failed to send touch down");
        return 1;
    }
    free(down);

    // Hold for duration
    usleep(durationMs * 1000);

    // Touch up
    IndigoMessage *up = fnMouse(&ratio, &zero, 0x32, MouseEventUp, CGSizeZero, 0);
    if (!sendHIDMessage(client, up)) {
        printError(@"Failed to send touch up");
        return 1;
    }
    free(up);

    printSuccess([NSString stringWithFormat:@"Long pressed at (%.0f, %.0f) for %dms", x, y, durationMs]);
    return 0;
}

static int cmdSwipe(id client, DeviceInfo *dev, double x1, double y1, double x2, double y2, int durationMs) {
    CGSize screenSize = dev->screenSize;
    float scale = dev->scale;
    CGPoint zero = CGPointZero;

    int steps = 10;
    int stepDelay = durationMs * 1000 / steps;

    // Touch down at start
    CGPoint startRatio = CGPointMake(
        (x1 * scale) / screenSize.width,
        (y1 * scale) / screenSize.height
    );
    IndigoMessage *down = fnMouse(&startRatio, &zero, 0x32, MouseEventDown, CGSizeZero, 0);
    sendHIDMessage(client, down);
    free(down);

    // Intermediate drag events
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double cx = x1 + (x2 - x1) * t;
        double cy = y1 + (y2 - y1) * t;
        CGPoint ratio = CGPointMake(
            (cx * scale) / screenSize.width,
            (cy * scale) / screenSize.height
        );
        IndigoMessage *drag = fnMouse(&ratio, &zero, 0x32, MouseEventDrag, CGSizeZero, 0);
        sendHIDMessage(client, drag);
        free(drag);
        usleep(stepDelay);
    }

    // Touch up at end
    CGPoint endRatio = CGPointMake(
        (x2 * scale) / screenSize.width,
        (y2 * scale) / screenSize.height
    );
    IndigoMessage *up = fnMouse(&endRatio, &zero, 0x32, MouseEventUp, CGSizeZero, 0);
    sendHIDMessage(client, up);
    free(up);

    printSuccess([NSString stringWithFormat:@"Swiped from (%.0f,%.0f) to (%.0f,%.0f) in %dms",
                  x1, y1, x2, y2, durationMs]);
    return 0;
}

static int cmdKey(id client, uint32_t keyCode) {
    // Key down
    IndigoMessage *down = fnKeyboard(keyCode, HIDDirectionDown);
    if (!sendHIDMessage(client, down)) {
        printError(@"Failed to send key down");
        return 1;
    }
    free(down);

    usleep(30000); // 30ms

    // Key up
    IndigoMessage *up = fnKeyboard(keyCode, HIDDirectionUp);
    if (!sendHIDMessage(client, up)) {
        printError(@"Failed to send key up");
        return 1;
    }
    free(up);

    printSuccess([NSString stringWithFormat:@"Pressed key %u", keyCode]);
    return 0;
}

static int cmdKeyCombo(id client, NSArray<NSNumber *> *modifiers, uint32_t keyCode) {
    // Press modifiers down
    for (NSNumber *mod in modifiers) {
        IndigoMessage *down = fnKeyboard(mod.unsignedIntValue, HIDDirectionDown);
        sendHIDMessage(client, down);
        free(down);
        usleep(20000);
    }

    // Press key
    IndigoMessage *keyDown = fnKeyboard(keyCode, HIDDirectionDown);
    sendHIDMessage(client, keyDown);
    free(keyDown);
    usleep(30000);

    IndigoMessage *keyUp = fnKeyboard(keyCode, HIDDirectionUp);
    sendHIDMessage(client, keyUp);
    free(keyUp);
    usleep(20000);

    // Release modifiers (reverse order)
    for (NSInteger i = modifiers.count - 1; i >= 0; i--) {
        IndigoMessage *up = fnKeyboard(modifiers[i].unsignedIntValue, HIDDirectionUp);
        sendHIDMessage(client, up);
        free(up);
        usleep(20000);
    }

    printSuccess([NSString stringWithFormat:@"Pressed key combo with key %u", keyCode]);
    return 0;
}

static int cmdButton(id client, int buttonCode) {
    IndigoMessage *down = fnButton(buttonCode, HIDDirectionDown, ButtonTargetHardware);
    if (!sendHIDMessage(client, down)) {
        printError(@"Failed to send button down");
        return 1;
    }
    free(down);

    usleep(100000); // 100ms for button press

    IndigoMessage *up = fnButton(buttonCode, HIDDirectionUp, ButtonTargetHardware);
    if (!sendHIDMessage(client, up)) {
        printError(@"Failed to send button up");
        return 1;
    }
    free(up);

    printSuccess([NSString stringWithFormat:@"Pressed button %d", buttonCode]);
    return 0;
}

static int cmdList(void) {
    // Use simctl for reliable device listing
    NSDictionary *json = getSimctlDevices();
    if (!json) {
        printError(@"Failed to run xcrun simctl list devices");
        return 1;
    }

    NSDictionary *devices = json[@"devices"];
    NSMutableArray *result = [NSMutableArray array];

    for (NSString *runtime in devices) {
        for (NSDictionary *device in devices[runtime]) {
            NSString *stateStr = device[@"state"] ?: @"Unknown";
            [result addObject:@{
                @"name": device[@"name"] ?: @"",
                @"udid": device[@"udid"] ?: @"",
                @"state": stateStr,
                @"runtime": runtime,
                @"booted": @([stateStr isEqualToString:@"Booted"]),
            }];
        }
    }

    printJSON(@{@"success": @YES, @"devices": result, @"count": @(result.count)});
    return 0;
}

static int cmdScreenshot(NSString *udid, NSString *path) {
    if (!path) {
        path = [NSString stringWithFormat:@"%@/fs_screenshot_%llu.png",
                NSTemporaryDirectory(), (uint64_t)(mach_absolute_time() / 1000000)];
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/xcrun";
    task.arguments = @[@"simctl", @"io", udid, @"screenshot", path];

    NSPipe *pipe = [NSPipe pipe];
    task.standardError = pipe;
    [task launch];
    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSData *errData = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *err = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        printError([NSString stringWithFormat:@"Screenshot failed: %@", err]);
        return 1;
    }

    printJSON(@{@"success": @YES, @"path": path, @"message": @"Screenshot saved"});
    return 0;
}

// ============================================================================
// Argument parsing helpers
// ============================================================================

static NSString *getArgValue(NSArray<NSString *> *args, NSString *flag) {
    for (NSUInteger i = 0; i < args.count - 1; i++) {
        if ([args[i] isEqualToString:flag]) {
            return args[i + 1];
        }
    }
    return nil;
}

static uint32_t keyNameToCode(NSString *name) {
    NSDictionary *map = @{
        @"enter": @(kHIDKeyReturn), @"return": @(kHIDKeyReturn),
        @"backspace": @(kHIDKeyBackspace), @"delete": @(kHIDKeyDelete),
        @"tab": @(kHIDKeyTab), @"escape": @(kHIDKeyEscape), @"esc": @(kHIDKeyEscape),
        @"space": @(kHIDKeySpace),
        @"up": @(kHIDKeyUp), @"down": @(kHIDKeyDown),
        @"left": @(kHIDKeyLeft), @"right": @(kHIDKeyRight),
        @"home": @(kHIDKeyHome), @"end": @(kHIDKeyEnd),
        @"pageup": @(kHIDKeyPageUp), @"pagedown": @(kHIDKeyPageDown),
        @"volume_up": @(kHIDKeyVolumeUp), @"volume_down": @(kHIDKeyVolumeDown),
        // Letters
        @"a": @(kHIDKeyA), @"b": @(kHIDKeyB), @"c": @(kHIDKeyC), @"d": @(kHIDKeyD),
        @"e": @(kHIDKeyE), @"f": @(kHIDKeyF), @"g": @(kHIDKeyG), @"h": @(kHIDKeyH),
        @"i": @(kHIDKeyI), @"j": @(kHIDKeyJ), @"k": @(kHIDKeyK), @"l": @(kHIDKeyL),
        @"m": @(kHIDKeyM), @"n": @(kHIDKeyN), @"o": @(kHIDKeyO), @"p": @(kHIDKeyP),
        @"q": @(kHIDKeyQ), @"r": @(kHIDKeyR), @"s": @(kHIDKeyS), @"t": @(kHIDKeyT),
        @"u": @(kHIDKeyU), @"v": @(kHIDKeyV), @"w": @(kHIDKeyW), @"x": @(kHIDKeyX),
        @"y": @(kHIDKeyY), @"z": @(kHIDKeyZ),
    };
    NSNumber *code = map[name.lowercaseString];
    return code ? code.unsignedIntValue : 0;
}

static int buttonNameToCode(NSString *name) {
    NSDictionary *map = @{
        @"home": @(ButtonKeyCodeHome),
        @"lock": @(ButtonKeyCodeLock), @"power": @(ButtonKeyCodeLock),
        @"siri": @(ButtonKeyCodeSiri),
        @"apple-pay": @(ButtonKeyCodeApplePay), @"apple_pay": @(ButtonKeyCodeApplePay),
        @"side": @(ButtonKeyCodeSideButton), @"side-button": @(ButtonKeyCodeSideButton),
    };
    NSNumber *code = map[name.lowercaseString];
    return code ? code.intValue : -1;
}

// ============================================================================
// Main
// ============================================================================

static void printUsage(void) {
    fprintf(stderr,
        "Usage: fs-ios-bridge <command> [args]\n"
        "\n"
        "Commands:\n"
        "  tap <x> <y>                      Tap at coordinates\n"
        "  long-press <x> <y> [--duration ms]  Long press (default 1000ms)\n"
        "  swipe <x1> <y1> <x2> <y2> [--duration ms]  Swipe gesture\n"
        "  key <name>                       Press key (enter/backspace/tab/...)\n"
        "  key-combo <combo>                Key combination (cmd+a, ctrl+c, ...)\n"
        "  button <name>                    Hardware button (home/lock/siri/...)\n"
        "  gesture <name>                   Preset gesture (scroll-up/down/...)\n"
        "  text <string>                    Type text string\n"
        "  list                             List simulators\n"
        "  screenshot [--path file]         Take screenshot\n"
        "\n"
        "Options:\n"
        "  --udid <udid>    Target specific simulator\n"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        if (args.count < 1) {
            printUsage();
            return 1;
        }

        NSString *command = args[0];

        // 'list' only needs simctl, not private frameworks
        if ([command isEqualToString:@"list"]) {
            return cmdList();
        }

        // Load private frameworks for HID injection
        if (!loadFrameworks()) {
            printError(@"Failed to load Apple private frameworks (requires Xcode)");
            return 1;
        }

        // Find booted simulator
        NSString *targetUdid = getArgValue(args, @"--udid");
        NSString *udid = getBootedUDID(targetUdid);
        if (!udid) {
            printError(targetUdid
                ? [NSString stringWithFormat:@"No booted simulator with UDID %@", targetUdid]
                : @"No booted iOS Simulator found");
            return 1;
        }

        // Screenshot uses simctl
        if ([command isEqualToString:@"screenshot"]) {
            return cmdScreenshot(udid, getArgValue(args, @"--path"));
        }

        // Get device screen info
        DeviceInfo dev;
        strncpy(dev.udid, udid.UTF8String, sizeof(dev.udid) - 1);
        getDeviceScreenInfo(udid, &dev.screenSize, &dev.scale);

        // Create HID client via private API
        id client = createHIDClient(udid);
        if (!client) {
            printError(@"Failed to create HID client. Is the simulator booted and Simulator.app running?");
            return 1;
        }

        // ---- tap ----
        if ([command isEqualToString:@"tap"] && args.count >= 3) {
            return cmdTap(client, &dev, [args[1] doubleValue], [args[2] doubleValue]);
        }

        // ---- long-press ----
        if ([command isEqualToString:@"long-press"] && args.count >= 3) {
            NSString *durStr = getArgValue(args, @"--duration");
            return cmdLongPress(client, &dev, [args[1] doubleValue], [args[2] doubleValue],
                               durStr ? durStr.intValue : 1000);
        }

        // ---- swipe ----
        if ([command isEqualToString:@"swipe"] && args.count >= 5) {
            NSString *durStr = getArgValue(args, @"--duration");
            return cmdSwipe(client, &dev,
                           [args[1] doubleValue], [args[2] doubleValue],
                           [args[3] doubleValue], [args[4] doubleValue],
                           durStr ? durStr.intValue : 300);
        }

        // ---- key ----
        if ([command isEqualToString:@"key"] && args.count >= 2) {
            uint32_t code = keyNameToCode(args[1]);
            if (code == 0) {
                code = (uint32_t)[args[1] intValue];
                if (code == 0) {
                    printError([NSString stringWithFormat:@"Unknown key: %@", args[1]]);
                    return 1;
                }
            }
            return cmdKey(client, code);
        }

        // ---- key-combo ----
        if ([command isEqualToString:@"key-combo"] && args.count >= 2) {
            NSArray *parts = [args[1] componentsSeparatedByString:@"+"];
            if (parts.count < 2) {
                printError(@"Key combo format: modifier+key (e.g., cmd+a, ctrl+c)");
                return 1;
            }

            NSMutableArray<NSNumber *> *modifiers = [NSMutableArray array];
            for (NSUInteger i = 0; i < parts.count - 1; i++) {
                NSString *mod = [parts[i] lowercaseString];
                if ([mod isEqualToString:@"cmd"] || [mod isEqualToString:@"command"]) {
                    [modifiers addObject:@(kHIDKeyLeftGUI)];
                } else if ([mod isEqualToString:@"ctrl"] || [mod isEqualToString:@"control"]) {
                    [modifiers addObject:@(kHIDKeyLeftControl)];
                } else if ([mod isEqualToString:@"shift"]) {
                    [modifiers addObject:@(kHIDKeyLeftShift)];
                } else if ([mod isEqualToString:@"alt"] || [mod isEqualToString:@"option"]) {
                    [modifiers addObject:@(kHIDKeyLeftAlt)];
                } else {
                    printError([NSString stringWithFormat:@"Unknown modifier: %@", mod]);
                    return 1;
                }
            }

            uint32_t keyCode = keyNameToCode([parts lastObject]);
            if (keyCode == 0) {
                printError([NSString stringWithFormat:@"Unknown key: %@", [parts lastObject]]);
                return 1;
            }
            return cmdKeyCombo(client, modifiers, keyCode);
        }

        // ---- button ----
        if ([command isEqualToString:@"button"] && args.count >= 2) {
            int code = buttonNameToCode(args[1]);
            if (code < 0) {
                printError([NSString stringWithFormat:@"Unknown button: %@. Use: home, lock, siri, apple-pay, side", args[1]]);
                return 1;
            }
            return cmdButton(client, code);
        }

        // ---- gesture ----
        if ([command isEqualToString:@"gesture"] && args.count >= 2) {
            NSString *gesture = args[1].lowercaseString;
            double w = dev.screenSize.width / dev.scale;
            double h = dev.screenSize.height / dev.scale;

            if ([gesture isEqualToString:@"scroll-up"] || [gesture isEqualToString:@"scroll_up"]) {
                return cmdSwipe(client, &dev, w/2, h*0.6, w/2, h*0.3, 300);
            } else if ([gesture isEqualToString:@"scroll-down"] || [gesture isEqualToString:@"scroll_down"]) {
                return cmdSwipe(client, &dev, w/2, h*0.3, w/2, h*0.6, 300);
            } else if ([gesture isEqualToString:@"scroll-left"] || [gesture isEqualToString:@"scroll_left"]) {
                return cmdSwipe(client, &dev, w*0.7, h/2, w*0.3, h/2, 300);
            } else if ([gesture isEqualToString:@"scroll-right"] || [gesture isEqualToString:@"scroll_right"]) {
                return cmdSwipe(client, &dev, w*0.3, h/2, w*0.7, h/2, 300);
            } else if ([gesture isEqualToString:@"edge-swipe-left"] || [gesture isEqualToString:@"edge_swipe_left"]) {
                return cmdSwipe(client, &dev, 2, h/2, w*0.4, h/2, 300);
            } else if ([gesture isEqualToString:@"edge-swipe-right"] || [gesture isEqualToString:@"edge_swipe_right"]) {
                return cmdSwipe(client, &dev, w-2, h/2, w*0.6, h/2, 300);
            } else if ([gesture isEqualToString:@"pull-to-refresh"] || [gesture isEqualToString:@"pull_to_refresh"]) {
                return cmdSwipe(client, &dev, w/2, h*0.2, w/2, h*0.7, 500);
            } else {
                printError([NSString stringWithFormat:@"Unknown gesture: %@. Use: scroll-up, scroll-down, scroll-left, scroll-right, edge-swipe-left, edge-swipe-right, pull-to-refresh", gesture]);
                return 1;
            }
        }

        // ---- text ----
        if ([command isEqualToString:@"text"] && args.count >= 2) {
            NSString *text = args[1];
            for (NSUInteger i = 0; i < text.length; i++) {
                unichar c = [text characterAtIndex:i];
                NSString *s = [NSString stringWithCharacters:&c length:1];
                uint32_t code = keyNameToCode(s);
                if (code == 0 && c == ' ') code = kHIDKeySpace;
                if (code == 0 && c == '\n') code = kHIDKeyReturn;
                if (code == 0 && c == '\t') code = kHIDKeyTab;

                if (code > 0) {
                    if (c >= 'A' && c <= 'Z') {
                        cmdKeyCombo(client, @[@(kHIDKeyLeftShift)], code);
                    } else {
                        cmdKey(client, code);
                    }
                }
            }
            printSuccess([NSString stringWithFormat:@"Typed text: %@", text]);
            return 0;
        }

        printUsage();
        return 1;
    }
}
