//
//  KcMachO.h
//  KcDebugTool_Example
//
//  Created by 张杰 on 2021/5/11.
//  Copyright © 2021 张杰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcMachO : NSObject

+ (void)log_sectionDataWithImageName:(NSString *)imageName;

@end

NS_ASSUME_NONNULL_END
