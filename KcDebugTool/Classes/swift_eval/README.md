# Swift Eval

真机运行时**受限 Swift 表达式求值器**。在调试页 / 代码里输入一段字符串：

```swift
SwiftEval.evaluate("MemoryGraphScanner.identifyObjects()")
```

就能拿到这次调用的完整结果：原始返回值、可读文本、结构化 JSON，以及「有没有返回值」。

## 先读：能做什么、不能做什么

iOS 上没有 JIT，**不能执行任意 Swift 源码**（`let` / `if` / `for` / 闭包 / 定义类型都不支持）。
本工具解析的是固定的一小套语法：`Type.method(实参)`、`name(实参)`（手动注册方法）、类型构造、
链式调用、属性、字面量。

调用分三条路径：

| 路径 | 覆盖范围 | 前提 |
| --- | --- | --- |
| **手动注册方法** | `SwiftEval.register(method:)` 暴露的任意闭包，支持位置 / 标签参数、`0x...` 对象地址实参；无需目标类型导出符号 | 调用方显式注册；DEBUG 代码里写闭包 |
| **Mach-O + Swift ABI** | 原生 Swift 的 `class func` / `static func` / 实例方法，以及 static / class 属性 getter；对象及基本数据类型参数；Swift 值或对象返回值 | arm64 真机；符号必须保留在已加载 Mach-O 中 |
| **ObjC runtime** | ObjC / `@objc` 的类方法、实例方法和类型属性 getter；对象及整数、浮点、Bool 参数和返回值 | 成员在 ObjC runtime 可见 |

对象实例的存储属性统一通过 `Mirror` 读取，并沿 `superclassMirror` 包含父类属性；读取存储属性不调用 getter、不走 KVC。仅当 Mirror 和 Swift 符号都找不到、且该成员是 ObjC runtime 明确声明的 `@property`（如 `UIViewController.view`）时，才回退到 KVC `value(forKey:)`，这一步会执行 getter。普通零参数方法不会被当作属性 getter 调用。

**自动发现是默认路径，无需注册**：工具遍历当前进程已加载镜像的 `LC_SYMTAB`，
demangle 后按类型、方法名、参数标签及数量选出唯一符号，再使用实际加载地址调用。
`Type.instanceMethod()` 会通过可用的初始化方法创建对象；初始化参数都有默认值时，会动态调用对应的
default-argument generator。`Type().instanceMethod()` 也受支持。

需要执行一段**任意调试逻辑**（符号被裁剪、类型不可见、要组合多个调用或直接改状态）时，
可改用[手动注册方法](#手动注册方法)：注册一个闭包，之后用 `name(args)` 调用，参数语法与自动发现
完全一致。两种路径可混用，注册方法优先于同名类型构造。

> 工具只做调用，不做权限控制：二进制中可发现的方法都可能被调用。仅在 DEBUG 包启用，且不要监听公网。

## 目录

| 路径 | 用途 |
| --- | --- |
| `Classes/SwiftEval.swift` | 对外 API、`EvalResult`、表达式求值器 |
| `Classes/EvalExpression.swift` | 词法 / 语法解析 |
| `Classes/SwiftMachOInvoker.swift` | Swift 符号签名解析、参数准备、返回值装箱 |
| `Classes/SEMachOSymbolResolver.m` | Mach-O 符号读取、ObjC NSInvocation 分派 |
| `Classes/SESwiftCallArm64.S` | Swift ABI 寄存器调用桥（含 x20 self / metatype） |
| `Classes/EvalRuntime.swift` | 实参取用、根变量 / 手动注册方法注册表、ObjC runtime 查找 |
| `Classes/EvalValue.swift` | 返回值装箱、可读文本与 JSON 序列化 |
| `Classes/EvalTypeDescription.swift` | 类 / 对象的属性方法清单（含父类，Swift + ObjC） |
| `Classes/SwiftEvalHTTPServer.swift` | 可选 HTTP 调试服务 |
| `Resources/eval.html` | 调试页（表达式 / 成员清单 / 历史 / 结果 / 已发现成员） |
| `SwiftEval.podspec` | 本地 pod 描述 |
| `Tests/main.swift` | macOS 命令行自检 |

## 接入

**1. Podfile**（仅调试配置引入，路径按 target 目录调整）：

```ruby
pod 'SwiftEval',
    :path => '../.././LocalPods/swift_eval/SwiftEval.podspec',
    :configurations => ['Debug', 'AdHoc', 'DebugSimulator']
```

然后按项目约定执行 `bundle install --quiet`、`bundle exec pod install --silent`。

**2. 启动调试服务**。无需引用或注册目标类型，所以 internal 类型也可以调用：

```swift
#if DEBUG
import SwiftEval

func setupSwiftEval() {
    SwiftEvalHTTPServer.startIfDebug(port: 16817)
}
#endif
```

**3. 不启动网页也能用**：

```swift
let result = SwiftEval.evaluate("MemoryGraphScanner.identifyObjects().count")
result.isSuccess        // 是否成功
result.hasReturnValue   // 有无返回值（void 方法与返回 nil 是两回事）
result.rawValue         // 原始值，例如 [HeapObject] / Int / nil
result.displayText      // 缩进可读文本
result.jsonObject       // Foundation JSON 兼容对象
result.jsonString()     // 一行拿完整 JSON（含表达式、类型、耗时、错误）

// 需要主线程语义的调试方法（碰 UI / 单例状态）时：
SwiftEval.dispatchOnMainThread = true
// 大数组展示默认截断：
SwiftEval.maxItems = 200
SwiftEval.maxDepth = 10 // 默认值及允许的最大属性展示深度

// 仅覆盖本次结果展示，不修改全局配置；有效范围 1...10
let detailed = SwiftEval.evaluate("currentView", maxDepth: 8)
```

## 表达式语法

| 写法 | 说明 |
| --- | --- |
| `name()` / `name(1, label: "x")` | 手动注册方法；支持位置 / 标签参数与 `0x...` 对象地址实参，见[手动注册方法](#手动注册方法) |
| `Type.method()` | 类方法 / static 方法；未命中时自动实例化后调同名实例方法 |
| `Module.Type.method()` | 完整 Swift 命名空间写法；跨模块存在同名类型时用于消歧 |
| `Type.method(1, "a", true, nil)` | 位置实参（字面量） |
| `Type.method(of: 0x1000, maxDepth: 2)` | Swift 风格参数标签，用于重载消歧和参数匹配 |
| `Type()` / `Type().method()` | 显式构造实例（Swift 初始化符号或 ObjC `init`） |
| `Type.method().count` | 链式调用 / 通用属性 |
| `Type.staticProperty` / `Type.classProperty` | Swift static / class 属性或 ObjC 类属性 |
| `object.property` / `Type().property` | 已有对象或临时实例的对象属性 |
| `0x12f945200.test()` / `0x12f945200.property` | 以当前进程内仍存活的对象地址调用实例方法或读取属性 |
| `.description` `.count` `.isEmpty` `.typeName` `.json` `.fields` | 任意返回值都可用的通用属性 |
| `Type.members` / `Type.typeName` | Mach-O 可发现成员清单 / 类型名 |
| `"text"` `123` `0x2a` `1.5` `true` `false` `nil` `[1,2]` `["k":1]` | 字面量 |
| `A.foo(); B.bar()` | 分号分隔多句，返回最后一句结果 |
| `// 注释` | 行注释 |

## 方法调用示例（按场景）

下面每个示例都给出 **Swift / ObjC 声明 → SwiftEval 表达式** 的对应，重点说明「下划线参数 `_`」和「别名标签」如何落到实参写法上。所有示例都可直接粘进调试页表达式框，或包进 `SwiftEval.evaluate(...)`。

### 1. 类方法 / static 方法 / class 方法

```swift
// 声明
class MemoryGraphScanner {
    static func identifyObjects() -> [HeapObject]
    class func shared() -> MemoryGraphScanner
}

// 调用（无需构造实例，直接命中 static / class 符号）
SwiftEval.evaluate("MemoryGraphScanner.identifyObjects()")
SwiftEval.evaluate("MemoryGraphScanner.shared()")
// 链式：类方法 → 通用属性
SwiftEval.evaluate("MemoryGraphScanner.identifyObjects().count")
```

- 跨模块同名时写完整命名空间消歧：`Sawa.MemoryGraphScanner.identifyObjects()`。
- 若同名 static / class 不存在、但存在同名**实例方法**，会自动先实例化再调用同名实例方法（见第 2 节）。

### 2. 对象方法（实例方法）

有三种写法，语义等价：

```swift
// ① 类名的「类方法式」写法：工具自动实例化后调同名实例方法
SwiftEval.evaluate("ViewController.reload(cache: true)")

// ② 显式构造实例后再调用
SwiftEval.evaluate("ViewController().reload(cache: true)")

// ③ 用进程内已存活对象的地址调用（最常用）
SwiftEval.evaluate("0x12f945200.reload(cache: true)")
```

- `ViewController()` 走 Swift 初始化符号；ObjC 类走 `init`。构造参数都有默认值时，会自动调用对应的 default-argument generator。
- `0x...` 必须是当前进程内仍存活、已注册到 runtime 的对象地址；普通十进制数字保持数值语义，不会被当成地址。
- 成员清单里实例方法列在 `Instance Methods:` 一节，例如 `reload(cache: Bool) -> Void (0x...) [swift]`。

### 3. 类属性 / static 属性 / class 属性

```swift
// 声明
class Config {
    static let shared: Config
    class var maxCount: Int { 3 }
}

// 调用（直接写属性名，不要加 ()）
SwiftEval.evaluate("Config.shared")          // 读取 static 属性
SwiftEval.evaluate("Config.maxCount")         // 读取 class 属性
SwiftEval.evaluate("Config.shared.maxCount")  // 链式：属性 → 属性
```

- 类属性走 Mach-O 符号的 getter；ObjC 类属性（Class Property，存在 metaclass 的 `class_getProperty`）同样以 `Type.property` 读取。
- **与方法区分**：属性不加 `()`；方法必须加 `()`（即使无参）。`Config.shared` 是属性，`Config.shared()` 会被当成无参方法解析，二者结果不同。

### 4. 对象属性（实例属性）

```swift
// 已有对象
SwiftEval.evaluate("0x12f945200.titleLabel")        // 读取实例属性
SwiftEval.evaluate("0x12f945200.titleLabel.text")   // 链式：属性 → 属性

// 临时实例
SwiftEval.evaluate("UIButton().titleLabel")
SwiftEval.evaluate("Type().someStoredProperty")
```

- 实例存储属性通过 `Mirror` 读取，并沿 `superclassMirror` 包含父类属性；**不会调用 getter 或 KVC**，因此无业务副作用。
- ObjC 声明的计算属性（`UIViewController.view`、`NSURL.path` 等）不在 Mirror 里，也没有 Swift mangled getter 符号；仅在这两条路径都落空、且 runtime 沿继承链能查到同名 `@property` 时，才用 KVC 读取。**这会执行 getter**，例如访问 `view` 会触发 view 加载。普通零参数方法（如 `reload`）没有 property 元数据，无括号访问仍报 `unknownMember`，要调用请写 `reload()`。
- `lazy` / property wrapper 的 backing ivar（`$__lazy_storage_$_name`、`_name`）会还原成业务属性名；未初始化时显示 `nil`，不会触发初始化。
- 任意返回值还有通用属性可用：`.description` / `.count` / `.isEmpty` / `.typeName` / `.json` / `.fields`。

### 5. 参数是「下划线 `_`」（无外部标签）

Swift / ObjC 的第一个参数常是 `_`（无外部名），构造实参时**直接写值、不带标签**：

```swift
// Swift 声明
func numberOfSectionsInCollectionView(_ view: Any) -> Int

// ObjC 声明（selector：numberOfSectionsInCollectionView:）
- (NSInteger)numberOfSectionsInCollectionView:(id)view;

// 调用：第一个实参无标签
SwiftEval.evaluate("0x12f945200.numberOfSectionsInCollectionView(0x12f945200)")
//                                                       ↑ 没有 of:/view: 这类标签

// 同样适用于纯 Swift
func reload(_ data: [Any])      // → Type().reload([1, 2, 3])
func setTitle(_ text: String)   // 常见于 ObjC setter
SwiftEval.evaluate("UIButton().setTitle(\"Hi\")")   // setTitle: 第一个参数即 _
```

- 成员清单里这一行写作 `numberOfSectionsInCollectionView(_: id) -> long [objc]`；`_` 即「调用时不写标签」。
- 位置实参（`obj.method(value)`）与 `_` 参数写法一致，因为第一个位置本就没有标签。

### 6. 参数是「别名 / 标签」（argument label）

Swift 的标签，或 ObjC selector 从第二段起的片段，在调用里**必须写成 `label: 实参`**。这是**重载消歧**和**参数匹配**的关键：

```swift
// Swift 声明（带标签）
func reload(cache: Bool)
func configure(title: String, subtitle: String)

// ObjC 声明（selector 第二段起成为标签）
- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle;

// 调用：每个带标签的实参都要写 label:
SwiftEval.evaluate("Type().reload(cache: true)")
SwiftEval.evaluate("Type().configure(title: \"Hello\", subtitle: \"World\")")
```

- ObjC 的 `configureWithTitle:subtitle:` → 标签取 `WithTitle` 之后的片段，即 `title:`、`subtitle:`。
- 标签写错或漏写会匹配不到符号；同名同参数个数但有不同标签的 Swift 重载，靠标签区分。
- 混合形态也很常见——第一个是 `_`、第二个起带标签：

```swift
// func index(of element: Any) -> Int  ← 第一个是 _，of: 是第二个
SwiftEval.evaluate("0x12f945200.index(0x12f945200, of: someValue)")
```

### 7. 位置实参（不带标签，按声明顺序）

当所有参数都可按位置传时，可以像普通函数一样只给值：

```swift
SwiftEval.evaluate("Type.method(1, \"a\", true, nil)")
SwiftEval.evaluate("0x12f945200.add(10, 20)")
```

- 位置实参按声明顺序填入；无法区分重载时仍建议用第 6 节的标签版。
- 字面量支持：`123`（整数）、`0x2a`（十六进制）、`1.5`（浮点）、`true`/`false`、`nil`、`"text"`（字符串）、`[1,2]`（数组）、`["k":1]`（字典）。

### 8. 组合与边界

```swift
// 类属性 + 链式属性
SwiftEval.evaluate("Config.shared.currentUser.name")

// 实例方法 + 带标签参数 + 分号多句（返回最后一句）
SwiftEval.evaluate("0x12f945200.reload(cache: true); 0x12f945200.count")

// 对象属性 + 实例方法
SwiftEval.evaluate("0x12f945200.titleLabel.sizeToFit()")

// 任意返回值的通用属性
SwiftEval.evaluate("MemoryGraphScanner.identifyObjects().typeName")
```

速查表：

| 场景 | 表达式 | 要点 |
| --- | --- | --- |
| 手动注册方法 | `name(1, label: "x")` | `SwiftEval.register(method:)` 注册的闭包，见下一节 |
| 类 / static / class 方法 | `Type.method()` | 直接命中 static/class 符号；若同名 static 缺失则自动实例化后调同名实例方法 |
| 实例方法（显式构造） | `Type().method()` | 先 `Type()` 再调用 |
| 实例方法（已有对象） | `0x....method()` | 进程内仍存活的对象地址 |
| 类 / static / class 属性 | `Type.property` | **不加 `()`** |
| 实例存储属性 | `0x....property` | `Mirror` 读取，无副作用 |
| ObjC 声明的计算属性 | `0x....view` | Swift 路径落空后按 `@property` 走 KVC，会执行 getter |
| 第一个参数 `_` | `obj.method(value)` | 实参无标签 |
| 带标签参数 | `obj.method(label: value)` | 每个标签都要写 |
| 位置实参 | `obj.method(1, 2)` | 按声明顺序填入 |


## 手动注册方法

自动发现依赖「符号还在、runtime 能看到」，遇到符号被裁剪、只想临时组合几步调用、
或直接改一个开关时，可以注册一个闭包作为**全局方法**，之后用 `name(args)` 调用。
注册方法是显式入口，不要求目标类型导出、`@objc`、可实例化，也不需要保留符号。

### 注册与调用

```swift
#if DEBUG
import SwiftEval

// 有返回值：闭包返回 Any?，会成为 EvalResult.rawValue / displayText / jsonObject
SwiftEval.register(method: "add") { args in
    try args.int(at: 0) + args.int(at: 1)       // 位置参数
}
SwiftEval.register(method: "greet") { args in
    "Hello, " + (try args.string(labeled: "name"))   // 标签参数
}

// 无返回值：hasReturnValue == false，与 void 方法一致
var verbose = false
SwiftEval.register(voidMethod: "setVerbose") { args in
    verbose = try args.bool(labeled: "enabled")
}

// 操作已存在的对象：0x... 地址会经 mach_vm_read + isa 校验还原成真实对象
SwiftEval.register(method: "inspect") { args in
    let object = try args.object(labeled: "target")
    return String(describing: object)
}
#endif
```

对应的表达式（调试页直接输入，或 `SwiftEval.evaluate(...)`）：

```swift
add(1, 2)                          // → 3，位置参数按源码顺序取
greet(name: "Sawa")                // → "Hello, Sawa"
setVerbose(enabled: true)          // → 无返回值
inspect(target: 0x10481a800)       // 地址实参
inspect(target: currentVC)         // 根变量实参（已注册的对象）
inspect(target: Config.shared)     // 链式表达式也能作为实参
add(1, 2).description              // 返回值继续链式访问
```

注册方法与类型构造共用 `name(...)` 语法节点，**同名时注册方法优先**；
`name` 不带括号会被当成类型 / 根变量查找并给出「调用需写成 `name(...)`」提示；
注册方法是全局入口而非成员，写成 `obj.name()` 无效，错误信息里会提示直接调用。

### 取参数

闭包收到 `EvalArguments`，实参已按源码顺序求值、外部标签保留，取值方式分三类：

| 需求 | 按下标 | 按标签 |
| --- | --- | --- |
| 整数 / 字符串 / 浮点 / Bool | `args.int(at: 0)`、`args.string(at: 0)`、`args.double(at: 0)`、`args.bool(at: 0)` | `args.int(labeled: "to")`、`args.string(labeled: "key")` … |
| 数组 / 字典 | `args.array(at: 0)`、`args.dictionary(at: 0)` | 先 `args.value(labeled:)` 再 `asArray()` / `asDictionary()` |
| 原始 Swift 值（对象、集合、自定义类型） | `args.raw(at: 0)`、`args.cast(at: 0, as: Foo.self)` | `args.raw(labeled:)` |
| 已存在的对象 | `args.object(at: 0)` | `args.object(labeled: "target")` |
| 数量 / 全部标签 / 原始值模型 | `args.count`、`args.labels`、`args.items` | — |

- `object(at:)` / `object(labeled:)` 接受 `0x...` 地址字面量（经 isa 校验，野指针报 `.argument`）
  或已经是对象的实参（根变量、上一步返回值）；标量会报 `.argument`，标量请用 `raw(at:)`。
- 位置参数的标签是 `nil`（`args.labels` 里显示为 `_`），标签取参只匹配显式写了 `label:` 的项。
- 参数不够、标签缺失、类型不符分别抛 `.arity` / `.argument`，都带可读原因。

### 返回值、错误与生命周期

| 情况 | 写法 | 结果 |
| --- | --- | --- |
| 有返回值 | `register(method:)` 里 `return value` | `.value(value)`，`hasReturnValue == true` |
| 有返回值但为 nil | `register(method:)` 里 `return nil` | `.value(nil)`，`displayText` 为 `nil`，**不是** void |
| 无返回值 | `register(voidMethod:)` | `.void`，`hasReturnValue == false` |
| 抛结构化错误 | `throw EvalError(kind:message:suggestion:)` | 原样透传到 `EvalResult.error`，kind / suggestion 保留 |
| 抛其它错误 | `throw SomeError` | 包装成 `.invocation`，附方法名与调用位置 |

- 闭包在**表达式求值时**才执行（与根变量 getter 一样是惰性的），也遵守
  `SwiftEval.dispatchOnMainThread`，需要碰 UI 时保持默认主线程派发即可。
- 同名重复注册以最后一次为准；`SwiftEval.unregister(method: "add")` 注销后同名类型构造恢复可用；
  `SwiftEval.registry.clear()` 会同时清空根变量与注册方法（仅供自检 / 热重载）。
- `SwiftEval.registeredMethods()` 返回排序后的方法名；`/api/catalog` 的 `methods` 字段与调试页
  左侧目录都会列出，调试页还会为前 16 个注册方法生成可点击的 `name()` 示例。
- 注册方法只是把已有闭包暴露成可远程调用的命令，**没有权限控制**。仅在 DEBUG 包注册，
  不要注册会破坏数据或越权的动作，HTTP 服务不要监听公网。

> 注册方法名必须是表达式可写的单个标识符（字母 / 下划线开头，可含数字），不带模块前缀、
> 不含点；按原样精确匹配，因此 `Module.foo()` 不会误命中注册为 `foo` 的方法。


## 成员清单（属性 / 方法）

调试页第二个输入框（或 `/api/describe`）接受 **对象地址** 或 **类名**：

```
0x12f945200
swiftTest.ViewController
UIViewController
```

输出对齐 LLDB 里 `_methodDescription` 的风格：每个类一节，从子类一路列到根类。

```
in swiftTest.ViewController:
Properties:
	@property (nonatomic, strong) UILabel *titleLabel;
	@property (ivar, strong) Int pageIndex;
	@property (ivar, weak) UIViewController? delegate;
Instance Methods:
	numberOfSectionsInCollectionView(_: id) -> long (0x105853b20) [objc]
	reload(cache: Bool) -> Void (0x104a1c2d0) [swift]
Class Methods:
	lks_visibleViewController() -> id (0x1059aab60) [objc]
in UIViewController:
...
```

- **ObjC 成员**来自 runtime：当前类 / 元类的 `class_copyPropertyList`、`class_copyMethodList` 与 `class_copyIvarList`。
  方法行与 Swift 成员统一成声明式 `name(_: Type, label: Type) -> ReturnType (0x...) [objc]`：第一个参数对应 Swift 的「_」无标签，其余用 selector 片段作标签；行尾 `[objc]` 区分来源。参数 / 返回值由 type encoding 转成 `id`、`long`、`BOOL`、`struct CGRect` 等可读名，`__C.` 模块前缀已去掉（如 `__C.UITableView` → `UITableView`），指针星号在声明式里省略。
- **Swift 成员**来自 Mach-O 符号（与 `Type.method()` 共用同一套解析规则），行尾标 `[swift]`，地址是符号加载地址。
  与同名、同参数个数的 ObjC selector 重复的会去掉；`@objc` thunk、`__allocating_init` 等编译器产物不列。
  与动态调用一样，Strip / LTO / Release 包会减少可见符号。
- 纯 Swift 类没有 `@property` 元数据，存储属性以 `(ivar, 所有权)` 行列出；runtime 不给这类 ivar 有效 type encoding 时，
  用同名 Swift getter 或 ObjC `@property` 的声明类型补出（都没有才退化为 `id`）。
  所有权有 `strong` / `weak` / `unowned` / `unowned(unsafe)` 四种，来自 Mach-O `__swift5_fieldmd` 字段描述符：
  字段类型 mangling 的尾缀 `Xw` / `Xo` / `Xu` 分别对应 weak / unowned / unowned(unsafe)，无尾缀为 strong。
  纯 Swift 存储属性拿不到 `ivar_getTypeEncoding`、`class_getWeakIvarLayout`，且实例化后用 Mirror 读 unowned 会崩，
  所以这里只读编译期元数据、不实例化对象也不读属性值，对清单无副作用。
  Strip 掉反射元数据或纯 ObjC ivar（如 `isa`）无法判定时退化为不带所有权的 `(ivar)` 行。
  `lazy` / property wrapper 的 backing ivar（`$__lazy_storage_$_name`、`_name`）还原成业务属性名，
  并与同名属性行去重，不会同时出现两行。
- 纯 Swift 类同样有 isa / superclass，继承链会走到 `_TtCs12_SwiftObject`；NSObject 子类走到 `NSObject`。
- 只读运行时元数据，不实例化对象、不调用 getter，因此不会触发业务副作用。地址输入沿用表达式求值的 isa 校验，
  仅支持当前进程内仍存活且已注册到 runtime 的对象；类名查询无此限制。
- 类名支持**不带模块前缀的短名**（如 `RoomViewController`），工具按「模块名.」之后的最后一段精确匹配。
  纯 Swift 类只在 runtime 里以 `Module.Class` 形式注册，`NSClassFromString("短名")` 恒为 nil，
  因此短名走 runtime 类表兜底解析；同一短名跨多个模块出现时，优先选 Mach-O 符号表里能解析到类型元数据的那个，
  仍不唯一则提示写完整 `Module.Class`。带 `Module.` 的完整名依旧优先直接命中。

调试页的开关对应 `includeSwift` / `includeSuper` / `includeIvars`（默认全开），另有本地筛选框、
「复制清单」以及点击成员行填入上方表达式输入框（带参数的方法需按签名补全实参）。

## 返回值

`EvalResult` 同时保留三种形态，任意 Swift 返回值都会经 `Mirror` 递归展开成 JSON，
`[HeapObject]`、`ReferenceReport`、字典、Optional 都能直接在网页里看：

| 字段 | 说明 |
| --- | --- |
| `rawValue: Any?` | 原始值，调用方可继续强转使用 / 参与链式调用 |
| `displayText: String` | 标量为 Swift 字面量；JSON 容器缩进显示；class/struct 按 Xcode/LLDB 对象格式显示 |
| `jsonObject: Any` | `NSNull` / `NSNumber` / `String` / 数组 / 字典 |
| `hasReturnValue: Bool` | `.void` 为 false，`.value(nil)` 为 true |
| `typeName: String` | 返回值动态类型短名 |
| `duration` / `error` | 耗时、错误（含 `suggestion` 说明不支持原因或消歧信息） |

`EvalReturn.void` 与 `.value(nil)` 分开，所以「没有返回值的方法」和「返回 nil 的方法」不会混淆。
展示深度 / 元素数由 `SwiftEval.maxDepth`、`maxItems` 控制；属性默认展示 10 层，且最大限制为 10 层，
避免扫描类方法返回大型对象图时拖垮调试页面。
对象（包括 UIView / NSObject）通过 `Mirror` 连同父类镜像展开；当前递归路径按对象身份检测循环引用，
遇到回环时输出对象类型与地址而不继续递归。最大展示深度强制限制为 10，网页可在运行按钮旁按请求配置。
对象输出包含 `$type`、`$address` 及 Mirror 可见的存储属性，并沿 `superclassMirror` 展开父类；lazy
backing storage 会从 `$__lazy_storage_$_name` 还原成 `name`，未初始化时显示为 `nil`，不会触发初始化。
UIKit、QuartzCore 及其业务子类会在反射入口自动切到主线程；普通 Swift/ObjC 业务对象仍在原求值线程展开。
对象展示形如 `<Module.Type: 0x...> { property = value }`；该格式只影响 `displayText`，`jsonObject`
和 HTTP 响应中的 `value` 仍保留结构化 JSON，便于网页二次处理。

十六进制字面量用作成员接收者时会按对象地址处理。工具先验证地址可读、指针对齐，并确认 `isa`
属于当前 runtime 的已知类，再进入 Swift Mach-O 或 ObjC runtime 调用；普通十进制数字仍保持数值语义。
地址不会自动延长原对象在调用前的生命周期，已释放、复用或正在并发释放的地址不受支持。
类型短名全局唯一时可直接写 `MemoryGraphScanner`；同名类型来自多个模块时应写
`Sawa.MemoryGraphScanner`。地址接收者不需要手工添加命名空间，工具会从对象 `isa` 自动取得完整类名。

## HTTP 入口

```swift
SwiftEvalHTTPServer.shared.start(port: 16817)
// 或 SwiftEvalHTTPServer.startIfDebug()（仅 DEBUG 配置编译）
```

Mac 与手机同一局域网时打开启动日志打印的设备地址。指定端口被占用时，服务会依次尝试后续端口，
最终端口可通过 `SwiftEvalHTTPServer.shared.boundPort` 读取；传入 `0` 时仍由系统自动分配。
服务是单线程、每连接单请求，耗时调用期间页面会禁用运行按钮。

| 请求 | 返回 |
| --- | --- |
| `GET /` | 调试页 |
| `GET /api/eval?expr=<urlencoded>` | `EvalResult` JSON |
| `POST /api/eval` | body 为纯表达式或 `{"expr":"..."}`，返回同上 |
| `GET /api/catalog` | `types`（已发现类型与成员）、`roots`（根变量）、`methods`（手动注册方法名） |
| `GET /api/describe?target=<地址或类名>` | 属性 / 方法清单 JSON |
| `POST /api/describe` | body 为 `{"target":"...","includeSuper":false}` 或纯 target 字符串 |

`/api/describe` 的 `includeSwift` / `includeSuper` / `includeIvars` 默认开启，传 `0` / `false` 关闭；
POST JSON 里同名布尔字段同样生效。

```bash
curl 'http://<手机IP>:16817/api/eval?expr=MemoryGraphScanner.identifyObjects().count'
# {"ok":true,"hasReturnValue":true,"type":"Int","display":"3","value":3,...}

curl 'http://<手机IP>:16817/api/describe?target=UIViewController&includeSuper=0'
# {"ok":true,"className":"UIViewController","display":"in UIViewController: ...","sections":[...],...}
```

`/api/eval` 结果字段：`ok` / `hasReturnValue` / `type` / `display` / `value` / `durationMs` / `expression`，
失败时额外有 `error` / `errorKind` / `suggestion`。

`/api/describe` 结果字段：`ok` / `target` / `className` / `isAddress` / `classCount` / `memberCount` /
`display`（上文文本）/ `sections`（`className` + `groups` → `title` + `members` →
`name` / `signature` / `source` / `argumentCount` / `address`）/ `notes`，失败时 `display` 与 `error` 为错误信息。

## ABI 与符号限制

Swift 路径仅在 arm64 上启用，最多使用 8 个普通参数寄存器与 8 个浮点参数寄存器。
参数支持 Swift `String`、Bool、整数、浮点和类对象；返回值支持能确认寄存器布局的 Swift 值，
例如对象、String、Array、Dictionary、Set 和 Optional。需要间接返回缓冲区的大型值会返回
`unsupported`，不会冒险调用。泛型方法、async、throws、inout、闭包、裸指针和结构体参数暂不支持。

ObjC 路径通过 `NSMethodSignature` / `NSInvocation` 按真实 type encoding 调用，支持对象和常见标量；
结构体、union、block 与裸指针参数或返回值会明确报错。实例存储属性读取不走 ObjC getter 或 KVC；只有 runtime 明确声明的 ObjC `@property` 才会在 Swift 路径落空后走 KVC，普通方法不会。

Mach-O 本地符号可能被 Strip、LTO 或优化移除；因此该工具面向 Debug / AdHoc。若错误提示找不到符号，
检查目标的 Strip 配置以及方法是否被链接器判定为未使用。App Store / Release 包不属于支持范围。

## 自检

arm64 macOS 可用下列混编方式做库级自检；产品验证仍以 arm64 真机为准：

```bash
cd LocalPods/swift_eval
xcrun clang -fobjc-arc -c Classes/SEMachOSymbolResolver.m -o /tmp/SEMachOSymbolResolver.o
xcrun clang -c Classes/SESwiftCallArm64.S -o /tmp/SESwiftCallArm64.o
xcrun swiftc -import-objc-header Classes/SEMachOSymbolResolver.h \
  Classes/*.swift Tests/main.swift /tmp/SEMachOSymbolResolver.o /tmp/SESwiftCallArm64.o \
  -o /tmp/swift_eval_selftest
/tmp/swift_eval_selftest
```

覆盖：Swift static / 实例方法、static / class / 对象属性、完整命名空间、无返回值、自动实例化、基本类型参数、
自定义 struct 数组返回值、带标签 / 十六进制实参、链式调用、ObjC 属性与对象/标量调用、
十六进制对象地址接收者、类名与地址的成员清单（ObjC / Swift / 父类 / ivar 所有权 strong / weak / unowned /
unowned(unsafe) / 开关 / 格式 / 错误路径）、`/api/describe` HTTP 入口、错误路径和 JSON 输出。
