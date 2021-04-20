//
//  UICollectionView+KcDebugTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/20.
//

#import <UIKit/UIKit.h>
#import "KcHookTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface UICollectionView (KcDebugTool)

/// 点击cell
+ (void)kc_hook_cellDidSelect;

/// collectionView delegate
+ (void)kc_hook_delegateWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block;

/// collectionView dataSource
+ (void)kc_hook_dataSourceWithBlock:(void(^ _Nullable)(KcHookAspectInfo * _Nonnull info))block;

@end

NS_ASSUME_NONNULL_END
