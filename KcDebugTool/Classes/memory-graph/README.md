# Memory Graph 内存图工具

类似 Xcode Memory Graph Debugger 的运行时内存图工具：不依赖源码与符号表，
直接扫描进程堆，找出目标类的存活对象、对象间的强引用关系（谁引用我 / 我引用了谁），
并用交互式 HTML 力导向图展示，同时自动检测循环引用。

## 快速开始

```bash
# 编译（macOS，无需 Xcode 工程）
swiftc -O -o mgtool Sources/MemoryGraphCore.swift Sources/main.swift

# 运行 demo（自带多处循环引用、weak / unowned 反向引用的演示对象图）
./mgtool --filter MGDemo --out output \
         --template Templates/viewer.template.html --demo

# 打开可视化报告
open output/memory_graph.html
```

## 参数

| 参数 | 说明 |
|---|---|
| `--filter` | 类名前缀（逗号分隔），只保留匹配的对象；**必填**。已注册 Swift 类通常带模块前缀；未注册泛型类使用描述符原始名称，均按类名匹配 |
| `--weak-ivar` | 兜底手动标注 weak 属性名（逗号分隔）。weak / unowned 通常已自动识别（见「已知限制」），仅在个别字段反射不可达时补充 |
| `--out` | 输出目录，生成 `graph.json` 与 `memory_graph.html`，默认 `output/` |
| `--template` | HTML 模板路径，默认 `Templates/viewer.template.html` |
| `--demo` | 构造演示对象图后扫描，便于直接验证效果 |

## 可视化功能（memory_graph.html）

- 力导向布局，节点大小 = 被引用次数，同色 = 同类，红圈 = 参与循环引用；
- 点击节点，右侧面板列出 **被谁引用**（含属性名、地址）与 **引用了谁**，点击条目可跳转；
- 拖拽移动节点 / 画布，滚轮缩放，悬停显示详情；
- 顶部支持按类名搜索、只看循环引用节点。
- 顶部「对象地址 / 类地址 / 类名」查询：对象地址直接选中并显示引用关系与一条经过它的循环链；
  类地址显示该类存活实例数与地址列表；类名也可查询，Swift 类可省略模块前缀
  （例如输入 `MGDemoSession` 匹配 `main.MGDemoSession`），点击实例进入对象详情。
  类表包含当前快照已注册但零实例的类；对象与引用边仍受命令行 `--filter` 限制。

## 工作原理

1. **堆枚举**：`malloc_get_all_zones` + 各 zone 的 introspection `enumerator`
   （`MALLOC_PTR_IN_USE_RANGE_TYPE`）枚举进程所有在用 malloc 块；
2. **对象识别**：读块首字 isa，用 libobjc 导出的 `objc_debug_isa_class_mask`
   解码类指针、`objc_debug_taggedpointer_mask` 排除 tagged pointer，
   与 `objc_copyClassList` 注册类表比对后按 `--filter` 留下目标对象；
3. **引用边**：Swift 类按受保护的 `swift_reflectionMirror_recursiveChild*` 获取
   字段名与绝对实例偏移，ObjC 类按 `class_copyIvarList` 获取 ivar；无字段信息时
   回退全字扫描。指向已识别对象即建边；**weak / unowned ivar 自动排除**——
   Swift ownership 唯一取 Mach-O `__swift5_fieldmd` 的 Xw / Xo / Xu / 无尾缀，
   ObjC 类经 ivarLayout（布局只标 strong）；
   指向非对象块（Swift Array/Dictionary 缓冲区、被过滤掉的 NSArray 等）时做
   一层透传扫描，容器内元素的引用记在容器持有者头上，属性名取容器 ivar；
   **Swift 闭包字段补扫**：闭包 / 函数类型字段宽 16 字节（函数指针 + 上下文
   指针），上下文指针在字段偏移 +8 处，反射类会补扫字段内部字（仅当该字不
   属于下一字段）；函数指针经 `dladdr` + `swift_demangle` 符号化，边名会显示
   `属性名 · closure #N in ...`，可定位到具体闭包；**嵌套透传**：block 桥接 Swift 闭包时
   捕获链为 block → 桥接上下文 → 捕获值，容器扫描按深度 3 递归穿透；
4. **循环引用**：迭代版 Tarjan 求强连通分量，size > 1 或自环的分量即循环。

### 闭包 / block 的识别方式

- **ObjC block（含 `@convention(block)`）**：堆 block 的 isa 是注册类
  （`__NSMallocBlock__` 等），正常识别为对象节点（JSON 标 `isBlock: true`）。
  注意 `class_copyIvarList` 会给 NSBlock 返回一个偏移 0 的 `isa` "ivar"，
  会把扫描退化成只扫 isa 一个字——偏移 0 恒为 isa 不算字段，仅剩 isa 时回退
  全字扫描，偏移 32 起（isa/flags/invoke/descriptor 头部之后）是捕获变量区。
  工具会符号化偏移 16 的 invoke 指针，捕获边显示 `block 捕获[N] · ...`；即使
  block 被类名前缀过滤、只作为容器透传，伪来源节点也保留该 invoke 符号。
  符号被 Release strip 掉时只能保留属性名 / 捕获槽位，不能恢复源码闭包名。
- **Swift 原生闭包**：上下文是堆块但首字是元数据指针（非注册类 isa），识别为
  匿名容器透传（标签「匿名堆块（Swift 闭包/缓冲区）」，16 字节上下文也在
  阈值内）；闭包由 Swift 函数类型属性持有时，从属性中相邻的代码指针解析
  `closure #N in ...`，捕获对象记到该具体闭包名下，`incoming` 反查同理。
  仅被 GCD / timer 等设施持有的匿名 context 自身不保存代码指针，无法可靠反推
  源闭包，明确显示「无可用代码指针」，不伪造闭包身份。
- 闭包 / block 捕获变量无强弱元数据：**实测 `[x]` 与 `[weak x]` 捕获位的堆内存
  形态完全一致**（都是原始对象指针），扫描无法区分。这类边标 `unknown`，
  只作为潜在引用展示，不参与循环检测，避免把 `[weak x]` 捕获误报为循环引用。
  `--weak-ivar` 也覆盖不到（捕获不是 ivar）。
  `weakly_referenced` 是**对象级** sticky 标记，只说明该对象被某处 weak 引用过，
  不指向任何具体边，**不能**用来判断某条边的强弱；判断泄漏请以循环引用链与
  「对象是否随页面退出而释放」为准。

### 每条边的 strong / weak / unowned 判定能力

所有边（JSON 的 `edges` / `nonStrongEdges`、报告页）都带 `ownership`：
`strong` / `unconfirmedStrong` / `weak` / `unowned` / `unownedUnsafe` /
`nonStrong` / `unknown`。

| 来源 | 能力 | 依据 |
|---|---|---|
| Swift 类属性 | **strong / weak / unowned / unowned(unsafe)**；fieldmd 描述符未匹配标 `unconfirmedStrong`（疑似 strong） | 名称与实例偏移取 `swift_reflectionMirror_recursiveChild*`；ownership 唯一取 Mach-O `__swift5_fieldmd` 的类型 mangling 尾缀（Xw / Xo / Xu / 无尾缀），不读取反射 `isStrong`；描述符匹配失败时按存储属性默认 strong 参与找环并标注未确证 |
| ObjC 类属性 | **strong / weak 准确**；其余非强标 `nonStrong` | `class_getIvarLayout`（strong）+ `class_getWeakIvarLayout`（weak）两份布局；都不在的 `@` ivar 可能是 `__unsafe_unretained`，标 `nonStrong` |
| ObjC block 捕获（显式/隐式） | **有符号时身份可定位；ownership 准确** | invoke 指针经 `dladdr` 符号化；`BlockDescriptor` extended layout（libclosure 公开 ABI）用紧凑编码 `0xXYZ`（X strong / Y byref / Z weak）或 `0xPN` 字节串（P=3 strong / 4 byref / 5 weak / 6 unretained）。实测 strong block `layout=0x100`、weak block `layout=0x001` |
| Swift 原生闭包捕获（显式/隐式） | **有符号的属性闭包可定位；可证明偏移的捕获可判 ownership，其余标 `unknown`** | Swift 函数字段的代码指针可符号化为 `closure #N in ...`；上下文 `HeapLocalVariableMetadata` 的 `CaptureDescription` 指向 `__swift5_capture`，CaptureTypeRecord 的 Xw / Xo / Xu / 无尾缀给出 ownership；weak / unowned 可继续按单字定位，无尾缀 strong 可能是多字值，其后没有逐槽 offset，无法可靠定位时降级 |
| `@convention(block)` 桥接 block | **不能，标 `unknown`** | 桥接 block 无 `BLOCK_HAS_EXTENDED_LAYOUT`（实测 flags=0x43000002）；弱捕获在 Swift 上下文层 |

`nonStrongEdges` / `nonStrongOutgoing` 单独存放 weak / unowned / nonStrong 边，
不参与强引用图与找环；`nonStrongFields` 列出字段级语义，即使 unowned 槽位
不指向对象地址（无法成边）也如实给出。Swift 闭包上下文通过首字指向
`HeapLocalVariableMetadata`（kind 0x400）识别为闭包上下文；可定位捕获槽按
CaptureTypeRecord 标注，无法定位的槽标 `unknown`，数组缓冲区仍标 `strong`。

报告页把「参与找环的强引用」、`unknown`、确认非强三组分开展示；循环检测使用
confirmed `strong` 与 `unconfirmedStrong`，真正的 `unknown`（闭包 / 容器透传无元数据）
不会出现在循环引用链中。Swift 反射字段名与 ObjC ivar 名存在
`delegate` / `_delegate` 差异时会做唯一规范化匹配，把 fieldmd ownership 同步写到
实际扫描偏移，避免 weak 字段因名称差异回退成 strong。FieldDescriptor 的类型名可能
含 symbolic reference，无法按普通 C 字符串稳定 demangle；解析器会保留全部描述符，
并在类名不可用时限定同一 Mach-O 镜像，按整组反射字段的最大重合度匹配。只有最佳
候选对 ownership 一致时才采信，避免 `delegate`、`viewModel` 等跨类同名字段串味。

**`unknown` 与 `unconfirmedStrong` 必须分开**：`unknown` 是「语义上真的可能不是
引用」——闭包捕获 / 容器透传没有 capture 元数据，堆内存形态上强捕获与 `[weak x]`
一致，只能展示、不能参与找环。`unconfirmedStrong` 是「类存储属性的所有权元数据
不可用」（描述符未匹配 / 类型 mangling 解析失败），但 Swift / ObjC 存储属性默认
strong，weak / unowned 是显式修饰，缺的只是确证而不是语义。此前两者共用
`unknown` 并一刀切排除出找环，导致普通强引用环被整条切断：例如
`RoomViewController.msgContainerView`（lazy）⇄ `RoomMsgContainView.viewController`
（带 didSet 的 strong 存储属性），两个字段都因描述符匹配失败被降级，环查不出来。
现在这类边按默认 strong 参与找环，徽标显示「疑似 strong（类属性元数据缺失）」、
循环链标注「含未确证边」，不冒充 confirmed；若实际声明是 weak，需人工核对。

**任意地址读取安全性**：容器首字、block descriptor / layout 字节串都可能是垃圾值
（真机实测 `_glyphs` 容器首字为 `0x10d010101030110`）。`dladdr` 只能确认「地址落在
某个 image 范围内」，不保证可解引用，直接 load 会 `EXC_BAD_ACCESS`。现统一用 Mach
`vm_read_overwrite` 读取：无效地址返回 `KERN_FAILURE`，工具拿到 nil 就跳过；元数据
读不到时容器边标 `unknown`（保守），绝不退回 strong 或崩溃。

**反射守卫与 weak 误判修复**：Swift 类不调用会强制 realize 的 ObjC ivar API；
先用 class_data_bits_t 的 Swift 标志分流。只要元数据不在 malloc 堆上（防崩溃守卫）
且镜像位于 App bundle 内，reflectionMirror SPI 只读取字段名、类型和绝对偏移，
`isStrong` 明确忽略；ownership 始终由 fieldmd 决定。主程序、Xcode 16+ Debug
Dylib Support 生成的 debug dylib，以及内嵌 framework / Pod 都必须放行；bundle 外
的系统动态库不放行。
Aspects / KVO 等运行时动态子类的 metadata 位于 malloc 堆，不能直接反射；工具会
向上找到最近的 App 静态父类，用父类字段元数据与绝对偏移恢复继承属性的 ownership。
反射可用但 fieldmd 描述符匹配失败的 Swift 字段标 `unconfirmedStrong`（按存储属性
默认 strong 参与找环，明确标注未确证）；反射完全不可用时字段表为空，回退逐字扫描，
同样按默认 strong 处理，不冒充 `unknown`。真正标 `unknown` 的只有闭包 / 容器透传
这类语义上无法判定的边。

> 调用 `enumerator` 必须通过导入的 `malloc_introspection_t` 字段访问（arm64 上该函数指针
> 带 `__ptrauth` PAC 签名，手动按裸指针 load 出来调用会崩溃）；同理 `objc_copyClassList`
> 的结果不能经 `AutoreleasingUnsafeMutablePointer<AnyClass>` 下标读取（会触发 ObjC 消息
> 转发崩溃），需按裸内存逐字读。

## 接入 iOS App

堆枚举与 isa 解码 API 在 iOS 同样可用（FBAllocationTracker 同款做法）。

**准备**：把 `Templates/viewer.template.html` 加入 App target（Debug 包）。

**Debug 菜单触发**（复现疑似泄漏的操作路径之后）：

### 直接打开查询页（无需预先选中对象）

Objective-C 项目在 Debug 菜单按钮里调用：

```objc
#import <KcDebugTool/KcDebugTool-Swift.h>

[MemoryGraphManager openMemoryGraphFrom:self];
```

这会立即打开空白的 WKWebView 查询页，**打开时不扫描堆**。在网页输入当前进程的
对象地址、类地址或类名并点击「查询」后，才在后台识别堆对象并生成结果；
类名支持省略 Swift 模块前缀。类查询可点击某个存活实例，继续查看其引用图和循环链。
类名/类地址默认走快速路径：只枚举运行时类表和 malloc 块首字，不建立完整对象图；
结果页可点「完整扫描此类」补查未注册的 Swift 泛型类。对象地址默认只做一轮
全堆反查和有限预算的查环；结果页可点「完整扫描引用链」追加第二层反查并扩大
查环预算。每次查询都是当前进程的新快照，不缓存上次对象地址。

### 页面退出后复查（推荐）

在准备退出目标页面时启动观察；`from:` 传退出后仍显示的调试入口页面，
也可传 `nil` 让工具查找当前最上层页面。入口只保存目标地址和 weak 引用，
不会因诊断闭包强持有目标。默认可延迟 2 秒，需在调用后正常 pop / dismiss 目标页面：

```objc
#import <KcDebugTool/KcDebugTool-Swift.h>

[MemoryGraphManager watchDeallocationOf:targetViewController
                                   from:self
                                  after:2.0];
[self.navigationController popViewControllerAnimated:YES];
```

复查报告显示目标是否仍存活、前后各类实例数、原地址仍在数与新增地址数；
目标存活时附带引用图和循环链。地址可能被 malloc 复用，所以目标释放与否以
weak 观察为准，数量差异仅用于定位可疑类。调用该入口会在当前线程先做一次
堆对象识别；建议从 Debug 菜单或页面退出调试操作调用，勿放进高频生命周期回调。
报告在 `Documents/memory_lifetime_*.html`，可从页面右上角分享。

`captureMemoryGraph(from:)` 与 `captureMemoryGraph(forAddress:from:)` 的后台任务
现在弱持有展示 VC，报告文件按地址和时间命名；如展示 VC 已退出，报告仍保存在
Documents，不会再把该 VC 留到扫描结束。

推荐按需查询：识别堆对象秒级完成，再对单个对象（如当前页面 VC）反查被谁引用、
它引用了谁；参与找环的强引用、unknown、weak / unowned 分组展示，只有参与找环的
强引用（confirmed + 未确证 strong）继续向上展开引用层级并参与找环：

```swift
import UIKit

func captureReferenceReport(of target: UIViewController, from presenter: UIViewController) {
    let targetAddress = unsafeBitCast(target, to: UInt.self)
    DispatchQueue.global(qos: .userInitiated).async {
        let scanner = MemoryGraphScanner()   // 不传前缀：引用来源可能是任意系统对象，需全量识别
        scanner.identifyObjects()
        guard let report = scanner.referenceReport(of: targetAddress, maxDepth: 2) else {
            // 目标可能已正常释放
            return
        }
        // report.outgoing：它可能持有谁；report.incoming：谁引用了它（含非强引用与层级）
        // report.cycles：经过该对象的循环引用链（完整边序列，含属性名与透传标记）
        // 自行组装展示（App 内可用 WKWebView 加载生成的 HTML）
    }
}
```

`referenceReport(of:maxDepth:)` 的 incoming 每层做一次全堆定向扫描，`maxDepth` 层即
`maxDepth` 次扫描；`maxDepth: 1` 只看直接引用者，建议 2。weak / unowned 会保留在
当前层报告和引用图中，但不会作为下一层 target，因此不会伪造成持有链。
报告页同时显示对象数、反查次数、查环展开数和搜索预算是否触顶；
「未发现环」仅表示本次搜索范围内未发现，不能代替页面退出后的释放检查。
Swift fieldmd 只解析 App bundle 内的主程序、debug dylib 与内嵌 framework / Pod，
不会扫描系统镜像；解析后按类名及「镜像 + 规范化字段名」建立倒排索引。查询新类时
只访问候选描述符，不再对每个字段遍历整份 fieldmd；Aspects / KVO 动态子类回退到
同一静态父类时也会复用已完成的反射布局。

**App 内 `MemoryGraphManager` 的三个入口**（`Sources/MemoryGraphManager.swift`）：

```objc
// 入口一：先打开空白查询页，再在网页输入地址或类名
[MemoryGraphManager openMemoryGraphFrom:self];

// 入口二：直接查当前页面 VC
[MemoryGraphManager captureMemoryGraphFrom:self];

// 入口三：直接查指定对象地址
[MemoryGraphManager captureMemoryGraphForAddress:@"0x14f2ab100" from:self];
```

查询结果共用同一套后台扫描与报告生成逻辑，主线程用 `MGWKWebViewController`
展示 `Documents/memory_lookup_*.html` 或 `Documents/reference_report_*.html`；
地址解析失败或对象已释放 / 地址失效时弹提示，不会白屏。
App 内报告 HTML 也有「对象地址 / 类地址 / 类名」输入框：通过 WKWebView 的
`memoryLookup` 消息回到原生层重新扫描，输入对象地址打开该对象的报告；
输入类地址或名称列出存活实例，点击地址继续查引用链。分享后的离线单文件
保留已有结果，但重新查询需要在 App 内打开。
`report.outgoing` / `nonStrongOutgoing` / `cycles` 等字段说明见上文。

**循环引用链**：`report.cycles` 是「从目标出发、沿强引用边最终回到目标」的完整链
（每条边带属性名 / 经容器透传标记），由 `cycleChains(through:directIncoming:maxDepth:maxChains:maxObjects:)`
定向 DFS 得到——不构建全堆边表，只展开目标可达对象。报告先连接目标的 outgoing
与反查得到的直接回指边，保留至多 100 条一边 / 两边短环；再搜索较长环（默认最多
5 条），默认最深 10 条边、最多展开 400 个对象，以覆盖经 DisposeBag / Sink 的 Rx 订阅长环。短环不会因深搜预算或排序截断而消失。
单独调用该方法时没有报告的反查边，仍按 DFS 查找。
与全图 `scan()` 的 Tarjan SCC 区别：SCC 给出「哪些对象构成环」，这里给出「具体怎么绕回来的路径」。

也可以只导出 JSON（`scanner.exportJSONData()`）用 `graph.json` 做定时快照 diff（对象数只增不减的类 = 疑似泄漏）。

全图 HTML 默认只布局入度最高的 300 个节点，搜索或「只看循环引用」可切换可见范围；
可单独打开 weak / unowned 边。每条边只有在两端属于同一个强连通分量时才标为环边。
这是诊断画布的显示限制，JSON 保留完整节点和边。

全量内存图（`scanner.scan()` + `exportHTMLData(template:)`）解析全部对象引用边并找环，
在大堆上耗时分钟级，仅确需全图时使用。

注意：`malloc_get_all_zones` / zone enumerator 属于 libmalloc 的 introspection 能力，
未公开承诺 ABI 稳定，仅用于 Debug / 内部诊断包，上架版本不建议包含。
真机验证时本仓库工程请走 `Projects/<Target>` 的既有流程（bundle install / pod install）。

## 已知限制

- **weak / unowned 引用自动识别**（实测本工具链）：
  - **Swift 定义的类：自动排除非强引用**。`recursiveChildMetadata` / Offset
    只提供名称、类型和绝对偏移；ownership 取 `__swift5_fieldmd` 的类型 mangling，
    可区分 strong、weak、unowned、unowned(unsafe)。
  - **ObjC 定义的类：自动识别**。分别解析 `class_getIvarLayout`
    与 `class_getWeakIvarLayout`，且按继承链上各类自身的 aligned instanceStart
    计算偏移；两份布局都未覆盖的 `@` ivar 保守标 `nonStrong`。
  - 字段名依赖编译产物中的 Swift reflection metadata，`@_silgen_name` SPI
    理论上随系统版本有变化风险；若个别字段反射不可达（如属性包装器改写字段名），
    用 `--weak-ivar` 兜底标注。
  - 所有对象会读取 isa 的 **weakly_referenced 位**（实测当前 arm64 运行时为
    bit2，仅作参考标记）：该位为 true 只说明对象被某处 weak 引用过，是对象级
    sticky 标记、不指向具体边，HTML 面板与控制台会如实提示，不可据此判断
    某条边的强弱。
  - 反向扫描不会调用 `swift_unknownObjectWeakLoadStrong` / `objc_loadWeakRetained`：
    堆枚举没有强持有来源对象，来源可能并发释放，把快照中的 weak storage 交给
    runtime 会崩溃。类字段仅安全读取原始槽值；ObjC / 桥接 weak 通常可恢复目标，
    native Swift side-table weak 若槽值不是对象地址则只能列出字段语义，无法建立边。
    闭包 CaptureDescriptor 又缺少逐槽 offset，推测为 weak 的捕获槽不会解引用。
- 纯 Swift 类（非 NSObject 子类）**同样支持**：已注册类可经 ObjC 类表识别；
  尚未注册的泛型类只读 Swift ClassDescriptor 原始名称，不调用 `class_getName`。
  未注册类不调用 `reflectionMirror`，以免动态 metadata 触发运行时断点；
  引用回退原始字扫描，因此这类对象的字段名和所有权可能无法确认。
- 保守扫描与 leaks 同类，指针误判可能带来少量误报边；已通过类名前缀过滤 +
  ivar 偏移扫描 + 容器仅透传一层控制噪音。
- 大堆扫描（百万级块）耗时约秒级，适合诊断场景而非线上监控。

## 输出格式（graph.json）

```json
{
  "generatedAt": "…",
  "classFilter": "MGDemo",
  "classes": [{ "address": "0x…", "name": "main.MGDemoSession", "instanceCount": 1 }],
  "nodes": [{ "address": "0x…", "classAddress": "0x…", "className": "…", "size": 48, "inDegree": 3, "inCycle": true }],
  "edges": [{ "from": "0x…", "to": "0x…", "ivar": "token", "indirect": false }],
  "cycles": [["0x…", "0x…"]]
}
```
