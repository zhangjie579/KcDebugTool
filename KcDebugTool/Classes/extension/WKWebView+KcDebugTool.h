//
//  WKWebView+KcDebugTool.h
//  OCTest
//
//  Created by samzjzhang on 2020/7/29.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <WebKit/WebKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface WKWebView (KcDebugTool)

/// 调用JSBridge
- (void)kc_callJSBridgeWithPath:(NSString *)path query:(nullable NSDictionary<NSString *, id> *)query;

/// 调用JSBridge - jsbridge://app/addSome?title=${title}&...
- (void)kc_callJSBridgeWithScheme:(NSString *)scheme
                             path:(NSString *)path
                            query:(nullable NSDictionary<NSString *, id> *)query;

/// 添加JSBridge方法
- (void)kc_addJSBridgeMethodWithSource:(NSString *)source;

#pragma mark - hook

/// hook evaluateJavaScript
+ (void)kc_hook_evaluateJavaScriptWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block;

/// hook loadRequest
+ (void)kc_hook_loadRequestWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block;

/// hook decidePolicyForNavigationAction
+ (void)kc_hook_decidePolicyForNavigationAction:(void(^)(KcHookAspectInfo * _Nonnull info))block;

+ (void)kc_hook_allInstanceMethodWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block
                               filterBlock:(BOOL(^ _Nullable)(KcHookAspectInfo * _Nonnull info))filterBlock;

@end

NS_ASSUME_NONNULL_END
