#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 读取当前进程已加载 Mach-O 的 Swift 符号，并通过 arm64 Swift ABI 调用符号地址。
/// 该接口只给 SwiftEval 内部使用；所有地址在调用前都来自当前进程的已加载镜像。
@interface SEMachOSymbolResolver : NSObject

/// 返回原始符号名中包含 typeName 的 Swift 符号。每项包含 address、mangled、demangled、image。
+ (NSArray<NSDictionary<NSString *, id> *> *)symbolsContainingType:(NSString *)typeName;

/// 返回 demangled 名命中任一类型短名的 Swift 符号。缓存的整张符号表只扫描一遍，
/// 且只把匹配项桥接给 Swift，避免大 App 上跨语言转换全部符号。
+ (NSArray<NSDictionary<NSString *, id> *> *)symbolsContainingAnyTypeIn:(NSArray<NSString *> *)typeNames
    NS_SWIFT_NAME(symbols(containingAnyTypeIn:));

/// 读取 Mach-O `__swift5_fieldmd` 字段描述符，返回与传入 runtime ivar 名一一对应的
/// 所有权（strong / weak / unowned / unowned(unsafe)）；解析不到时对应项为 @""。
/// 纯 Swift 存储属性没有 type encoding、也没有 ObjC weak ivar layout，所有权只能由
/// 字段类型 mangling 的 Xw / Xo / Xu 后缀判断。只读元数据，不实例化对象或访问属性值。
+ (NSArray<NSString *> *)fieldOwnershipForIvarNames:(NSArray<NSString *> *)names
    NS_SWIFT_NAME(fieldOwnership(forIvarNames:));

/// 调用 Swift 函数。generalWords 按 x0...x7 排列，floatingWords 按 d0...d7 排列；
/// context 写入 Swift self / metatype 使用的 x20。返回 x0...x2 与 d0...d3 的原始位。
+ (NSDictionary<NSString *, NSArray<NSNumber *> *> * _Nullable)
    invokeAddress:(uintptr_t)address
          context:(uintptr_t)context
     generalWords:(NSArray<NSNumber *> *)generalWords
    floatingWords:(NSArray<NSNumber *> *)floatingWords
             error:(NSError **)error;

/// 当前是否为调用桩已实现的 ABI。现阶段仅 arm64；调用方必须先据此拒绝不兼容设备。
+ (BOOL)supportsCurrentArchitecture;

/// 安全读取堆地址的 isa，并确认它能映射到当前 ObjC runtime 的已知类。
/// 只返回类信息，不拥有或延长该对象的生命周期。
+ (NSDictionary<NSString *, id> * _Nullable)
    objectInfoAtAddress:(uintptr_t)address
                  error:(NSError **)error NS_SWIFT_NAME(objectInfo(atAddress:));

/// 枚举对象及父类声明的 ObjC property，并按 getter 的真实返回编码安全装箱。
/// 单个 getter 抛出的 NSException 会转成该属性的 error 字段，不中断其余属性读取。
+ (NSDictionary<NSString *, id> *)objectiveCInfoForObject:(id)object
                                            maxProperties:(NSUInteger)maxProperties
    NS_SWIFT_NAME(objectiveCInfo(object:maxProperties:));

/// UIKit / QuartzCore 对象的反射和 getter 必须在主线程执行。
+ (BOOL)requiresMainThreadForObject:(id)object
    NS_SWIFT_NAME(requiresMainThread(object:));

/// 使用 NSInvocation 调用 ObjC 方法；返回字典中的 value 已按返回类型装箱，
/// isVoid 用于区分 void 与返回 nil。arguments 只接受对象或 NSNumber 标量。
+ (NSDictionary<NSString *, id> * _Nullable)
    invokeObjectiveCTarget:(id)target
              selectorName:(NSString *)selectorName
                 arguments:(NSArray *)arguments
                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
