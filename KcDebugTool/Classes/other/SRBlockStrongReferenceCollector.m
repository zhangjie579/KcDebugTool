//
//  SRBlockStrongReferenceCollector.m
//  BlockStrongReferenceObject
//
//  Created by tripleCC on 8/15/19.
//  Copyright © 2019 tripleCC. All rights reserved.
//

#import "SRBlockStrongReferenceCollector.h"

#pragma mark - block的结构 (这里的代码可以直接抄Apple源码)

enum {
    SR_BLOCK_DEALLOCATING =      (0x0001),  // runtime
    SR_BLOCK_REFCOUNT_MASK =     (0xfffe),  // runtime
    SR_BLOCK_NEEDS_FREE =        (1 << 24), // runtime
    SR_BLOCK_HAS_COPY_DISPOSE =  (1 << 25), // compiler
    SR_BLOCK_HAS_CTOR =          (1 << 26), // compiler: helpers have C++ code
    SR_BLOCK_IS_GC =             (1 << 27), // runtime
    SR_BLOCK_IS_GLOBAL =         (1 << 28), // compiler
    SR_BLOCK_USE_STRET =         (1 << 29), // compiler: undefined if !BLOCK_HAS_SIGNATURE
    SR_BLOCK_HAS_SIGNATURE  =    (1 << 30), // compiler
    SR_BLOCK_HAS_EXTENDED_LAYOUT=(1 << 31)  // compiler
};

enum {
    // Byref refcount must use the same bits as Block_layout's refcount.
    // BLOCK_DEALLOCATING =      (0x0001),  // runtime
    // BLOCK_REFCOUNT_MASK =     (0xfffe),  // runtime
    SR_BLOCK_BYREF_LAYOUT_MASK =       (0xf << 28), // compiler mask
    SR_BLOCK_BYREF_LAYOUT_EXTENDED =   (  1 << 28), // compiler extended
    SR_BLOCK_BYREF_LAYOUT_NON_OBJECT = (  2 << 28), // compiler non object
    SR_BLOCK_BYREF_LAYOUT_STRONG =     (  3 << 28), // compiler strong
    SR_BLOCK_BYREF_LAYOUT_WEAK =       (  4 << 28), // compiler weak
    SR_BLOCK_BYREF_LAYOUT_UNRETAINED = (  5 << 28), // compiler unretained
    
    SR_BLOCK_BYREF_IS_GC =             (  1 << 27), // runtime  gc
    
    SR_BLOCK_BYREF_HAS_COPY_DISPOSE =  (  1 << 25), // compiler copy、dispose
    SR_BLOCK_BYREF_NEEDS_FREE =        (  1 << 24), // runtime  need free
};

typedef enum SR_BLOCK_LAYOUT {
    SR_BLOCK_LAYOUT_NON_OBJECT_BYTES = 1,    // N bytes non-objects (和word类型相似，只是空间大小不同)
    SR_BLOCK_LAYOUT_NON_OBJECT_WORDS = 2,    // N words non-objects (Word字类型(非对象)，由于字大小一般和指针一致，1个占用8字节(考虑多个对齐后的情况))
    SR_BLOCK_LAYOUT_STRONG           = 3,    // N words strong pointers
    SR_BLOCK_LAYOUT_BYREF            = 4,    // N words byref pointers - __block
    SR_BLOCK_LAYOUT_WEAK             = 5,    // N words weak pointers
    SR_BLOCK_LAYOUT_UNRETAINED       = 6,    // N words unretained pointers
} SRBlockLayoutType;

/// __block生成的结构
struct sr_block_byref {
    void *isa;
    struct sr_block_byref *forwarding;
    volatile int32_t flags; // contains ref count
    uint32_t size;
};

struct sr_block_byref_2 {
    // requires BLOCK_BYREF_HAS_COPY_DISPOSE
    void (*byref_keep)(struct sr_block_byref *dst, struct sr_block_byref *src);
    void (*byref_destroy)(struct sr_block_byref *);
};

struct sr_block_byref_3 {
    // requires BLOCK_BYREF_LAYOUT_EXTENDED
    const char *layout;
};

/// layout, 返回的是struct sr_block_byref_3 *
static void **sr_block_byref_captured(struct sr_block_byref *a_byref) {
    uint8_t *block_byref = (uint8_t *)a_byref;
    block_byref += sizeof(struct sr_block_byref);
    if (a_byref->flags & SR_BLOCK_BYREF_HAS_COPY_DISPOSE) {
        block_byref += sizeof(struct sr_block_byref_2);
    }
    // 这里2级指针与1级指针一样, 都为struct sr_block_byref_3 *
    return (void **)block_byref;
}

static const char *sr_block_byref_extended_layout(struct sr_block_byref *a_byref) {
    if (!(a_byref->flags & SR_BLOCK_BYREF_LAYOUT_EXTENDED)) return NULL;
    // sr_block_byref_captured返回的是: struct sr_block_byref_3 *description, description->layout
    const char *layout = (char *)*sr_block_byref_captured(a_byref);
    return layout;
}

struct sr_block_descriptor_1 {
    uintptr_t reserved;
    uintptr_t size;
};

struct sr_block_descriptor_2 {
    // requires BLOCK_HAS_COPY_DISPOSE
    void (*copy)(void *dst, void *src);
    void (*dispose)(void *);
};

struct sr_block_descriptor_3 {
    // requires BLOCK_HAS_SIGNATURE
    const char *signature;
    const char *layout;     // contents depend on BLOCK_HAS_EXTENDED_LAYOUT
};

struct sr_block_layout {
    void *isa;
    volatile int32_t flags;
    int32_t reserved;
    void (*invoke)(void *, ...);
    struct sr_block_descriptor_1 *descriptor;
    char captured[0];
    /* Imported variables. */
};

static struct sr_block_descriptor_3 * _sr_block_descriptor_3(struct sr_block_layout *aBlock)
{
    if (!(aBlock->flags & SR_BLOCK_HAS_SIGNATURE)) return NULL;
    uint8_t *desc = (uint8_t *)aBlock->descriptor;
    desc += sizeof(struct sr_block_descriptor_1);
    if (aBlock->flags & SR_BLOCK_HAS_COPY_DISPOSE) {
        desc += sizeof(struct sr_block_descriptor_2);
    }
    return (struct sr_block_descriptor_3 *)desc;
}


static const char *sr_block_extended_layout(struct sr_block_layout *block) {
    if (!(block->flags & SR_BLOCK_HAS_EXTENDED_LAYOUT)) return NULL;
    struct sr_block_descriptor_3 *desc3 = _sr_block_descriptor_3(block);
    if (!desc3) return NULL;
    
    if (!desc3->layout) return "";
    return desc3->layout;
}

@interface SRLayoutItem ()
- (instancetype)initWithType:(unsigned int)type count:(NSInteger)count;
- (NSHashTable *)objectsForBeginAddress:(void *)address;
@end

@implementation SRLayoutItem{
    unsigned int _type;
    NSInteger _count;
}

- (instancetype)initWithType:(unsigned int)type count:(NSInteger)count {
    if (self = [super init]) {
        _type = type;
        _count = count;
    }
    return self;
}

/// 指针 -> objc
- (NSHashTable *)objectsForBeginAddress:(void *)address {
    if (!address) return NULL;
    
    NSHashTable *references = [NSHashTable weakObjectsHashTable];
    uintptr_t *begin = (uintptr_t *)address;
    
    // 每次指针 + 1
    for (int i = 0; i < _count; i++, begin++) {
        id object = (__bridge id _Nonnull)(*(void **)begin); // 取值
        if (object) [references addObject:object];
    }
    return references;
};

- (NSString *)description {
    return [NSString stringWithFormat:@"type: %d, count: %ld", _type, _count];
}
@end

@interface SRCapturedLayoutInfo ()
- (void)addItemWithType:(unsigned int)type count:(NSInteger)count;
@end

@implementation SRCapturedLayoutInfo {
    NSMutableArray <SRLayoutItem *> *_layoutItems;
}
- (instancetype)init {
    if (self = [super init]) {
        _layoutItems = [NSMutableArray array];
    }
    return self;
}

/*
 1).捕获对象布局
 * 按照 alignment 降序排序 (C结构体比较特殊，即使整体占用空间比指针变量大，也排在对象指针后面)
 * 其他方式排列
     * __strong 修饰对象指针变量
     * __block 修饰对象指针变量
     * __weak 修饰对象指针变量
     * 其他变量

 struct foo {
     void *p;    // 8
     int i;      // 4
     char c;     // 1
 } __attribute__ ((__packed__));

  __attribute__ ((__packed__)) 编译属性告诉编译器，按照字段的实际占用子节数进行对齐，所以创建 foo 结构体需要分配的空间大小为 8 + 4 + 1 = 13。
 * 没有的话, 为 8 + 4 +4

 NSObject *o1 = [NSObject new];
 __weak NSObject *o2 = o1;
 __block NSObject *o3 = o1;
 unsigned long long j = 4;
 int i = 3;
 char c = 'a';
 void (^blk)(void) = ^{
     i;
     c;
     o1;
     o2;
     o3;
     j;
 };

 1.按照 aligment 排序，可以得到排序顺序为 [o1 o2 o3] j i c
 2.根据 __strong、__block、__weak 修饰符对 o1 o2 o3 进行排序，可得到最终结果 o1[8] o3[8] o2[8] j[8] i[4] c[1]。
 
 2).layout
 1.inline: 指针保存实际值，而不是保存实际值的地址
    * 使用十六进制中的一位表示捕获变量的数量，所以每种类型的变量最多只能有 15 个
    * 格式: 0xXYZ, 其中 X、Y、Z 分别表示捕获 __strong、__block、__weak 修饰指针变量的个数
 2.某个类型的数量超过 15个、捕获变量的修饰类型不为这三种任何一个时，比如捕获的变量由 __unsafe_unretained 修饰，则采用另一种编码方式
    * layout 会指向一个字符串，这个字符串的每个字节以 0xPN 的形式呈现，并以 0x00 结束，P 表示变量类型，N 表示变量个数，需要注意的是，N 为 0 表示 P 类型有一个，而不是 0 个，也就是说实际的变量个数比 N 大 1。
        * p = 1  byte 类型，和 word 类型有相似的功能，只是表示的空间大小不同
        * P 为 2 表示 word 字类型（非对象），由于字大小一般和指针一致，所以这里表示占用了 8 * (N + 1) 个字节
        * P 为 3 表示 __strong 修饰的变量
        * P 为 4 表示 __block 修饰的变量
        * P 为 5 表示 __weak 修饰的变量
    * 捕获 int 等基础类型，不影响 layout 的呈现方式，layout 编码中也不会有关于基础类型的信息，除非需要基础类型的编码来辅助定位对象指针类型的位置，比如捕获含有对象指针字段的结构体
    * 只含有基本类型的结构体，同样不会影响 block 的 layout 编码信息
 */
+ (instancetype)infoForLayoutEncode:(const char *)layout {
    if (!layout) return nil;
    
    SRCapturedLayoutInfo *info = [SRCapturedLayoutInfo new];
    
    // 1 << 12, 0xXYZ 不会超过 3 * 4
    if ((uintptr_t)layout < (1 << 12)) { // inline 指针保存实际值，而不是保存实际值的地址; 使用十六进制中的一位表示捕获变量的数量，所以每种类型的变量最多只能有 15 个;
        // layout 的值以 0xXYZ 形式呈现，其中 X、Y、Z 分别表示捕获 __strong、__block、__weak 修饰指针变量的个数
        uintptr_t inlineLayout = (uintptr_t)layout;
        [info addItemWithType:SR_BLOCK_LAYOUT_STRONG count:(inlineLayout & 0xf00) >> 8]; // strong
        [info addItemWithType:SR_BLOCK_LAYOUT_BYREF count:(inlineLayout & 0xf0) >> 4];   // byref
        [info addItemWithType:SR_BLOCK_LAYOUT_WEAK count:inlineLayout & 0xf];            // weak
    } else {
        while (layout && *layout != '\x00') {
            unsigned int type = (*layout & 0xf0) >> 4;
            unsigned int count = (*layout & 0xf) + 1;
            
            [info addItemWithType:type count:count];
            layout++;
        }
    }
    
    return info;
}

- (NSArray <SRLayoutItem *> *)itemsForType:(unsigned int)type {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"type = %u", type];
    return [_layoutItems filteredArrayUsingPredicate:predicate];
}

- (void)addItemWithType:(unsigned int)type count:(NSInteger)count {
    if (count <= 0) return;
    
    SRLayoutItem *item = [[SRLayoutItem alloc] initWithType:type count:count];
    [_layoutItems addObject:item];
}

- (NSString *)description {
    NSMutableString *description = [NSMutableString stringWithString:@"\n"];
    for (SRLayoutItem *item in _layoutItems) {
        [description appendString:[NSString stringWithFormat:@"%@\n", item]];
    }
    return description;
}
@end

/// 添加到哈希表
static void SRAddObjectsFromHashTable(NSHashTable *dst, NSHashTable *ori) {
    for (id object in ori.objectEnumerator) {
        [dst addObject:object];
    }
};

@implementation SRBlockStrongReferenceCollector {
    __weak id _block;
    NSEnumerator *_strongReferences;
    NSMutableArray *_blockByrefLayoutInfos;
    SRCapturedLayoutInfo *_blockLayoutInfo;
}

- (instancetype)initWithBlock:(__weak id)block {
    if (self = [super init]) {
        _block = block;
        _blockByrefLayoutInfos = [NSMutableArray array];
    }
    return self;
}

- (NSEnumerator *)exploreLayoutInfos {
    NSHashTable *objects = [self strongReferencesForBlockLayout:(__bridge void *)(_block)];
    return [objects objectEnumerator];
}

/// block强引用的对象
- (NSHashTable *)strongReferencesForBlockLayout:(void *)iLayout {
    if (!iLayout) return nil;
    
    // block
    struct sr_block_layout *aLayout = (struct sr_block_layout *)iLayout;
    // block layout
    const char *extenedLayout = sr_block_extended_layout(aLayout);
    // block布局信息
    _blockLayoutInfo = [SRCapturedLayoutInfo infoForLayoutEncode:extenedLayout];
    
    NSHashTable *references = [NSHashTable weakObjectsHashTable];
    // 捕获变量的开始地址, 这里还没有进行取值操作
    uintptr_t *begin = (uintptr_t *)aLayout->captured;
    for (SRLayoutItem *item in _blockLayoutInfo.layoutItems) {
        switch (item.type) {
            case SR_BLOCK_LAYOUT_STRONG: { // strong
                NSHashTable *objects = [item objectsForBeginAddress:begin]; // 根据地址取值
                SRAddObjectsFromHashTable(references, objects);
                begin += item.count;
            } break;
            case SR_BLOCK_LAYOUT_BYREF: { // __block内的强引用
                for (int i = 0; i < item.count; i++, begin++) {
                    struct sr_block_byref *aByref = *(struct sr_block_byref **)begin;
                    NSHashTable *objects = [self strongReferenceForBlockByref:aByref];
                    SRAddObjectsFromHashTable(references, objects);
                }
            } break;
            case SR_BLOCK_LAYOUT_NON_OBJECT_BYTES: { // 这里是 + item.count个地址
                begin = (uintptr_t *)((uintptr_t)begin + item.count);
            } break;
            default: { // + item.count * 8, 因为begin是指针类型
                begin += item.count;
            } break;
        }
    }
    
    return references;
}

/* __block内的强引用
 1.在存在 layout 的情况下，byref 使用 8 个字节保存 layout 编码信息，并紧跟着在 layout 字段后存储捕获的变量。
 2.不存在 layout
 */
- (NSHashTable *)strongReferenceForBlockByref:(void *)iByref {
    if (!iByref) return nil;
    
    struct sr_block_byref *aByref = (struct sr_block_byref *)iByref;
    NSHashTable *references = [NSHashTable weakObjectsHashTable];
    int32_t flag = aByref->flags & SR_BLOCK_BYREF_LAYOUT_MASK;
    
    switch (flag) {
        case SR_BLOCK_BYREF_LAYOUT_STRONG: { // 直接携带 __strong 修饰的变量，则不需要关心 layout 编码，直接从结构尾部获取指针变量值即可
            void **begin = sr_block_byref_captured(aByref);
            id object = (__bridge id _Nonnull)(*(void **)begin);
            if (object) [references addObject:object];
        } break;
        case SR_BLOCK_BYREF_LAYOUT_EXTENDED: { // 先得到布局信息，然后遍历这些布局信息，计算偏移量，获取强引用对象地址
            const char *layout = sr_block_byref_extended_layout(aByref);
            SRCapturedLayoutInfo *info = [SRCapturedLayoutInfo infoForLayoutEncode:layout];
            [_blockByrefLayoutInfos addObject:info];
            
            // 因为sr_block_byref_captured返回的是struct sr_block_byref_3 *位置, 捕获对象的开始是在下一个位置
            uintptr_t *begin = (uintptr_t *)sr_block_byref_captured(aByref) + 1;
            for (SRLayoutItem *item in info.layoutItems) {
                switch (item.type) {
                    case SR_BLOCK_LAYOUT_NON_OBJECT_BYTES: {
                        begin = (uintptr_t *)((uintptr_t)begin + item.count);
                    } break;
                    case SR_BLOCK_LAYOUT_STRONG: {
                        NSHashTable *objects = [item objectsForBeginAddress:begin];
                        SRAddObjectsFromHashTable(references, objects);
                        begin += item.count;
                    } break;
                    default: {
                        begin += item.count;
                    } break;
                }
            }
        } break;
        default: break;
    }
    
    return references;
}

- (NSArray<SRCapturedLayoutInfo *> *)blockByrefLayoutInfos {
    if (!_blockByrefLayoutInfos) [self exploreLayoutInfos];

    return _blockByrefLayoutInfos;
}

- (SRCapturedLayoutInfo *)blockLayoutInfo {
    if (!_blockLayoutInfo) [self exploreLayoutInfos];
    
    return _blockLayoutInfo;
}

- (NSEnumerator *)strongReferences {
    if (!_strongReferences) _strongReferences = [self exploreLayoutInfos];
    
    return _strongReferences;
}
@end

@implementation NSObject (KcBlock)

- (NSArray<id> *)kc_blockStrongReferences {
    SRBlockStrongReferenceCollector *collector = [[SRBlockStrongReferenceCollector alloc] initWithBlock:self];
    return collector.strongReferences.allObjects;
}

@end
