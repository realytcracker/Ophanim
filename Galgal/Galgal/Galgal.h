//
//  Galgal.h
//  Galgal
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

//! Project version number for Galgal.
FOUNDATION_EXPORT double GalgalVersionNumber;

//! Project version string for Galgal.
FOUNDATION_EXPORT const unsigned char GalgalVersionString[];

#import "PTFakeMetaTouch.h"
#import "IOHIDEvent+KIF.h"
#import "UIApplication+Private.h"
#import "UIEvent+Private.h"
#import "UITouch+Private.h"

// OphanimCore capture ring - exposes op_ring_start()/op_ring_emit() to the framework's Swift (this
// umbrella doubles as the Swift bridging header) and to the OphanimCore interpose wrappers.
#import "../../OphanimCore/OPRing.h"

// This is the function that CFRunLoop calls to serve main dispatch queue
// Used by GalgalInput to manually drain the queue
extern void _dispatch_main_queue_callback_4CF(void *);
