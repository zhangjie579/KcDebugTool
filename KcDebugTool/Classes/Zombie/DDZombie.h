////  HYZombie.h
//  DDZombieDetector
//
//  Created by Alex Ting on 2018/7/14.
//  Copyright © 2018年 Alex. All rights reserved.
//

#import <Foundation/Foundation.h>

//class DDThreadStack;

@interface DDZombie : NSObject

@property (nonatomic, assign)Class realClass;
//@property (nonatomic, assign)DDThreadStack *threadStack;

+ (Class)zombieIsa;
+ (NSInteger)zombieInstanceSize;

#pragma mark - threadStack

- (void)updateThreadStack:(void *)threadStack;
/// DDThreadStack *
- (void *)getThreadStack;
- (void)deleteThreadStack;

- (size_t)occupyMemorySize;

@end
