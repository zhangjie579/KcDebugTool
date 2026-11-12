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
| `--filter` | 类名前缀（逗号分隔），只保留匹配的对象；**必填**。Swift 类名带模块前缀（`模块.类名`），按最后一段匹配 |
| `--weak-ivar` | 兜底手动标注 weak 属性名（逗号分隔）。weak / unowned 通常已自动识别（见「已知限制」），仅在个别字段反射不可达时补充 |
| `--out` | 输出目录，生成 `graph.json` 与 `memory_graph.html`，默认 `output/` |
| `--template` | HTML 模板路径，默认 `Templates/viewer.template.html` |
| `--demo` | 构造演示对象图后扫描，便于直接验证效果 |

## 可视化功能（memory_graph.html）

- 力导向布局，节点大小 = 被引用次数，同色 = 同类，红圈 = 参与循环引用；
- 点击节点，右侧面板列出 **被谁引用**（含属性名、地址）与 **引用了谁**，点击条目可跳转；
- 拖拽移动节点 / 画布，滚轮缩放，悬停显示详情；
- 顶部支持按类名搜索、只看循环引用节点。

## 工作原理

1. **堆枚举**：`malloc_get_all_zones` + 各 zone 的 introspection `enumerator`
   （`MALLOC_PTR_IN_USE_RANGE_TYPE`）枚举进程所有在用 malloc 块；
2. **对象识别**：读块首字 isa，用 libobjc 导出的 `objc_debug_isa_class_mask`
   解码类指针、`objc_debug_taggedpointer_mask` 排除 tagged pointer，
   与 `objc_copyClassList` 注册类表比对后按 `--filter` 留下目标对象；
3. **引用边**：对每个对象按 `class_copyIvarList` 给出的 ivar 偏移读指针字
   （NSObject 子类的 Swift 存储属性都会暴露为 ivar；无 ivar 信息时回退全字扫描），
   指向已识别对象即建边；**weak / unowned ivar 自动排除**——Swift 类经
   `swift_reflectionMirror_*` 反射元数据的 isStrong 标记（weak/unowned 均为
   false，偏移与 ivar_getOffset 对齐），ObjC 类经 ivarLayout（布局只标 strong）；
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
`strong` / `weak` / `unowned` / `nonStrong` / `unknown`。

| 来源 | 能力 | 依据 |
|---|---|---|
| Swift 类属性 | **strong / weak / unowned** | 反射 `isStrong` 排除非强字段；Optional 非强字段统一标 weak，非 Optional 标 unowned（`unowned var value: T?` 也按 weak 展示） |
| ObjC 类属性 | **strong / weak 准确**；其余非强标 `nonStrong` | `class_getIvarLayout`（strong）+ `class_getWeakIvarLayout`（weak）两份布局；都不在的 `@` ivar 可能是 `__unsafe_unretained`，标 `nonStrong` |
| ObjC block 捕获（显式/隐式） | **有符号时身份可定位；ownership 准确** | invoke 指针经 `dladdr` 符号化；`BlockDescriptor` extended layout（libclosure 公开 ABI）用紧凑编码 `0xXYZ`（X strong / Y byref / Z weak）或 `0xPN` 字节串（P=3 strong / 4 byref / 5 weak / 6 unretained）。实测 strong block `layout=0x100`、weak block `layout=0x001` |
| Swift 原生闭包捕获（显式/隐式） | **有符号的属性闭包可定位；ownership 不能，标 `unknown`** | Swift 函数字段的代码指针可符号化为 `closure #N in ...`；上下文是 `HeapLocalVariableMetadata`（kind 0x400），只有 `OffsetToFirstCapture` 与 `CaptureDescription`，无 ownership 枚举；strong 与 weak 槽位完全相同，unowned 槽位甚至不是对象指针 |
| `@convention(block)` 桥接 block | **不能，标 `unknown`** | 桥接 block 无 `BLOCK_HAS_EXTENDED_LAYOUT`（实测 flags=0x43000002）；弱捕获在 Swift 上下文层 |

`nonStrongEdges` / `nonStrongOutgoing` 单独存放 weak / unowned / nonStrong 边，
不参与强引用图与找环；`nonStrongFields` 列出字段级语义，即使 unowned 槽位
不指向对象地址（无法成边）也如实给出。Swift 闭包上下文通过首字指向
`HeapLocalVariableMetadata`（kind 0x400）识别为「无元数据容器」，其透传边标
`unknown`，数组缓冲区仍标 `strong`。

报告页把 confirmed `strong`、`unknown`、确认非强三组分开展示；循环检测只使用
confirmed `strong`，`unknown` 不会出现在循环引用链中。Swift 反射字段名
与 ObjC ivar 名存在 `delegate` / `_delegate` 差异时会做唯一规范化匹配，把
`isStrong=false` 同步写到实际扫描偏移，避免 weak 字段因名称差异回退成 strong。

**任意地址读取安全性**：容器首字、block descriptor / layout 字节串都可能是垃圾值
（真机实测 `_glyphs` 容器首字为 `0x10d010101030110`）。`dladdr` 只能确认「地址落在
某个 image 范围内」，不保证可解引用，直接 load 会 `EXC_BAD_ACCESS`。现统一用 Mach
`vm_read_overwrite` 读取：无效地址返回 `KERN_FAILURE`，工具拿到 nil 就跳过；元数据
读不到时容器边标 `unknown`（保守），绝不退回 strong 或崩溃。

**反射守卫与 weak 误判修复**：实测 Swift 类的 `ivar_getTypeEncoding` 返回空字符串，
且 `class_getIvarLayout` / `class_getWeakIvarLayout` 都返回 nil——Swift 类若拿不到
反射元数据，就既无 `isStrong` 也无 ivarLayout。旧版按「类名无模块点号就跳过反射」
处理，导致 `@objc(自定义名)` 的 Swift 类（真机常见）的 weak 属性被默认标成 strong。
现在用「ivar 编码为空」识别 Swift 类：只要元数据不在 malloc 堆上（防崩溃守卫）
且属于主可执行文件或其同名 `.debug.dylib`，就对无点号类也尝试反射
（纯 ObjC 类不尝试，零风险）；Xcode 16+ Debug Dylib Support 会把 App 业务代码
放进 `<主可执行名>.debug.dylib`，该镜像必须放行，Pods / 系统动态库仍不放行。
Aspects / KVO 等运行时动态子类的 metadata 位于 malloc 堆，不能直接反射；工具会
向上找到最近的 App 静态父类，用父类字段元数据与绝对偏移恢复继承属性的 ownership。
反射字段同时按字段名反查 ivar 偏移，两个偏移都写入，避免偏移错位漏标。
反射确实不可用的 Swift 字段标 `unknown`，不再冒充 `strong`。

> 调用 `enumerator` 必须通过导入的 `malloc_introspection_t` 字段访问（arm64 上该函数指针
> 带 `__ptrauth` PAC 签名，手动按裸指针 load 出来调用会崩溃）；同理 `objc_copyClassList`
> 的结果不能经 `AutoreleasingUnsafeMutablePointer<AnyClass>` 下标读取（会触发 ObjC 消息
> 转发崩溃），需按裸内存逐字读。

## 接入 iOS App

堆枚举与 isa 解码 API 在 iOS 同样可用（FBAllocationTracker 同款做法）。

**准备**：把 `Templates/viewer.template.html` 加入 App target（Debug 包）。

**Debug 菜单触发**（复现疑似泄漏的操作路径之后）：

推荐按需查询：识别堆对象秒级完成，再对单个对象（如当前页面 VC）反查被谁强引用、
它引用了谁，weak / unowned 自动排除：

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
        // report.outgoing：它强引用了谁；report.incoming：谁强引用了它（含反查层级）
        // report.cycles：经过该对象的循环引用链（完整边序列，含属性名与透传标记）
        // 自行组装展示（App 内可用 WKWebView 加载生成的 HTML）
    }
}
```

`referenceReport(of:maxDepth:)` 的 incoming 每层做一次全堆定向扫描，`maxDepth` 层即
`maxDepth` 次扫描；`maxDepth: 1` 只看直接持有者，建议 2。

**App 内 `MGTool` 的两个入口**（`Projects/MGTool.swift`）：

```swift
// 入口一：直接查当前页面 VC
MGTool.captureMemoryGraph(from: viewController)

// 入口二：按 16 进制字符串地址查（用于复看报告 / 日志里记下的地址）
MGTool.captureMemoryGraph(forAddress: "0x14f2ab100", from: viewController)
// 也兼容 "0X14F2AB100"、"14f2ab100"、首尾空格；格式非法弹「地址格式无效」
```

两个入口共用同一套查询与报告页生成逻辑（后台队列识别堆对象并查询，
主线程用 `MGWKWebViewController` 打开 `Documents/reference_report.html`）；
地址解析失败或对象已释放 / 地址失效时弹提示，不会白屏。
`report.outgoing` / `nonStrongOutgoing` / `cycles` 等字段说明见上文。

**循环引用链**：`report.cycles` 是「从目标出发、沿强引用边最终回到目标」的完整链
（每条边带属性名 / 经容器透传标记），由 `cycleChains(through:maxDepth:maxChains:maxObjects:)`
定向 DFS 得到——不构建全堆边表，只展开目标可达对象，默认最深 6 条边、最多 5 条链、
最多展开 200 个对象，保证按需查询不退化成全量扫描。也可单独调用该方法。
与全图 `scan()` 的 Tarjan SCC 区别：SCC 给出「哪些对象构成环」，这里给出「具体怎么绕回来的路径」。

也可以只导出 JSON（`scanner.exportJSONData()`）用 `graph.json` 做定时快照 diff（对象数只增不减的类 = 疑似泄漏）。

全量内存图（`scanner.scan()` + `exportHTMLData(template:)`）解析全部对象引用边并找环，
在大堆上耗时分钟级，仅确需全图时使用。

注意：`malloc_get_all_zones` / zone enumerator 属于 libmalloc 的 introspection 能力，
未公开承诺 ABI 稳定，仅用于 Debug / 内部诊断包，上架版本不建议包含。
真机验证时本仓库工程请走 `Projects/<Target>` 的既有流程（bundle install / pod install）。

## 已知限制

- **weak / unowned 引用自动识别**（实测本工具链）：
  - **Swift 定义的类：自动排除非强引用**。运行时反射元数据
    （`swift_reflectionMirror_recursiveChildMetadata` 的 `_FieldReflectionMetadata`，
    布局为 name 8 + freeFunc 8 + isStrong 1 + isVar 1 字节）逐字段提供
    `isStrong`，weak 与 unowned 均为 false；`recursiveChildOffset` 给出的偏移与
    `ivar_getOffset` 对齐、自动含父类字段。Optional 非强字段统一标 weak，
    非 Optional 非强字段标 unowned。
  - **ObjC 定义的类：自动识别**。分别解析 `class_getIvarLayout`
    与 `class_getWeakIvarLayout`，且按继承链上各类自身的 aligned instanceStart
    计算偏移；两份布局都未覆盖的 `@` ivar 保守标 `nonStrong`。
  - 反射元数据依赖编译产物中的 Swift 字段描述，理论上 `@_silgen_name` 私有
    符号随系统版本有变化风险；若个别字段反射不可达（如属性包装器改写字段名），
    用 `--weak-ivar` 兜底标注。
  - 所有对象会读取 isa 的 **weakly_referenced 位**（实测当前 arm64 运行时为
    bit2，仅作参考标记）：该位为 true 只说明对象被某处 weak 引用过，是对象级
    sticky 标记、不指向具体边，HTML 面板与控制台会如实提示，不可据此判断
    某条边的强弱。
- 纯 Swift 类（非 NSObject 子类）**同样支持**：Swift 类在运行时也是注册的 ObjC 类
  （出现在 `objc_copyClassList` 中，`class_getName` 返回 `模块.类名`），存储属性也
  会注册为 ivar，节点识别、引用边、属性名、非强引用排除、循环检测均可用。
- 保守扫描与 leaks 同类，指针误判可能带来少量误报边；已通过类名前缀过滤 +
  ivar 偏移扫描 + 容器仅透传一层控制噪音。
- 大堆扫描（百万级块）耗时约秒级，适合诊断场景而非线上监控。

## 输出格式（graph.json）

```json
{
  "generatedAt": "…",
  "classFilter": "MGDemo",
  "nodes": [{ "address": "0x…", "className": "…", "size": 48, "inDegree": 3, "inCycle": true }],
  "edges": [{ "from": "0x…", "to": "0x…", "ivar": "token", "indirect": false }],
  "cycles": [["0x…", "0x…"]]
}
```
