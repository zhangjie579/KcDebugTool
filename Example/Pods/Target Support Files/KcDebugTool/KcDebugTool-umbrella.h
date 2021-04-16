#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "KcDebugTool.h"
#import "KcHookClassManager.h"
#import "KcHookProjectProtocol.h"
#import "KcDebugLayout.h"
#import "NSMethodSignature+KcExtension.h"
#import "NSObject+KcMethodExtension.h"
#import "NSObject+KcRuntimeExtension.h"
#import "NSString+KcExtension.h"
#import "UIApplication+KcDebugTool.h"
#import "UIView+KcDebugTool.h"
#import "UIViewController+KcDebugTool.h"
#import "UIWindow+KcDebugTool.h"
#import "WKWebView+KcDebugTool.h"
#import "KcHookModel.h"
#import "KcHookTool.h"
#import "KcDebugView.h"
#import "KcFluencyMonitor.h"
#import "KcMachOHelper.h"
#import "KcAspects.h"
#import "KcMethodCallStack.h"
#import "SMCallLib.h"
#import "SMCallStack.h"
#import "KcFloatingWindow.h"
#import "KcGlobalWindowBtn.h"
#import "KcScrollViewTool.h"
#import "KcDebugTool.h"
#import "KcHookClassManager.h"
#import "KcHookProjectProtocol.h"
#import "KcFloatingWindow.h"
#import "KcGlobalWindowBtn.h"
#import "KcScrollViewTool.h"
#import "KcDebugLayout.h"
#import "NSMethodSignature+KcExtension.h"
#import "NSObject+KcMethodExtension.h"
#import "NSObject+KcRuntimeExtension.h"
#import "NSString+KcExtension.h"
#import "UIApplication+KcDebugTool.h"
#import "UIView+KcDebugTool.h"
#import "UIViewController+KcDebugTool.h"
#import "UIWindow+KcDebugTool.h"
#import "WKWebView+KcDebugTool.h"
#import "KcHookModel.h"
#import "KcHookTool.h"
#import "KcDebugView.h"
#import "KcFluencyMonitor.h"
#import "KcMachOHelper.h"
#import "KcAspects.h"
#import "KcMethodCallStack.h"
#import "SMCallLib.h"
#import "SMCallStack.h"

FOUNDATION_EXPORT double KcDebugToolVersionNumber;
FOUNDATION_EXPORT const unsigned char KcDebugToolVersionString[];

