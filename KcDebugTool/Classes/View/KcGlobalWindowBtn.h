//
//  KcGlobalWindowBtn.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/12.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol KcPluginProtocol <NSObject>

/// 打开插件
- (void)start;
/// 关闭插件
- (void)end;

@end

@interface KcGlobalWindowBtn : NSObject <KcPluginProtocol>

@end

NS_ASSUME_NONNULL_END
