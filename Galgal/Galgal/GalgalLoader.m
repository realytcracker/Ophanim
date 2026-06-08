//
//  GalgalLoader.m
//  Galgal
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <sys/sysctl.h>

#import "GalgalLoader.h"
#import <Galgal/Galgal-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import "../../OphanimCore/OPRing.h"   // op_ring_emit for filesystem capture

@import MachO;

// Get device model from ophanim .plist
// With a null terminator
#define DEVICE_MODEL [[[AppConfig shared] deviceModel] cStringUsingEncoding:NSUTF8StringEncoding]
#define OEM_ID [[[AppConfig shared] oemID] cStringUsingEncoding:NSUTF8StringEncoding]
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int gg_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int gg_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int gg_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int gg_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(gg_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(gg_uname, uname)
DYLD_INTERPOSE(gg_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(gg_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Extract a keychain item's service/account into a stack buffer. CoreFoundation getters don't
// allocate, so the ring producer stays allocation-free.
static void op_kc_attr(CFDictionaryRef d, char *buf, size_t cap) {
    buf[0] = '\0';
    if (!d) return;
    CFTypeRef v = CFDictionaryGetValue(d, kSecAttrService);
    if (!v) v = CFDictionaryGetValue(d, kSecAttrAccount);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, buf, (CFIndex)cap, kCFStringEncodingUTF8);
    }
}

// Use the implementations from KeychainShim
static OSStatus gg_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    char acct[OP_STR_CAP]; op_kc_attr(query, acct, sizeof(acct));
    op_ring_emit(OP_K_KEYCHAIN_COPY, 0, (int32_t)retval, acct[0] ? acct : NULL, NULL, 0);
    if (result != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [KeychainShim debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus gg_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    char acct[OP_STR_CAP]; op_kc_attr(attributes, acct, sizeof(acct));
    op_ring_emit(OP_K_KEYCHAIN_ADD, 0, (int32_t)retval, acct[0] ? acct : NULL, NULL, 0);
    if (result != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus gg_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    char acct[OP_STR_CAP]; op_kc_attr(query, acct, sizeof(acct));
    op_ring_emit(OP_K_KEYCHAIN_UPDATE, 0, (int32_t)retval, acct[0] ? acct : NULL, NULL, 0);
    if (attributesToUpdate != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus gg_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    char acct[OP_STR_CAP]; op_kc_attr(query, acct, sizeof(acct));
    op_ring_emit(OP_K_KEYCHAIN_DELETE, 0, (int32_t)retval, acct[0] ? acct : NULL, NULL, 0);
    if ([[AppConfig shared] chainGuardDebugging]) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef gg_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[AppConfig shared] chainGuard]) {
        result = [KeychainShim keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus gg_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[AppConfig shared] chainGuardDebugging]) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(gg_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(gg_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(gg_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(gg_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(gg_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(gg_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int gg_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    // Allocation-free capture: op_ring_emit only memcpys into the lock-free ring, so it's safe even
    // though open() is called from inside malloc. It self-gates on the .filesystem category mask.
    op_ring_emit(OP_K_FS_OPEN, 0, oflag, filename, NULL, 0);

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, O_CREAT, mod);
    }

    return open(filename, oflag);
}

static int gg_stat(char const* restrict path, struct stat* restrict buf) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_STAT, 0, 0, p, NULL, 0);
    return stat(p, buf);
}

static int gg_access(char const* path, int mode) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_ACCESS, 0, mode, p, NULL, 0);
    return access(p, mode);
}

static int gg_rename(char const* restrict old_name, char const* restrict new_name) {
    char const *o = ue_fix_filename(old_name);
    char const *n = ue_fix_filename(new_name);
    op_ring_emit(OP_K_FS_RENAME, 0, 0, o, NULL, 0);
    return rename(o, n);
}

static int gg_unlink(char const* path) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_UNLINK, 0, 0, p, NULL, 0);
    return unlink(p);
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int gg_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[AppConfig shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);
        
        int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
        int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];
        
        if (time == 100000) {
            int timestamp = (int)[[NSDate date] timeIntervalSince1970];
            // If it sleeps too fast, increase counter
            if (timestamp - last_sleep_attempt < 2) {
                thread_sleep_counter++;
            } else {
                thread_sleep_counter = 1;
            }
            last_sleep_attempt = timestamp;
            thread_sleep_counters[threadKey] = @(thread_sleep_counter);
            last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            
        }
        
        if (thread_sleep_counter > 100) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(gg_open, open)
DYLD_INTERPOSE(gg_stat, stat)
DYLD_INTERPOSE(gg_access, access)
DYLD_INTERPOSE(gg_rename, rename)
DYLD_INTERPOSE(gg_unlink, unlink)
DYLD_INTERPOSE(gg_usleep, usleep)

@implementation GalgalLoader

static void __attribute__((constructor)) initialize(void) {
    [Ophanim launch];

    // Ophanim instrumentation engine (embedded injection mode). Gated: starts only when the app's
    // config selects embedded injection - in sibling mode the standalone agent dylib owns the engine
    // and the embedded core stays dormant here.
    [OPBootstrap startEmbedded];

    if (ue_status == 0) {
        if (GalgalInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[AppConfig shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
