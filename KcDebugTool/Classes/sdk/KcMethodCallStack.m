//
//  KcMethodCallStack.m
//  OCTest
//
//  Created by samzjzhang on 2020/12/17.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcMethodCallStack.h"
#import <objc/message.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stddef.h>
#import <stdint.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/time.h>

static uint64_t _min_time_cost = 1; //us
static int _max_call_depth = 3;
static pthread_key_t _thread_key;

static int recordNum = -1;
static int recordAlloc;
static kc_call_record *callRecords;

kc_call_record *kc_getCallRecords(int *number) {
    if (number) {
        *number = recordNum;
    }
    return callRecords;
};

void kc_callConfigMinTime(uint64_t us) {
    _min_time_cost = us;
}
void kc_callConfigMaxDepth(int depth) {
    _max_call_depth = depth;
}

typedef struct {
    kc_call_record *stack;
    int allocated_length;
    int index;
    bool is_main_thread;
} kc_thread_call_stack;

@implementation KcCallStackModel

+ (void)load {
    [self start];
}

+ (void)logCallStack {
    NSMutableString *string = [[NSMutableString alloc] init];
//    NSMutableArray<KcCallStackModel *> *models = [self makeCallRecords];
    NSArray<KcCallStackModel *> *models = [self makeSortedCallStack];
//    [self descriptionCallStackWithModels:models string:string];
//    NSLog(@"\n%@", string);
    [models enumerateObjectsUsingBlock:^(KcCallStackModel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [string appendFormat:@"%@\n", obj.description];
    }];
    NSLog(@"\n%@", string);
}

+ (void)descriptionCallStackWithModels:(NSArray<KcCallStackModel *> *)models string:(NSMutableString *)string {
    for (KcCallStackModel *model in models) {
        [string appendFormat:@"%@\n", model.description];
        if (model.childs.count > 0) {
            [self descriptionCallStackWithModels:model.childs string:string];
        }
    }
}

+ (void)start {
    kc_call_record_start();
}

+ (void)clearCallStack {
    recordNum = -1;
    recordAlloc = 1024;
    if (callRecords) {
        free(callRecords);
        callRecords = nil;
    }
}

+ (void)configureMinCostTime:(double)minCostTime maxCallDepth:(int)maxCallDepth {
    _min_time_cost = minCostTime * 1000;
    _max_call_depth = maxCallDepth;
}

/* 这种方式不太好, log的时候递归child, 容易栈溢出
 callRecords
 2|   0.00|    -[ViewController test1],
 1|   0.18|  -[ViewController test],
 1|   0.28|  -[ViewController btn],
 1|   2.17|  -[ViewController tableView],
 2|   0.00|    -[ViewController items],
 1|   0.15|  -[ViewController tableView:numberOfRowsInSection:],
 0|   7.46|-[ViewController viewDidLoad]
 
 
 0|   7.46|-[ViewController viewDidLoad]
 1|   0.18|  -[ViewController test]
 2|   0.00|    -[ViewController test1]
 1|   0.28|  -[ViewController btn]
 1|   2.17|  -[ViewController tableView]
 1|   0.15|  -[ViewController tableView:numberOfRowsInSection:]
 2|   0.00|    -[ViewController items]
 */
//+ (NSMutableArray<KcCallStackModel *> *)makeCallRecords {
//    NSMutableArray<KcCallStackModel *> *callRecords = [[NSMutableArray alloc] init];
//
//    int num = 0;
//    kc_call_record *records = kc_getCallRecords(&num);
//    for (int i = 0; i <= num; i++) { // 转 [QiCallTraceTimeCostModel]
//        kc_call_record *rd = &records[i];
//        KcCallStackModel *model = [KcCallStackModel new];
//        model.cls = rd->cls;
//        model.sel = rd->sel;
//        model.className = NSStringFromClass(rd->cls);
//        model.isClassMethod = class_isMetaClass(rd->cls);
//        model.timeCost = (double)rd->time / 1000000.0;
//        model.callDepth = rd->depth;
//        [callRecords addObject:model];
//    }
//
//    if (callRecords.count <= 0) {
//        return callRecords;
//    }
//
//    // 找到childs, depth为 + 1
//    NSInteger count = callRecords.count;
//    for (NSInteger i = 0; i < count; i++) {
//        KcCallStackModel *model = callRecords[i];
//        if (model.callDepth > 0) { // 数组内只留下方法的开头, 即depth = 0
//            [callRecords removeObjectAtIndex:i];
//            for (NSInteger j = i; j < count - 1; j++) { // 因为remove i, 总数少了1
//                if (callRecords[j].callDepth + 1 == model.callDepth) { // 记录child
//                    NSMutableArray<KcCallStackModel *> *sub = callRecords[j].childs;
//                    if (!sub) {
//                        sub = [[NSMutableArray alloc] init];
//                        callRecords[j].childs = sub;
//                    }
////                    [sub insertObject:model atIndex:0];
//                    [sub addObject:model];
//                    break;
//                }
//            }
//
//            i--;
//            count--;
//        }
//    }
//
//    return callRecords;
//}

/// 顺序的调用堆栈
+ (NSArray<id<KcCallStackModelProtocol>> *)makeSortedCallStack {
    NSMutableArray<id<KcCallStackModelProtocol>> *callRecords = [[NSMutableArray alloc] init];
    
    int num = 0;
    kc_call_record *records = kc_getCallRecords(&num);
    for (int i = 0; i <= num; i++) { // 转 [QiCallTraceTimeCostModel]
        kc_call_record *rd = &records[i];
        KcCallStackModel *model = [KcCallStackModel new];
        model.cls = rd->cls;
        model.sel = rd->sel;
        model.className = NSStringFromClass(rd->cls);
        model.isClassMethod = class_isMetaClass(rd->cls);
        model.timeCost = (double)rd->time / 1000000.0;
        model.callDepth = rd->depth;
        [callRecords addObject:model];
    }
    
    return [self sortedCallStack:callRecords];
}

/// zeroDepth: 顶层 depth = 0, child, child: 每一个顶层对应的child
+ (NSDictionary<NSString *, NSArray<id<KcCallStackModelProtocol>> *> *)makeCallStack {
    NSArray<id<KcCallStackModelProtocol>> *callStack = [self makeSortedCallStack];
    
    // 顶层, depth = 0
    NSMutableArray<id<KcCallStackModelProtocol>> *arrayZeroDepth = [[NSMutableArray alloc] init];
    // 每一个depth = 0的child
    NSMutableArray<NSMutableArray<id<KcCallStackModelProtocol>> *> *arrayChild = [[NSMutableArray alloc] init];
    
    for (NSInteger i = 0; i < callStack.count; i++) {
        id<KcCallStackModelProtocol> model = callStack[i];
        if (model.callDepth == 0) {
            [arrayZeroDepth addObject:model];
            // 每个头方法, 都要绑定一个子堆栈
            [arrayChild addObject:[NSMutableArray array]];
        } else {
            if (arrayChild.count <= 0) {
                [arrayChild addObject:[NSMutableArray array]];
            }
            [arrayChild.lastObject addObject:model];
        }
    }
    
    if (arrayZeroDepth.count != arrayChild.count) {
        NSAssert(arrayZeroDepth.count == arrayChild.count, @"出错了");
    }
    
    return @{
        @"zeroDepth": arrayZeroDepth.copy,
        @"child": arrayChild.copy,
    };
}

+ (NSArray<id<KcCallStackModelProtocol>> *)sortedCallStack:(NSArray<id<KcCallStackModelProtocol>> *)callRecords {
    if (callRecords.count <= 0) {
        return callRecords;
    }
    
    // 分组 - 每个完整的调用是一组, 到0为止
    NSMutableArray<NSMutableArray<id<KcCallStackModelProtocol>> *> *array = [[NSMutableArray alloc] init];
    
    @autoreleasepool {
        NSMutableArray<id<KcCallStackModelProtocol>> *child = [[NSMutableArray alloc] init];
        for (id<KcCallStackModelProtocol> model in callRecords) {
            [child addObject:model];
            if (model.callDepth == 0) {
                [array addObject:child];
                child = [[NSMutableArray alloc] init];
            }
        }
    }
    
    NSMutableArray<id<KcCallStackModelProtocol>> *result = [[NSMutableArray alloc] init];
    for (NSMutableArray<id<KcCallStackModelProtocol>> *child in array) {
        [result addObjectsFromArray:[self sortedOneCallStack:child]];
    }
    
    return result;
}

/*
5|   1.23|          -[LVPageScrollView scrollView],
4|   1.58|        -[LVPageScrollView setupUI],
3|   1.73|      -[LVPageScrollView initWithFrame:],
2|   1.82|    -[LVRoomContainerUIComponentImpl scrollView],

5|   2.02|          +[UIImage loadLiveSDKImageWithName:],
4|   2.02|        +[UIImage loadSDKImage:],
5|   6.71|          -[LVClassEngine getService:],
4|   6.72|        +[LVComUtilCore GetService:],
3|   9.24|      -[LVRoomEntryViewController coverViewWithRoomInfo:],
5|  21.14|          -[LVAudienceRoomSessionMgr setApplicationIdleTimerDisabled:],
4|  21.30|        -[LVAudienceRoomSessionMgr getAudienceSession:],
5|   0.83|          -[LVAudienceRoomViewController init],
5| 2254.99|          -[LVAudienceRoomViewController setSdkContext:],
5|   0.86|          -[LVAudienceRoomViewController setRoomContext:],
4| 2262.41|        -[LVAudienceRoomSession createRoomVc:],
5| 124.39|          -[LVAudienceRoomViewController view],
4| 126.01|        -[LVAudienceRoomNavViewController initWithRoomViewController:],

3| 2409.85|      -[LVRoomEntryViewController roomViewControllerWithRoomInfo:],
2| 2419.33|    -[LVRoomContainerUIComponentImpl setupCurrentRoomWithRoomInfo:],
1| 2421.54|  -[LVRoomContainerUIComponentImpl setupUI],

1|   0.63|  -[LVRoomContainerUIComponentAdapterImpl fetchRoomListInfoWithCurrentRoomInfo:completion:],
0| 2422.19|-[LVRoomContainerUIComponentImpl componentDidLoad],
*/
+ (NSMutableArray<id<KcCallStackModelProtocol>> *)sortedOneCallStack:(NSArray<id<KcCallStackModelProtocol>> *)callRecords {
    if (callRecords.count <= 0) {
        return [[NSMutableArray alloc] init];
    }
    
    NSMutableArray<id<KcCallStackModelProtocol>> *result = [[NSMutableArray alloc] init];
    
    NSMutableArray<NSMutableArray<id<KcCallStackModelProtocol>> *> *array = [[NSMutableArray alloc] init];
    
    // 先把第0个添加, 因为都是后面的与pre的比
    NSInteger i = 1;
    NSMutableArray<id<KcCallStackModelProtocol>> *child = [[NSMutableArray alloc] initWithObjects:callRecords[0], nil];
    while (i < callRecords.count) {
        id<KcCallStackModelProtocol> current = callRecords[i];
        NSInteger preIndex = i - 1;
        
        id<KcCallStackModelProtocol> pre = callRecords[preIndex];
        if (pre.callDepth == current.callDepth) { // 之前 = 当前
            id<KcCallStackModelProtocol> _Nullable childLast = child.lastObject; // 一组内depth最大的
            /*
             2|     0.00|    -[ViewController test1],
             1|     0.23|  -[ViewController test],
             
             1|     0.37|  -[ViewController btn],
             1|     2.27|  -[ViewController tableView],
             */
            if (childLast && childLast.callDepth > current.callDepth) { // 只需要拿最后一个跟它比, 因为last depth最大, 如果 >, 说明需要分组
                [array addObject:child];
                child = [NSMutableArray arrayWithObject:current];
            } else {
                [child addObject:current];
            }
        } else if (pre.callDepth > current.callDepth) { // 之前 > 当前 -> 说明还在递减, 插入在0
            [child insertObject:current atIndex:0];
        } else { // 新的一组
            [array addObject:child];
            child = [NSMutableArray arrayWithObject:current];
        }
        
        i++;
    }
    
    // 上面while, 没有 + 最后一组
    if (child.count > 0) {
        [array addObject:child];
    }
    
    if (array.count == 0) {
        return result;
    }
    else if (array.count == 1) {
        [result addObjectsFromArray:array[0]];
        return result;
    }
    
    [result addObjectsFromArray:array[array.count - 1]]; // 添加最后一组
    for (NSInteger i = array.count - 2; i >= 0; i--) { // 从后向前, 因为0在最后
        NSMutableArray<id<KcCallStackModelProtocol>> *child = array[i];
        if (child.count <= 0) {
            continue;
        }
        
        id<KcCallStackModelProtocol> first = child.firstObject;
        
        // 找到第1个比first depth 大的位置插入
        for (NSInteger j = 0; j < result.count; j++) {
            NSInteger nextIndex = j + 1;
            if (nextIndex >= result.count) { // 说明是最后一个
                [result addObjectsFromArray:child];
                break;
            }
            
            id<KcCallStackModelProtocol> next = result[nextIndex];
            
            if (next.callDepth >= first.callDepth) { // 找到了插入地方
                // 👻可能要用range
                [result insertObjects:child atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(nextIndex, child.count)]];
                break;
            }
        }
        
    }
    
    return result;
}

- (NSString *)path {
    return [NSString stringWithFormat:@"%s[%@ %@]", (self.isClassMethod ? "+" : "-"), self.className, self.selectorName];
}

- (NSString *)selectorName {
    NSString *name = NSStringFromSelector(self.sel);
    while ([name hasPrefix:@"aspects__"]) {
        name = [name substringFromIndex:@"aspects__".length];
    }
    return name;
}

- (NSString *)description {
    NSMutableString *str = [NSMutableString new];
    [str appendFormat:@"%2d| ",(int)_callDepth];
    [str appendFormat:@"%8.2f|",_timeCost * 1000.0];
    for (NSUInteger i = 0; i < _callDepth; i++) {
        [str appendString:@"  "];
    }
    [str appendFormat:@"%s[%@ %@]", (self.isClassMethod ? "+" : "-"), self.className, self.selectorName];
    return str;
}

@end

static inline kc_thread_call_stack *get_thread_call_stack() {
    kc_thread_call_stack *cs = pthread_getspecific(_thread_key);
    if (cs == NULL) {
        cs = calloc(1, sizeof(kc_thread_call_stack));
        cs->stack = calloc(128, sizeof(kc_call_record));
        cs->allocated_length = 64;
        cs->index = -1;
        cs->is_main_thread = pthread_main_np();
        pthread_setspecific(_thread_key, cs);
    }
    return cs;
}

/// 释放
static void release_thread_call_stack(void *ptr) {
    kc_thread_call_stack *cs = (kc_thread_call_stack *)ptr;
    if (!cs) return;
    if (cs->stack) free(cs->stack);
    free(cs);
}

void kc_call_record_start() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pthread_key_create(&_thread_key, &release_thread_call_stack);
    });
}

void kc_push_call_record(id _self, SEL _cmd) {
    kc_thread_call_stack *cs = get_thread_call_stack();
    if (!cs) {
        return;
    }
    int nextIndex = ++cs->index;
    
    if (nextIndex >= cs->allocated_length) { // 扩容
        cs->allocated_length += 64;
        cs->stack = realloc(cs->stack, cs->allocated_length * sizeof(kc_call_record));
    }
    
    // 赋值
    kc_call_record *newRecord = &cs->stack[nextIndex];
    newRecord->objc = _self;
    newRecord->cls = object_getClass(_self);
    newRecord->sel = _cmd;
    newRecord->depth = nextIndex;
    
    if (cs->is_main_thread) { // 记录time
        struct timeval now;
        gettimeofday(&now, NULL);
        newRecord->time = (now.tv_sec % 100) * 1000000 + now.tv_usec;
    }
}

void kc_pop_call_record(id _self, SEL _cmd) {
    kc_thread_call_stack *cs = get_thread_call_stack();
    if (!cs) {
        return;
    }
    
    int curIndex = cs->index;
    int nextIndex = cs->index--;
    kc_call_record *pRecord = &cs->stack[nextIndex];
    
    if (!cs->is_main_thread) {
        return;
    }
    
    // 记录time
    struct timeval now;
    gettimeofday(&now, NULL);
    uint64_t time = (now.tv_sec % 100) * 1000000 + now.tv_usec;
    if (time < pRecord->time) { // 为什么这里要 + ... ？？？
        time += 100 * 1000000;
    }
    uint64_t cost = time - pRecord->time; // 执行time
    
    if (cost > _min_time_cost && cs->index < _max_call_depth) {
        if (!callRecords) { // 创建
            recordAlloc = 1024;
            callRecords = calloc(recordAlloc, sizeof(kc_call_record));
        }
        recordNum++;
        if (recordNum >= recordAlloc) { // 扩容
            recordAlloc += 1024;
            callRecords = realloc(callRecords, sizeof(kc_call_record) * recordAlloc);
        }
        
        kc_call_record *record = &callRecords[recordNum];
        record->cls = pRecord->cls;
        record->depth = curIndex;
        record->sel = pRecord->sel;
        record->time = cost;
    }
}
