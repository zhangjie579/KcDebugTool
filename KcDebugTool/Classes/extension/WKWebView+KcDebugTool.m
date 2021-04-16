//
//  WKWebView+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/7/29.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "WKWebView+KcDebugTool.h"
#import "NSObject+KcRuntimeExtension.h"

@implementation WKWebView (KcDebugTool)

/// 调用JSBridge
- (void)kc_callJSBridgeWithPath:(NSString *)path query:(nullable NSDictionary<NSString *, id> *)query {
    [self kc_callJSBridgeWithScheme:@"jsbridge" path:path query:query];
}

/// 调用JSBridge - jsbridge://app/addSome?title=${title}&...
- (void)kc_callJSBridgeWithScheme:(NSString *)scheme
                             path:(NSString *)path
                            query:(nullable NSDictionary<NSString *, id> *)query {
    NSMutableString *javaScript = [[NSMutableString alloc] initWithFormat:@"window.location.href = '%@://%@", scheme, path];
    if (query) {
        [javaScript appendString:@"?"];
        
        [query enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            [javaScript appendFormat:@"%@=%@&", key, obj];
        }];
        
        // 最后多了个&, 删掉
        [javaScript deleteCharactersInRange:NSMakeRange(javaScript.length - 1, 1)];
    }
    
    [javaScript appendString:@"';"];
    
    [self evaluateJavaScript:javaScript.copy completionHandler:nil];
}

/// 添加JSBridge方法
- (void)kc_addJSBridgeMethodWithSource:(NSString *)source {
    WKUserScript *script = [[WKUserScript alloc] initWithSource:source
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:false];
    
    [self.configuration.userContentController addUserScript:script];
}

#pragma mark - hook

/// hook evaluateJavaScript
+ (void)kc_hook_evaluateJavaScriptWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block {
    [self.kc_hookTool kc_hookWithObjc:WKWebView.class
                             selector:@selector(evaluateJavaScript:completionHandler:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        NSString *script = info.arguments.firstObject ?: @"";
        [KcLogParamModel logWithKey:@"WKWebView.evaluateJavaScript" format:@"%@", script];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook loadRequest
+ (void)kc_hook_loadRequestWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block {
    [self.kc_hookTool kc_hookWithObjc:WKWebView.class
                             selector:@selector(loadRequest:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        NSURLRequest *request = info.arguments.firstObject;
        if (request) {
            NSDictionary *header = request.allHTTPHeaderFields;
            NSString *URLString = request.URL.absoluteString;
            [KcLogParamModel logWithKey:@"WKWebView.loadRequest" format:@" [URLString: %@] [header: %@]", URLString, header.description];
        }
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook decidePolicyForNavigationAction
+ (void)kc_hook_decidePolicyForNavigationAction:(void(^)(KcHookAspectInfo * _Nonnull info))block {
    [self.kc_hookTool kc_hookWithObjc:WKWebView.class
                             selector:@selector(setNavigationDelegate:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (!info.arguments.firstObject) {
            return;
        }
        [self.kc_hookTool kc_hookWithObjc:info.arguments.firstObject
                                 selector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)
                              withOptions:KcAspectTypeBefore
                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            WKNavigationAction *navigationAction = (WKNavigationAction *)info.arguments[1];
            [KcLogParamModel logWithKey:@"WKWebView.decidePolicyForNavigationAction" format:@" [URLString: %@]", navigationAction.request.URL.absoluteString];
            if (block) {
                block(info);
            }
        } error:nil];
    } error:nil];
}

+ (void)kc_hook_allInstanceMethodWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block
                               filterBlock:(BOOL(^ _Nullable)(KcHookAspectInfo * _Nonnull info))filterBlock {
    NSArray<NSString *> *instanceMethods = [self kc_instanceMethodListWithContainSuper:false];
    NSMutableSet<NSString *> *blackSelectorName = [NSMutableSet setWithArray:[self kc_defaultBlackSelectorName]];
    
    NSSet<NSString *> *scrollViewDelegateMethods = [NSObject kc_protocolMethodListWithProtocol:@protocol(UIScrollViewDelegate) configure:KcProtocolMethodsConfigure.defaultConfigure];
    [blackSelectorName unionSet:scrollViewDelegateMethods];
    
    [blackSelectorName addObjectsFromArray:@[
        @"_page",
        @"_didFinishLoadingDataForCustomContentProviderWithSuggestedFilename:data:",
        @"_didInvalidateDataForAttachment:",
        @"_updateVisibleContentRects",
        @"_takeViewSnapshot",
        @"_didCommitLayerTreeDuringAnimatedResize:",
        @"_hidePasswordView",
        @"scrollViewDidScroll:",
        
        // 频率太高
        @"URL",
        @"UIDelegate",
        @"_didChangeEditorState",
        @"_haveSetObscuredInsets",
        @"viewForZoomingInScrollView:",
        @"scrollView",
        @"viewForZoomingInScrollView:",
        @"_currentContentView",
        @"_setAvoidsUnsafeArea:",
        @"usesStandardContentView",
        @"_layerTreeCommitComplete",
        @"_allowsDoubleTapGestures", // 双击手势
        @"_isBackground", // 后台相关
        @"_updateScrollViewBackground",
        @"_clearSafeBrowsingWarning",
        @"_scrollingUpdatesDisabledForTesting",
        
        @"_evaluateJavaScript:forceUserGesture:completionHandler:", // 调用evaluateJavaScript会调用它
    ]];
    
    [instanceMethods enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([blackSelectorName containsObject:name]) {
            return;
        }
        
        if ([name hasPrefix:@"kc_"] ||
            [name hasPrefix:@"_print"] ||
            [name hasPrefix:@"_initialize"]) { // 过滤初始化方法
            return;
        }
        
        [self.kc_hookTool kc_hookWithObjc:WKWebView.class
                             selectorName:name
                              withOptions:KcAspectTypeBefore
                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            if (block) {
                block(info);
            }
            
            BOOL isFilter = true;
            if (filterBlock) {
                isFilter = filterBlock(info);
            }
            
            if (!isFilter) {
                return;
            }
            
            [KcLogParamModel logWithKey:@"WKWebView.InstanceMethods" format:@" [%@]", info.selectorName];
        }];
    }];
}

+ (KcHookTool *)kc_hookTool {
    return [[KcHookTool alloc] init];
}

@end
