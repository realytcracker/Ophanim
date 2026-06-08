//
//  GalgalShadow.m
//  Galgal
//
//  Created by Venti on 08/03/2023.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <Galgal/Galgal-Swift.h>

__attribute__((visibility("hidden")))
@interface GalgalShadowLoader : NSObject
@end

@implementation NSObject (ShadowSwizzle)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    // Add selector if it doesn't exist, implement append with method
    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod)) ) {
        // Replace class instance method, added if selector not exist
        // For class cluster, it always adds new selector here
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
        
    } else {
        // SwizzleMethod maybe belongs to super
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    Class cls = object_getClass((id)self);
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod(cls, newSelector);

    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod)) ) {
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

// Instance methods

- (NSInteger) pm_hook_deviceType {
    return 1;
}

- (bool) pm_return_false {
    [OPBootstrap logJailbreakBypass:NSStringFromClass([self class]) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return false;
}

- (bool) pm_return_true {
    [OPBootstrap logJailbreakBypass:NSStringFromClass([self class]) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return true;
}

- (BOOL) pm_return_yes {
    [OPBootstrap logJailbreakBypass:NSStringFromClass([self class]) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return YES;
}

- (id) pm_return_null {
    [OPBootstrap logJailbreakBypass:NSStringFromClass([self class]) selector:NSStringFromSelector(_cmd)];
    return nil;
}

- (BOOL) pm_return_no {
    [OPBootstrap logJailbreakBypass:NSStringFromClass([self class]) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return NO;
}

- (int) pm_return_0 {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return 0;
}

- (int) pm_return_1 {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return 1;
}

- (NSString *) pm_return_empty {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return @"";
}

- (NSDictionary *) pm_return_empty_dictionary {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return @{};
}

// Endfield UIAlertController hook
- (void)pm_endfield_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(void (^)(void))completion {
    // If it's a UIAlertController, silently ignore it
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        NSLog(@"PC-DEBUG: [GalgalShadow] Blocked UIAlertController for Endfield");
        if (completion) {
            completion();
        }
        return;
    }
    
    // Otherwise, present normally
    [self pm_endfield_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

// Class methods

+ (void) pm_return_2_with_completion_handler:(void (^)(NSInteger))completionHandler {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    completionHandler(2);
}

+ (NSInteger) pm_return_2 {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return 2;
}

+ (bool) pm_clsm_return_false {
    [OPBootstrap logJailbreakBypass:NSStringFromClass(self) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return false;
}

+ (bool) pm_clsm_return_true {
    [OPBootstrap logJailbreakBypass:NSStringFromClass(self) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return true;
}

+ (BOOL) pm_clsm_return_yes {
    [OPBootstrap logJailbreakBypass:NSStringFromClass(self) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return YES;
}

+ (BOOL) pm_clsm_return_no {
    [OPBootstrap logJailbreakBypass:NSStringFromClass(self) selector:NSStringFromSelector(_cmd)];
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return NO;
}

+ (int) pm_clsm_do_nothing_with_callback:(void (^)(int))callback {
    // NSLog(@"PC-DEBUG: [GalgalMask] Jailbreak Detection Attempted");
    return 0;
}

@end

@implementation GalgalShadowLoader

+ (void) load {
    [self debugLogger:@"GalgalShadow is now loading"];
    // Each detector self-gates on the per-app config set (default: none enabled).
    [self loadJailbreakBypass];
    // if ([[AppConfig shared] bypass]) [self loadEnvironmentBypass]; # disabled as it might be too powerful

    // Swizzle ATTrackingManager
    [objc_getClass("ATTrackingManager") swizzleClassMethod:@selector(requestTrackingAuthorizationWithCompletionHandler:) withMethod:@selector(pm_return_2_with_completion_handler:)];
    [objc_getClass("ATTrackingManager") swizzleClassMethod:@selector(trackingAuthorizationStatus) withMethod:@selector(pm_return_2)];

    // canResizeToFitContent
    // [objc_getClass("UIWindow") swizzleInstanceMethod:@selector(canResizeToFitContent) withMethod:@selector(pm_return_true)];
    
    // Block UIAlertController presentation to bypass Endfield jailbreak message
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.gryphline.endfield.ios"] || 
    [bundleID isEqualToString:@"com.hypergryph.endfield"]) {
        [self debugLogger:@"loading UIAlertController bypass"];
        [objc_getClass("UIViewController") swizzleInstanceMethod:@selector(presentViewController:animated:completion:) withMethod:@selector(pm_endfield_presentViewController:animated:completion:)];
    }
}

+ (BOOL) jb:(NSString *)cls {
    // Per-detector gate: a class is bypassed only if its id is in the per-app config set.
    return [[[AppConfig shared] jailbreakBypasses] containsObject:cls];
}

+ (void) loadJailbreakBypass {
    [self debugLogger:@"Jailbreak bypass loading"];
    // Swizzle NSProcessInfo to troll every app that tries to detect macCatalyst
    // [objc_getClass("NSProcessInfo") swizzleInstanceMethod:@selector(isMacCatalystApp) withMethod:@selector(pm_return_false)];
    // [objc_getClass("NSProcessInfo") swizzleInstanceMethod:@selector(isiOSAppOnMac) withMethod:@selector(pm_return_true)];

    // Some device info class
    if ([GalgalShadowLoader jb:@"UIDevice"]) [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(platform) withMethod:@selector(pm_return_empty)];
    if ([GalgalShadowLoader jb:@"UIDevice"]) [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(hwModel) withMethod:@selector(pm_return_empty)];
    if ([GalgalShadowLoader jb:@"RNDeviceInfo"]) [objc_getClass("RNDeviceInfo") swizzleInstanceMethod:@selector(getDeviceType) withMethod:@selector(pm_hook_deviceType)];
        
    // Class: UIDevice
    if ([GalgalShadowLoader jb:@"UIDevice"]) [objc_getClass("UIDevice") swizzleClassMethod:@selector(isJailbroken) withMethod:@selector(pm_clsm_return_no)];
    if ([GalgalShadowLoader jb:@"UIDevice"]) [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(isJailBreak) withMethod:@selector(pm_return_no)];
    if ([GalgalShadowLoader jb:@"UIDevice"]) [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(isJailBroken) withMethod:@selector(pm_return_no)];

    // Class: JailbreakDetectionVC
    if ([GalgalShadowLoader jb:@"JailbreakDetectionVC"]) [objc_getClass("JailbreakDetectionVC") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_no)];

    // Class: DTTJailbreakDetection
    if ([GalgalShadowLoader jb:@"DTTJailbreakDetection"]) [objc_getClass("DTTJailbreakDetection") swizzleClassMethod:@selector(isJailbroken) withMethod:@selector(pm_clsm_return_no)];

    // Class: ANSMetadata
    if ([GalgalShadowLoader jb:@"ANSMetadata"]) [objc_getClass("ANSMetadata") swizzleInstanceMethod:@selector(computeIsJailbroken) withMethod:@selector(pm_return_no)];
    if ([GalgalShadowLoader jb:@"ANSMetadata"]) [objc_getClass("ANSMetadata") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_no)];

    // Class: AppsFlyerUtils
    if ([GalgalShadowLoader jb:@"AppsFlyerUtils"]) [objc_getClass("AppsFlyerUtils") swizzleClassMethod:@selector(isJailBreakon) withMethod:@selector(pm_clsm_return_no)];
    if ([GalgalShadowLoader jb:@"AppsFlyerUtils"]) [objc_getClass("AppsFlyerUtils") swizzleClassMethod:@selector(isJailbroken) withMethod:@selector(pm_clsm_return_no)];
    if ([GalgalShadowLoader jb:@"AppsFlyerUtils"]) [objc_getClass("AppsFlyerUtils") swizzleClassMethod:@selector(isJailbrokenWithSkipAdvancedJailbreakValidation:) withMethod:@selector(pm_clsm_return_false)];

    // Class: jailBreak
    if ([GalgalShadowLoader jb:@"jailBreak"]) [objc_getClass("jailBreak") swizzleClassMethod:@selector(isJailBreak) withMethod:@selector(pm_clsm_return_false)];

    // Class: GBDeviceInfo
    if ([GalgalShadowLoader jb:@"GBDeviceInfo"]) [objc_getClass("GBDeviceInfo") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_no)];

    // Class: CMARAppRestrictionsDelegate
    if ([GalgalShadowLoader jb:@"CMARAppRestrictionsDelegate"]) [objc_getClass("CMARAppRestrictionsDelegate") swizzleInstanceMethod:@selector(isDeviceNonCompliant) withMethod:@selector(pm_return_false)];

    // Class: ADYSecurityChecks
    if ([GalgalShadowLoader jb:@"ADYSecurityChecks"]) [objc_getClass("ADYSecurityChecks") swizzleClassMethod:@selector(isDeviceJailbroken) withMethod:@selector(pm_clsm_return_false)];

    // Class: UBReportMetadataDevice
    if ([GalgalShadowLoader jb:@"UBReportMetadataDevice"]) [objc_getClass("UBReportMetadataDevice") swizzleInstanceMethod:@selector(is_rooted) withMethod:@selector(pm_return_null)];

    // Class: UtilitySystem
    if ([GalgalShadowLoader jb:@"UtilitySystem"]) [objc_getClass("UtilitySystem") swizzleClassMethod:@selector(isJailbreak) withMethod:@selector(pm_clsm_return_false)];

    // Class: GemaltoConfiguration
    if ([GalgalShadowLoader jb:@"GemaltoConfiguration"]) [objc_getClass("GemaltoConfiguration") swizzleClassMethod:@selector(isJailbreak) withMethod:@selector(pm_clsm_return_false)];

    // Class: CPWRDeviceInfo
    if ([GalgalShadowLoader jb:@"CPWRDeviceInfo"]) [objc_getClass("CPWRDeviceInfo") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: CPWRSessionInfo
    if ([GalgalShadowLoader jb:@"CPWRSessionInfo"]) [objc_getClass("CPWRSessionInfo") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: KSSystemInfo
    if ([GalgalShadowLoader jb:@"KSSystemInfo"]) [objc_getClass("KSSystemInfo") swizzleClassMethod:@selector(isJailbroken) withMethod:@selector(pm_clsm_return_false)];

    // Class: EMDSKPPConfiguration
    if ([GalgalShadowLoader jb:@"EMDSKPPConfiguration"]) [objc_getClass("EMDSKPPConfiguration") swizzleInstanceMethod:@selector(jailBroken) withMethod:@selector(pm_return_false)];

    // Class: EnrollParameters
    if ([GalgalShadowLoader jb:@"EnrollParameters"]) [objc_getClass("EnrollParameters") swizzleInstanceMethod:@selector(jailbroken) withMethod:@selector(pm_return_null)];

    // Class: EMDskppConfigurationBuilder
    if ([GalgalShadowLoader jb:@"EMDskppConfigurationBuilder"]) [objc_getClass("EMDskppConfigurationBuilder") swizzleInstanceMethod:@selector(jailbreakStatus) withMethod:@selector(pm_return_false)];

    // Class: FCRSystemMetadata
    if ([GalgalShadowLoader jb:@"FCRSystemMetadata"]) [objc_getClass("FCRSystemMetadata") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: v_VDMap
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isJailbrokenDetected) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isJailBrokenDetectedByVOS) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isDFPHookedDetecedByVOS) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isCodeInjectionDetectedByVOS) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isDebuggerCheckDetectedByVOS) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isAppSignerCheckDetectedByVOS) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(v_checkAModified) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"v_VDMap"]) [objc_getClass("v_VDMap") swizzleInstanceMethod:@selector(isRuntimeTamperingDetected) withMethod:@selector(pm_return_false)];

    // Class: SDMUtils
    if ([GalgalShadowLoader jb:@"SDMUtils"]) [objc_getClass("SDMUtils") swizzleInstanceMethod:@selector(isJailBroken) withMethod:@selector(pm_return_no)];

    // Class: OneSignalJailbreakDetection
    if ([GalgalShadowLoader jb:@"OneSignalJailbreakDetection"]) [objc_getClass("OneSignalJailbreakDetection") swizzleClassMethod:@selector(isJailbroken) withMethod:@selector(pm_clsm_return_no)];

    // Class: DigiPassHandler
    if ([GalgalShadowLoader jb:@"DigiPassHandler"]) [objc_getClass("DigiPassHandler") swizzleInstanceMethod:@selector(rootedDeviceTestResult) withMethod:@selector(pm_return_no)];

    // Class: AWMyDeviceGeneralInfo
    if ([GalgalShadowLoader jb:@"AWMyDeviceGeneralInfo"]) [objc_getClass("AWMyDeviceGeneralInfo") swizzleInstanceMethod:@selector(isCompliant) withMethod:@selector(pm_return_true)];

    // Class: DTXSessionInfo
    if ([GalgalShadowLoader jb:@"DTXSessionInfo"]) [objc_getClass("DTXSessionInfo") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: DTXDeviceInfo
    if ([GalgalShadowLoader jb:@"DTXDeviceInfo"]) [objc_getClass("DTXDeviceInfo") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: JailbreakDetection
    if ([GalgalShadowLoader jb:@"JailbreakDetection"]) [objc_getClass("JailbreakDetection") swizzleInstanceMethod:@selector(jailbroken) withMethod:@selector(pm_return_false)];

    // Class: jailBrokenJudge
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(isJailBreak) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(isCydiaJailBreak) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(isApplicationsJailBreak) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(ischeckCydiaJailBreak) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(isPathJailBreak) withMethod:@selector(pm_return_false)];
    if ([GalgalShadowLoader jb:@"jailBrokenJudge"]) [objc_getClass("jailBrokenJudge") swizzleInstanceMethod:@selector(boolIsjailbreak) withMethod:@selector(pm_return_false)];

    // Class: FBAdBotDetector
    if ([GalgalShadowLoader jb:@"FBAdBotDetector"]) [objc_getClass("FBAdBotDetector") swizzleInstanceMethod:@selector(isJailBrokenDevice) withMethod:@selector(pm_return_false)];

    // Class: TNGDeviceTool
    if ([GalgalShadowLoader jb:@"TNGDeviceTool"]) [objc_getClass("TNGDeviceTool") swizzleClassMethod:@selector(isJailBreak) withMethod:@selector(pm_clsm_return_false)];
    if ([GalgalShadowLoader jb:@"TNGDeviceTool"]) [objc_getClass("TNGDeviceTool") swizzleClassMethod:@selector(isJailBreak_file) withMethod:@selector(pm_clsm_return_false)];
    if ([GalgalShadowLoader jb:@"TNGDeviceTool"]) [objc_getClass("TNGDeviceTool") swizzleClassMethod:@selector(isJailBreak_cydia) withMethod:@selector(pm_clsm_return_false)];
    if ([GalgalShadowLoader jb:@"TNGDeviceTool"]) [objc_getClass("TNGDeviceTool") swizzleClassMethod:@selector(isJailBreak_appList) withMethod:@selector(pm_clsm_return_false)];
    if ([GalgalShadowLoader jb:@"TNGDeviceTool"]) [objc_getClass("TNGDeviceTool") swizzleClassMethod:@selector(isJailBreak_env) withMethod:@selector(pm_clsm_return_false)];

    // Class: DTDeviceInfo
    if ([GalgalShadowLoader jb:@"DTDeviceInfo"]) [objc_getClass("DTDeviceInfo") swizzleClassMethod:@selector(isJailbreak) withMethod:@selector(pm_clsm_return_false)];

    // Class: SecVIDeviceUtil
    if ([GalgalShadowLoader jb:@"SecVIDeviceUtil"]) [objc_getClass("SecVIDeviceUtil") swizzleClassMethod:@selector(isJailbreak) withMethod:@selector(pm_clsm_return_false)];

    // Class: RVPBridgeExtension4Jailbroken
    if ([GalgalShadowLoader jb:@"RVPBridgeExtension4Jailbroken"]) [objc_getClass("RVPBridgeExtension4Jailbroken") swizzleInstanceMethod:@selector(isJailbroken) withMethod:@selector(pm_return_false)];

    // Class: ZDetection
    if ([GalgalShadowLoader jb:@"ZDetection"]) [objc_getClass("ZDetection") swizzleClassMethod:@selector(isRootedOrJailbroken) withMethod:@selector(pm_clsm_return_false)];
}

+ (void) loadEnvironmentBypass {
    [self debugLogger:@"Environment bypass loading"];
    // Completely nuke everything in the environment variables
    [objc_getClass("NSProcessInfo") swizzleInstanceMethod:@selector(environment) withMethod:@selector(pm_return_empty_dictionary)];
}

+ (void) debugLogger: (NSString *) message {
    NSLog(@"PC-DEBUG: %@", message);
}

@end
