//
//  KcMethodCallStack.h
//  OCTest
//
//  Created by samzjzhang on 2020/12/17.
//  Copyright © 2020 samzjzhang. All rights reserved.
//  调用堆栈

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    __unsafe_unretained id objc;
    __unsafe_unretained Class cls;
    SEL sel;
    uint64_t time; // us (1/1000 ms)
    int depth;
} kc_call_record;

void kc_call_record_start(void);

extern void kc_push_call_record(id _self, SEL _cmd);
extern void kc_pop_call_record(id _self, SEL _cmd);

void kc_callConfigMinTime(uint64_t us);
void kc_callConfigMaxDepth(int depth);
kc_call_record *kc_getCallRecords(int *number);

@protocol KcCallStackModelProtocol <NSObject>

@property (nonatomic) NSUInteger callDepth;      //Call 层级

@end

/// 调用堆栈
@interface KcCallStackModel : NSObject <KcCallStackModelProtocol>

@property (nonatomic) Class cls;
@property (nonatomic) SEL sel;
@property (nonatomic) BOOL isClassMethod;        //是否是类方法
@property (nonatomic) NSTimeInterval timeCost;   //时间消耗
@property (nonatomic) NSUInteger callDepth;      //Call 层级

@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy, readonly) NSString *selectorName;

@property (nonatomic) NSMutableArray<KcCallStackModel *> *childs;

@property (nonatomic, copy, readonly) NSString *path;

+ (void)logCallStack;

/// 顺序的调用堆栈
+ (NSArray<id<KcCallStackModelProtocol>> *)makeSortedCallStack;
//+ (NSMutableArray<KcCallStackModel *> *)makeCallRecords;

/// zeroDepth: 顶层 depth = 0, child, child: 每一个顶层对应的child
+ (NSDictionary<NSString *, NSArray<id<KcCallStackModelProtocol>> *> *)makeCallStack;

+ (void)configureMinCostTime:(double)minCostTime maxCallDepth:(int)maxCallDepth;

+ (void)start;
+ (void)clearCallStack;

@end

NS_ASSUME_NONNULL_END
