//
//  OPAgentDylib.m
//  OphanimAgent (sibling-dylib injection mode)
//
//  Constructor for the standalone agent dylib. When the installer adds a second LC_LOAD_DYLIB
//  pointing at this dylib (alongside Galgal), dyld runs this on load and starts the same
//  OphanimCore engine the embedded mode uses.
//
//  HARD RULE (see project notes): in sibling mode OphanimCore must NEVER DYLD_INTERPOSE the C
//  symbols Galgal already interposes (open/stat/SecItem*/sysctl/…). Sibling hooks stay at the
//  ObjC-swizzle / NSURLProtocol layer; the embedded mode owns the inline C-symbol interception.
//

#import <Foundation/Foundation.h>

// Forward-declared so this file needs no generated Swift header at compile time; the symbol is
// provided by the OphanimCore Swift sources linked into the same dylib. The sibling build compiles
// OphanimCore with -D OPHANIM_SIBLING, which names the entry class `OPAgentBootstrap` (distinct from
// the embedded Galgal runtime's `OPBootstrap`) so the two never collide in one process.
@interface OPAgentBootstrap : NSObject
+ (void)start;
@end

__attribute__((constructor))
static void ophanim_agent_init(void) {
    @autoreleasepool {
        [OPAgentBootstrap start];
    }
}
