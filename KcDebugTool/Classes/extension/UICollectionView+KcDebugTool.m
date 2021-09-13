//
//  UICollectionView+KcDebugTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/20.
//

#import "UICollectionView+KcDebugTool.h"
#import "KcHookModel.h"

@implementation UICollectionView (KcDebugTool)

/// 点击cell
+ (void)kc_hook_cellDidSelect {
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UICollectionView.class
                 selector:NSSelectorFromString(@"_selectItemAtIndexPath:animated:scrollPosition:notifyDelegate:deselectPrevious:performCustomSelectionAction:")
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (![info.instance isKindOfClass:UICollectionView.class]) {
            return;
        }
        [KcLogParamModel logWithKey:@"点击cell"
                             format:@"UICollectionViewDelegate: %@, indexPath: %@", [info.instance delegate], [info.arguments.firstObject description] ?: @""];
        
    } error:nil];
}

/// collectionView delegate
+ (void)kc_hook_delegateWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block {
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UICollectionView.class
                 selector:@selector(setDelegate:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"UICollectionViewDelegate: %@", info.arguments.firstObject ?: @""];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// collectionView dataSource
+ (void)kc_hook_dataSourceWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block {
    KcHookTool *tool = [[KcHookTool alloc] init];
    [tool kc_hookWithObjc:UICollectionView.class
                 selector:@selector(setDataSource:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"UICollectionViewDataSource: %@", info.arguments.firstObject ?: @""];
        if (block) {
            block(info);
        }
    } error:nil];
}

@end
