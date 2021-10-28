//
//  UITableView+KcDebugTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/20.
//

#import "UITableView+KcDebugTool.h"
#import "KcHookModel.h"

@implementation UITableView (KcDebugTool)

/// 点击cell
+ (void)kc_hook_cellDidSelect {
//    KcHookTool *tool = [[KcHookTool alloc] init];
//    [tool kc_hookWithObjc:UITableView.class
//                 selector:NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:isCellMultiSelect:")
//              withOptions:KcAspectTypeBefore
//               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        if (![info.instance isKindOfClass:UITableView.class]) {
//            return;
//        }
//        [KcLogParamModel logWithKey:@"点击cell"
//                             format:@"UITableViewDelegate: %@, indexPath: %@", [info.instance delegate], [info.arguments.firstObject description] ?: @""];
//        
//    } error:nil];
    
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UITableView.class
                 selector:@selector(setDelegate:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [tool kc_hookWithObjc:info.arguments.firstObject
                     selector:@selector(tableView:didSelectRowAtIndexPath:)
                  withOptions:KcAspectTypeBefore
                   usingBlock:^(KcHookAspectInfo * _Nonnull subInfo) {
            [KcLogParamModel logWithKey:@"点击cell"
                                 format:@"UITableViewDelegate: %@, indexPath: %@", subInfo.className, [subInfo.arguments[1] description] ?: @""];
        } error:nil];
    } error:nil];
}

/// tableView delegate
+ (void)kc_hook_delegateWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block {
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UITableView.class
                 selector:@selector(setDelegate:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"UITableViewDelegate: %@", info.arguments.firstObject ?: @""];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// tableView dataSource
+ (void)kc_hook_dataSourceWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block {
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UITableView.class
                 selector:@selector(setDataSource:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"UITableViewDataSource: %@", info.arguments.firstObject ?: @""];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// 监听自动调整contentInset
+ (void)kc_hook_adjustedContentInset {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UITableView.class
                 selector:@selector(setContentInset:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"adjustedContentInset"
                             format:@"contentInset: %@", info.arguments.firstObject ?: @""];
    } error:nil];
    
    if (@available(iOS 11.0, *)) {
        [tool kc_hookWithObjc:UITableView.class
                     selector:@selector(setContentInsetAdjustmentBehavior:)
                  withOptions:KcAspectTypeBefore
                   usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            [KcLogParamModel logWithKey:@"adjustedContentInset"
                                 format:@"adjustmentBehavior: %@", info.arguments.firstObject ?: @""];
        } error:nil];
        
        [tool kc_hookWithObjc:UITableView.class
                     selector:@selector(adjustedContentInsetDidChange)
                  withOptions:KcAspectTypeBefore
                   usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            UIEdgeInsets adjustedContentInset = [info.instance adjustedContentInset];
            [KcLogParamModel logWithKey:@"adjustedContentInset"
                                 format:@"adjustedContentInsetDidChange: %@", NSStringFromUIEdgeInsets(adjustedContentInset)];
        } error:nil];
    }
}

@end
