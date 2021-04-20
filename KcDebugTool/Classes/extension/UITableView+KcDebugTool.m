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
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UITableView.class
                 selector:NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:isCellMultiSelect:")
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (![info.instance isKindOfClass:UITableView.class]) {
            return;
        }
        [KcLogParamModel logWithKey:@"点击cell" format:@"UITableViewDelegate: %@", [info.instance delegate]];
        
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

@end
