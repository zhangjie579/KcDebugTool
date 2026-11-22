# ObjC Eval

`KCObjCEval` 是用于调试的受限 Objective-C 表达式求值器。它解析固定语法，再通过 Objective-C runtime 或已加载 Mach-O 中的 Swift 符号调用当前进程中的方法。解析、符号查找与调用管理均用 Objective-C 实现；arm64 Swift ABI 寄存器调用使用独立汇编桩。不编译或执行任意源码。

## 接入

把 `KCObjCEval.h`、`KCObjCEval.m`、`KCObjCEvalSwiftSymbols.h`、`KCObjCEvalSwiftSymbols.m`、`KCObjCEvalSwiftCallArm64.S` 和 `KCObjCEvalSwiftStringBridge.swift` 加入需要使用它的 target，并启用 ARC。iOS 9 及以上可用；依赖 Foundation、Objective-C runtime、Mach 和 libSystem 的动态链接接口。Swift 符号调用只在 arm64 上启用；其他架构仍可调用 ObjC runtime 成员。Swift 文件只负责 `String` 的 ABI 装箱与所有权转换；解析、符号查找、参数匹配和调用管理仍由 OC 实现。建议只在 DEBUG 构建中接入，调用方自行决定是否切到主线程（例如访问 UIKit 时）。本目录是独立模块，目前没有修改仓库原有的 podspec 或示例 target。

```objc
#import "KCObjCEval.h"

KCObjCEvalResult *result = [KCObjCEval evaluate:@"[NSString stringWithFormat:@\"Hi %@\", @\"Eva\"]"];
if (result.success) {
    NSLog(@"%@", result.displayText); // Hi Eva
} else {
    NSLog(@"求值失败：%@", result.errorMessage);
}
```

`success` 表示解析和调用是否成功；`hasReturnValue` 区分 `void` 与返回 `nil` 的方法；`value` 是原始对象，标量会装箱成 `NSNumber`，结构体会装箱成 `NSValue`；`displayText` 用于直接显示。失败时 `errorMessage` 包含位置或调用原因。方法自身抛出的 Objective-C 异常也会转换为失败结果。求值会执行真实方法和属性 getter，可能改变对象状态。

## 表达式

| 写法 | 含义 |
| --- | --- |
| `[Class method]`、`[object method:arg other:arg]` | 类方法或对象方法，selector 按 OC 语法拼接 |
| `[[Class shared] work]` | 多层嵌套调用 |
| `[object child].name`、`object.name` | 零参数 getter；支持声明属性及计算属性 |
| `0x1313.ivar1.ivar2 = xx`、`object.name = @"New"` | 沿点链读取前面的对象，对最后一个属性调用 setter；返回赋入的值 |
| `@"text"`、`"text"`、`@42`、`42`、`@YES`、`YES`、`nil` | 常见字面量；对象/Swift 参数按目标类型转换 |
| `[object setName:Alice]` | 参数位置的裸词 `Alice` 作为字符串；变量名仍优先取 `variables` |
| `@[value, value]`、`@{@"key": value}` | 数组、字典字面量 |
| `123`、`-1.5`、`0x2a`、`YES`、`NO` | 数字、地址或布尔值 |
| `expr; expr` | 顺序执行，返回最后一项 |

类名优先通过 `NSClassFromString` 查找；纯 Swift 类还可通过已加载 Mach-O 中的 metadata accessor 符号查找。可使用完整名称，例如 `Module.Example`；如果类使用 `@objc(Example)` 指定了名称，则使用该名称。`@objc` 成员走 ObjC runtime；没有暴露给 ObjC 的 Swift 类方法、实例方法和属性 getter 走 Swift 符号路径。计算属性通过 getter 执行，不直接读取 ivar。

```objc
// 目标 Swift 代码：class Counter { static func add(_ a: Int, b: Int) -> Int { a + b } }
KCObjCEvalResult *r = [KCObjCEval evaluate:@"[MyModule.Counter add:@3 b:@4]"];
// r.value == @7；Swift 的第二个参数标签 b: 对应 OC selector 第二段。
KCObjCEvalResult *same = [KCObjCEval evaluate:@"[MyModule.Counter add:3 b:4]"];
// same.value == @7；整数不必加 @。

// func greet(_ name: String) -> String
KCObjCEvalResult *greeting = [KCObjCEval evaluate:@"[MyModule.Counter greet:Alice]"];
// 也可以写 greet:\"Alice\"；包含空格或标点时使用双引号，不需要 @。
```

Swift 符号路径遍历已加载镜像的符号表，用 `swift_demangle` 解析方法签名，并以 ASLR 后的地址调用。它要求目标符号未被 strip、类型 metadata accessor 可用，并在调用时位于已加载镜像。找不到符号时返回清晰错误；有多个匹配重载时拒绝猜测。

## 地址和变量替换

```objc
KCObjCEvalResult *r1 = [KCObjCEval evaluate:@"[0x112424345 test]"];

KCObjCEvalResult *r2 = [KCObjCEval evaluate:@"[self test]"
                                       variables:@{@"self": @"0x112424345"}];

KCObjCEvalResult *r3 = [KCObjCEval evaluate:@"[[self child] setTitle:@\"New\"]"
                                       variables:@{@"self": existingObject}];
```

`variables` 的 key 替换表达式中的标识符，value 可直接传对象、`NSNumber`、集合或 `NSNull`。形如 `@"0x..."` 的字符串在**对象接收者或对象类型参数**位置解析为地址；普通数值参数中的 `0x...` 保持整数语义。地址在调用前通过 Mach 读取并核对 runtime 类表，无法读取或不是已注册对象时返回错误。这个检查不能代替对象生命周期管理：调用时必须确保对象仍存活。对 Swift 值类型和 tagged pointer 不提供地址调用。

## 动态注入方法

`injectSelector:intoClass:classMethod:implementation:error:` 把新方法实际添加到目标类（类方法添加到元类），注入后普通 OC 代码和表达式均能调用。只支持 **0 到 4 个对象参数、对象返回值**；实参按 selector 顺序装入数组，`nil` 以 `NSNull` 表示。已存在的方法不会被覆盖。

```objc
NSError *error = nil;
BOOL added = [KCObjCEval injectSelector:@selector(debugGreeting:)
                              intoClass:MyObject.class
                            classMethod:NO
                         implementation:^id(id target, NSArray *arguments) {
    return [@"Hello, " stringByAppendingString:arguments[0]];
} error:&error];

KCObjCEvalResult *r = [KCObjCEval evaluate:@"[self debugGreeting:@\"Eva\"]"
                                    variables:@{@"self": myObject}];
```

注入会修改进程中的 runtime 类，建议只在调试构建使用。失败时 `error` 说明原因；成功后方法在进程生命周期内保持有效。

## 类型与限制

- ObjC runtime 路径使用方法真实的 type encoding 读写对象、Class、SEL、整数、浮点数、布尔值、指针与结构体返回值；结构体参数需要传编码匹配的 `NSValue`。不支持 block 参数、union 或 C 数组参数。
- 纯 Swift 符号路径目前支持 `Void`、`Bool`、各宽度 `Int`/`UInt`、`Float`、`Double`、`String`、类对象的参数和返回值，以及对应方法和属性 getter。`String` 占两个通用寄存器，并由 Swift 桥接文件管理其内存。Swift 集合、结构体、枚举、Optional、泛型函数和需要间接返回缓冲区的类型暂不支持；解析到这类签名会在调用前返回错误，避免按错误 ABI 执行。纯 Swift 符号调用限 arm64，且一次调用的通用/浮点参数各不得超过 8 个寄存器。
- `nil` 是对象参数的空值，不能作为标量参数。向 `nil` 接收者发送消息返回错误，便于调试定位。
- 点语法读取时调用同名零参数 getter；赋值时对最后一个属性调用 `setXxx:`，也可使用正常消息语法，例如 `[self setTitle:@"A"]`。赋值目标必须有可调用的 setter；不直接写入 ivar。右侧可使用现有表达式，裸词作为字符串，变量名优先从 `variables` 读取。
- 双引号字符串使用 JSON 兼容的转义（如 `\\n`、`\\"`）。简单裸词只在参数位置作为字符串；接收者位置仍必须是已知类、变量或对象地址。没有控制流、运算符、变量声明和任意代码执行。
- 地址检查基于调用当时的进程快照；调用方仍须保证对象在整个求值过程中存活。

## 自检

macOS 上运行 `Tests/main.m` 的命令：

```sh
sh KcDebugTool/Classes/objc_eval/Tests/run.sh
```
