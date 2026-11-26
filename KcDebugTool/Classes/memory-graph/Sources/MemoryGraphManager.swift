//
//  MGTool.swift
//  SawaLudo
//
//  Created by 张杰 on 2026/11/8.
//

import UIKit
import WebKit
import Darwin

@objc(MemoryGraphManager)
@objcMembers
public class MemoryGraphManager: NSObject {
    /// 直接打开查询页，不预先扫描。用户在网页输入对象地址、类地址或类名后再查询。
    /// Objective-C: [MemoryGraphManager openMemoryGraphFrom:self];
    @objc(openMemoryGraphFrom:)
    public class func openMemoryGraph(from viewController: UIViewController) {
        DispatchQueue.main.async { [weak viewController] in
            guard let viewController = viewController else { return }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("memory_graph_search_\(UUID().uuidString).html")
            do {
                try Data(initialQueryHTML().utf8).write(to: url, options: .atomic)
                let browser = MGWKWebViewController(localURL: url)
                viewController.present(UINavigationController(rootViewController: browser), animated: true)
            } catch {
                let alert = UIAlertController(title: "查询页打开失败", message: error.localizedDescription,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                viewController.present(alert, animated: true)
            }
        }
    }

    /// 引用关系快速排查：以当前触发入口的页面 VC 为目标，识别堆对象（秒级）后
    /// 反查目标被谁引用、它引用了谁。weak / unowned 单独展示，不参与强引用层级扩展。
    /// 注意：全量内存图（scan() + 模板导出）在大堆上耗时分钟级，排查单对象勿用。
    /// [MemoryGraphManager captureMemoryGraphFrom:self];
    public class func captureMemoryGraph(from viewController: UIViewController) {
        let address = "0x" + String(unsafeBitCast(viewController, to: UInt.self), radix: 16)
        captureMemoryGraph(forAddress: address, from: viewController)
    }

    /// 按 16 进制字符串地址查询引用图，例如 "0x14f2ab100"（兼容 0x 前缀大小写、
    /// 无前缀、首尾空格）。适用于已从报告 / 日志里记下对象地址，想直接复看它的
    /// 引用关系，而不必重新定位对应 VC。 [MemoryGraphManager captureMemoryGraphForAddress:@"0x14f2ab100" from:self];
    /// - Parameters:
    ///   - addressString: 对象堆地址，如 "0x14f2ab100"
    ///   - viewController: 用于展示报告页 / 错误提示的当前页面
    public class func captureMemoryGraph(forAddress addressString: String, from viewController: UIViewController) {
        guard let address = parseHexAddress(addressString) else {
            DispatchQueue.main.async {
                let alert = UIAlertController(
                    title: "地址格式无效",
                    message: "请传入 16 进制地址，如 0x14f2ab100（收到：\(addressString)）",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                viewController.present(alert, animated: true)
            }
            return
        }
        captureReferenceGraph(address: address, from: viewController)
    }

    /// 16 进制地址解析：去掉 0x/0X 前缀与首尾空白后按 radix 16 转换
    private class func parseHexAddress(_ string: String) -> UInt? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = String(text.dropFirst(2)) }
        guard !text.isEmpty else { return nil }
        return UInt(text, radix: 16)
    }

    /// 查询并展示单对象引用报告（后台队列执行，结果页回主线程弹出）
    private class func captureReferenceGraph(address targetAddress: UInt, from viewController: UIViewController) {
        DispatchQueue.global(qos: .userInitiated).async { [weak viewController] in
            let scanner = MemoryGraphScanner()
            scanner.identifyObjects()
            guard let report = scanner.referenceReport(of: targetAddress, maxDepth: 2) else {
                DispatchQueue.main.async { [weak viewController] in
                    let alert = UIAlertController(
                        title: "未在堆中找到该对象",
                        message: "可能已正常释放，或地址已失效（0x\(String(targetAddress, radix: 16))）",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    viewController?.present(alert, animated: true)
                }
                return
            }
            let html = referenceReportHTML(for: report)
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("reference_report_\(String(targetAddress, radix: 16))_\(UUID().uuidString).html")
            do {
                try Data(html.utf8).write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { [weak viewController] in
                    guard let viewController = viewController else { return }
                    let alert = UIAlertController(title: "报告保存失败", message: error.localizedDescription,
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    viewController.present(alert, animated: true)
                }
                return
            }

            DispatchQueue.main.async { [weak viewController] in
                guard let viewController = viewController else { return }
                let vc = MGWKWebViewController(localURL: url)
                // 报告页的关闭 / 分享按钮挂在 navigationItem 上，需包一层导航控制器才能显示
                viewController.present(UINavigationController(rootViewController: vc), animated: true)
            }
        }
    }

    fileprivate class func lookupMemoryQuery(_ query: String, from controller: MGWKWebViewController) {
        let requestNumber = controller.beginLookup()
        DispatchQueue.global(qos: .userInitiated).async { [weak controller] in
            let scanner = MemoryGraphScanner()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let deep = trimmed.hasPrefix("deep:")
            let term = deep ? String(trimmed.dropFirst(5)) : trimmed
            let html: String
            if let address = parseHexAddress(term),
               term.lowercased().hasPrefix("0x") || term.count >= 6 &&
               term.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil {
                let isHeapAddress = UnsafeRawPointer(bitPattern: address).map {
                    malloc_zone_from_ptr($0) != nil
                } ?? false
                if !deep, !isHeapAddress {
                    let classInfo = scanner.quickClassInfo(at: address)
                    html = classLookupHTML(classInfo.map { [$0] } ?? [], query: term,
                                           scanner: scanner, quick: true)
                } else {
                    scanner.identifyObjects()
                    if let report = scanner.referenceReport(of: address,
                                                            maxDepth: deep ? 2 : 1,
                                                            cycleMaxDepth: deep ? 10 : 8,
                                                            cycleMaxObjects: deep ? 2_400 : 400) {
                        html = referenceReportHTML(for: report, quick: !deep)
                    } else if let classInfo = scanner.classInfo(at: address) {
                        html = classLookupHTML([classInfo], query: term, scanner: scanner, quick: false)
                    } else {
                        html = classLookupHTML(scanner.classInfos(matching: term), query: term,
                                               scanner: scanner, quick: false)
                    }
                }
            } else {
                if !deep {
                    let classes = scanner.quickClassInfos(matching: term)
                    html = classLookupHTML(classes, query: term, scanner: scanner, quick: true)
                } else {
                    scanner.identifyObjects()
                    html = classLookupHTML(scanner.classInfos(matching: term), query: term,
                                           scanner: scanner, quick: false)
                }
            }
            DispatchQueue.main.async { [weak controller] in
                controller?.showGeneratedHTML(html, requestNumber: requestNumber)
            }
        }
    }

    private class func classLookupHTML(_ classes: [MemoryGraphScanner.ClassInfo],
                                      query: String, scanner: MemoryGraphScanner, quick: Bool) -> String {
        let pageSize = 100
        var addressLists: [String] = []
        let blocks = classes.enumerated().map { index, info -> String in
            let addresses = info.instanceAddresses.map(hex)
            addressLists.append("\(index):[\(addresses.map { "'\($0)'" }.joined(separator: ","))]")
            let rows = addresses.prefix(pageSize).map { address in
                "<li><button onclick=\"mgLookupAddress('\(address)')\">\(address)</button></li>"
            }.joined()
            let more = addresses.count > pageSize
                ? "<button id='mgMore_\(index)' onclick='mgMore(\(index))'>再显示 100 个</button>" : ""
            return "<section><h2>\(escapeHTML(info.name))</h2><p>类地址 \(hex(info.address)) · 存活 \(addresses.count) 个</p><ul id='mgClass_\(index)'>\(rows.isEmpty ? "<li>当前没有存活实例</li>" : rows)</ul>\(more)</section>"
        }.joined()
        let content = blocks.isEmpty ? "<p>当前扫描未找到匹配项；地址可能已失效，或该类尚未注册。</p>" : blocks
        let scanSummary = scanner.inspectedHeapBlockCount == 0
            ? "已检查运行时类表，无需枚举堆块"
            : "\(quick ? "快速枚举" : "完整识别") \(scanner.inspectedHeapBlockCount) 个堆块"
        return """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font:14px -apple-system,sans-serif;background:#f2f3f5;padding:16px}section{background:white;border-radius:10px;padding:16px;margin:12px 0}h2{font-size:16px}button,input{font-size:14px;padding:8px}li{margin:8px 0}ul{padding-left:22px}</style></head><body>
        \(lookupBarHTML(initialValue: query))
        <section><h1>查询：\(escapeHTML(query))</h1>
          <p>\(scanSummary)，用时 \(String(format: "%.2f", scanner.identifyDuration)) 秒，匹配 \(classes.count) 个类。\(quick ? "快速模式覆盖已注册类；如需查未注册 Swift 泛型类，可点完整扫描。" : "")</p>
          \(quick ? "<button onclick=\"mgLookupDeep()\">完整扫描此类</button>" : "")
        </section>
        \(content)
        <script>
        var mgClassAddresses={\(addressLists.joined(separator: ","))};
        var mgClassCursor={};
        function mgMore(index){
          var addresses=mgClassAddresses[index]||[];
          var cursor=mgClassCursor[index]||100;
          var list=document.getElementById('mgClass_'+index);
          addresses.slice(cursor,cursor+100).forEach(function(address){
            var li=document.createElement('li'), button=document.createElement('button');
            button.textContent=address;
            button.onclick=function(){mgLookupAddress(address)};
            li.appendChild(button);list.appendChild(li);
          });
          mgClassCursor[index]=cursor+100;
          if(mgClassCursor[index]>=addresses.length)document.getElementById('mgMore_'+index).style.display='none';
        }
        </script>
        </body></html>
        """
    }

    private class func initialQueryHTML() -> String {
        """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>内存图查询</title>
        <style>body{font:15px -apple-system,sans-serif;background:#f2f3f5;color:#212529;padding:16px;line-height:1.6}section{background:white;border-radius:10px;padding:16px;margin:12px 0}code{background:#f1f3f5;padding:2px 4px;border-radius:4px}button,input{font-size:14px;padding:8px}</style></head><body>
        \(lookupBarHTML())
        <section><h1>内存图查询</h1>
          <p>输入当前进程的对象地址，可查看它的引用关系和循环引用链。</p>
          <p>输入类地址或类名，可查看存活实例数，再点击一个实例查看详情。</p>
          <p>Swift 类名可以省略模块前缀。例如 <code>MyViewController</code> 也可匹配 <code>App.MyViewController</code>。</p>
          <p>点击查询后才会扫描当前进程堆；地址已释放时不会再找到原对象。</p>
        </section></body></html>
        """
    }

    private class func lookupBarHTML(initialValue: String = "") -> String {
        """
        <section style="background:#fff;padding:12px;border-radius:10px;margin-bottom:12px">
          <input id="mgQuery" type="text" value="\(escapeHTML(initialValue))" placeholder="对象地址 / 类地址 / 类名（可省略 Swift 模块名）" style="width:75%;box-sizing:border-box">
          <button onclick="mgLookup()">查询</button>
          <div id="mgLookupStatus" style="color:#868e96;font-size:12px;margin-top:6px"></div>
        </section>
        <script>
        function mgLookup(){var q=document.getElementById('mgQuery').value.trim();if(!q)return;var status=document.getElementById('mgLookupStatus');if(window.webkit&&window.webkit.messageHandlers.memoryLookup){status.textContent='正在扫描当前进程…';window.webkit.messageHandlers.memoryLookup.postMessage(q)}else{status.textContent='离线文件不能重新查询，请在 App 内打开。'}}
        function mgLookupAddress(a){document.getElementById('mgQuery').value=a;mgLookup()}
        function mgLookupDeep(){var q=document.getElementById('mgQuery').value.trim();if(q&&window.webkit&&window.webkit.messageHandlers.memoryLookup){document.getElementById('mgLookupStatus').textContent='正在完整扫描…';window.webkit.messageHandlers.memoryLookup.postMessage('deep:'+q)}}
        function mgLookupDeepAddress(a){document.getElementById('mgQuery').value=a;mgLookupDeep()}
        document.getElementById('mgQuery').addEventListener('keydown',function(e){if(e.key==='Enter')mgLookup()});
        </script>
        """
    }

    /// 在页面退出前调用。扫描仅保存地址和数量，延迟复查不持有目标页面。
    /// presenter 应是退出后仍显示的调试入口；也可传 nil，由当前最上层页面展示。
    @objc(watchDeallocationOf:from:after:)
    public class func watchDeallocation(of target: UIViewController,
                                        from presenter: UIViewController?,
                                        after delay: TimeInterval) {
        let targetAddress = unsafeBitCast(target, to: UInt.self)
        let targetClass = NSStringFromClass(type(of: target))
        weak let weakTarget = target
        weak let weakPresenter = presenter
        let before = MemoryGraphScanner()
        before.identifyObjects()
        let baselineObjectCount = before.objects.count
        let baseline = classCounts(before.objects)
        let baselineAddresses = Set(before.objects.map(\.address))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.1)) {
            DispatchQueue.global(qos: .userInitiated).async {
                let after = MemoryGraphScanner()
                after.identifyObjects()
                let survived = weakTarget != nil
                let current = classCounts(after.objects)
                let report = survived ? after.referenceReport(of: targetAddress, maxDepth: 2) : nil
                var newByClass: [String: Int] = [:]
                var survivingByClass: [String: Int] = [:]
                for object in after.objects {
                    if baselineAddresses.contains(object.address) {
                        survivingByClass[object.className, default: 0] += 1
                    } else {
                        newByClass[object.className, default: 0] += 1
                    }
                }
                let changedClasses = Set(baseline.keys).union(current.keys).filter {
                    baseline[$0] != current[$0] || (newByClass[$0] ?? 0) > 0
                }.sorted { (newByClass[$0] ?? 0) > (newByClass[$1] ?? 0) }.prefix(12)
                let rows = changedClasses.map { name in
                    "<li>\(escapeHTML(name))：\(baseline[name] ?? 0) → \(current[name] ?? 0)，原地址仍在 \(survivingByClass[name] ?? 0)，新增地址 \(newByClass[name] ?? 0)</li>"
                }.joined()
                let status = survived ? "退出后仍存活" : "退出后已释放"
                let detail = report.map { referenceReportHTML(for: $0) } ?? """
                    <!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><body></body></html>
                    """
                let summary = "<section style='font-family:-apple-system;padding:16px;background:#fff;border-left:5px solid \(survived ? "#e03131" : "#2f9e44")'><h2>页面退出复查：\(status)</h2><p>\(escapeHTML(targetClass)) · 0x\(String(targetAddress, radix: 16))</p><p>退出前识别 \(baselineObjectCount) 个对象，复查识别 \(after.objects.count) 个。地址可能复用；目标是否释放以 weak 观察为准。下列数量变化仅供排查：</p><ul>\(rows.isEmpty ? "<li>类实例数无变化</li>" : rows)</ul></section>"
                let html = detail.replacingOccurrences(of: "<body>", with: "<body>\(summary)")
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("memory_lifetime_\(String(targetAddress, radix: 16))_\(UUID().uuidString).html")
                guard (try? Data(html.utf8).write(to: url, options: .atomic)) != nil else { return }
                DispatchQueue.main.async {
                    guard let host = weakPresenter ?? topViewController() else { return }
                    host.present(UINavigationController(rootViewController: MGWKWebViewController(localURL: url)), animated: true)
                }
            }
        }
    }

    private class func classCounts(_ objects: [HeapObject]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for object in objects { counts[object.className, default: 0] += 1 }
        return counts
    }

    private class func topViewController() -> UIViewController? {
        let window: UIWindow?
        if #available(iOS 13.0, *) {
            window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow })
        } else {
            window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
        }
        var current = window?.rootViewController
        while let controller = current {
            if let presented = controller.presentedViewController { current = presented }
            else if let navigation = controller as? UINavigationController { current = navigation.visibleViewController }
            else if let tabs = controller as? UITabBarController { current = tabs.selectedViewController }
            else { break }
        }
        return current
    }

    private class func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private class func hex(_ address: UInt) -> String {
        "0x" + String(address, radix: 16)
    }

    private class func className(of address: UInt, report: MemoryGraphScanner.ReferenceReport) -> String {
        report.classNameByAddress[address] ?? "?"
    }

    /// 边展示文案：属性名 + 经容器透传标记
    private class func edgeIvarLabel(_ edge: ReferenceEdge) -> String {
        var label = "经 \(edge.ivarName ?? "?")"
        if edge.isIndirect { label += "（经容器透传）" }
        return label
    }

    /// 每条边都标注持有语义；unknown 明确表示运行时无元数据，不假装 strong
    private class func ownershipBadge(_ ownership: ReferenceOwnership) -> String {
        " <span class='own own-\(ownership.rawValue)'>\(escapeHTML(ownership.label))</span>"
    }

    /// 非强引用边与字段级语义：即使 unowned 槽位不指向对象（无法成边）也如实列出
    private class func nonStrongHTML(for report: MemoryGraphScanner.ReferenceReport) -> String {
        var html = """
        <div class="card nonstrong-card">
          <h2>它的非强引用与字段</h2>
        """
        if report.nonStrongOutgoing.isEmpty && report.nonStrongFields.isEmpty {
            html += "<p class='empty'>未发现 weak / unowned 字段或 block 弱捕获</p>"
        } else {
            if !report.nonStrongOutgoing.isEmpty {
                html += "<h3>非强引用边（不参与循环检测）</h3><ul>"
                for edge in report.nonStrongOutgoing {
                    html += """
                    <li>\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.to, report: report)))</span> <span class="addr">\(hex(edge.to))</span></li>
                    """
                }
                html += "</ul>"
            }
            if !report.nonStrongFields.isEmpty {
                html += "<h3>字段级语义（元数据判定）</h3><ul>"
                for (field, ownership) in report.nonStrongFields.sorted(by: { $0.key < $1.key }) {
                    html += "<li>\(escapeHTML(field))\(ownershipBadge(ownership))</li>"
                }
                html += "</ul>"
            }
        }
        return html + "</div>"
    }

    /// 图节点展示名：去掉模块前缀并截断，避免长类名撑破节点框
    private class func shortClassName(_ fullName: String) -> String {
        let bare = fullName.split(separator: ".").last.map(String.init) ?? fullName
        return bare.count > 18 ? String(bare.prefix(17)) + "…" : bare
    }

    private class func shortAddress(_ address: UInt) -> String {
        let full = String(address, radix: 16)
        return "0x…" + String(full.suffix(6))
    }

    /// 引用图（纯内联 SVG，离线可用）：中心为目标对象，左侧按反查层级排布 incoming
    /// 来源（L1 靠近中心、L2 更左），右侧为 outgoing 目标；箭头表示引用方向。
    /// 每列最多 10 个节点，超出折叠为「+N 个」，完整信息仍在下方文字列表。
    private class func referenceGraphSVG(for report: MemoryGraphScanner.ReferenceReport) -> String {
        let boxW = 150, boxH = 62, gapX = 186, gapY = 76
        let maxPerColumn = 10
        // 非强边也画进图（虚线），否则 weak 属性在图里根本看不到
        let allOutgoing = report.outgoing + report.nonStrongOutgoing
        let levels = Set(report.incoming.compactMap { report.incomingLevel[$0.from] }).sorted()
        let centerColumn = levels.count
        let outgoingColumn = levels.count + 1
        func columnX(_ column: Int) -> Int { 16 + column * gapX }
        // L1（直接持有者）最靠近中心，L2 更左，依此类推
        func columnIndex(forLevel level: Int) -> Int? {
            guard let index = levels.firstIndex(of: level) else { return nil }
            return levels.count - 1 - index
        }
        let width = columnX(outgoingColumn) + boxW + 16
        // 循环链上的边：在图中标红加粗，直观看到「哪一跳构成了环」
        let cycleEdgeKeys = Set(report.cycles.flatMap { $0.edges }.map { "\($0.from)>\($0.to)>\($0.ivarName ?? "")" })
        func isCycleEdge(_ edge: ReferenceEdge) -> Bool {
            cycleEdgeKeys.contains("\(edge.from)>\(edge.to)>\(edge.ivarName ?? "")")
        }
        // 节点上补属性名：该节点对应边的 ivar 名（多边取第一条）
        var ivarByAddress: [UInt: String] = [:]
        for edge in report.incoming where ivarByAddress[edge.from] == nil {
            ivarByAddress[edge.from] = edge.ivarName
        }
        for edge in allOutgoing where ivarByAddress[edge.to] == nil {
            ivarByAddress[edge.to] = edge.ivarName
        }

        // 每列节点去重（同一来源可能有多条边）；超出上限折叠为汇总节点
        struct Column { var addresses: [UInt] = []; var overflow: Int = 0; var isOutgoing = false }
        var columns: [Column] = (0...outgoingColumn).map { _ in Column() }
        var seenIncoming = Set<UInt>()
        for edge in report.incoming {
            let level = report.incomingLevel[edge.from] ?? 1
            guard let columnIndex = columnIndex(forLevel: level), !seenIncoming.contains(edge.from) else { continue }
            seenIncoming.insert(edge.from)
            if columns[columnIndex].addresses.count < maxPerColumn {
                columns[columnIndex].addresses.append(edge.from)
            } else {
                columns[columnIndex].overflow += 1
            }
        }
        var seenOutgoing = Set<UInt>()
        for edge in allOutgoing where !seenOutgoing.contains(edge.to) {
            seenOutgoing.insert(edge.to)
            if columns[outgoingColumn].addresses.count < maxPerColumn {
                columns[outgoingColumn].addresses.append(edge.to)
            } else {
                columns[outgoingColumn].overflow += 1
            }
        }
        columns[outgoingColumn].isOutgoing = true
        columns[centerColumn].addresses = [report.address]

        let rowCounts = columns.map { $0.addresses.count + ($0.overflow > 0 ? 1 : 0) }
        let maxRows = max(rowCounts.max() ?? 1, 1)
        let height = max(240, maxRows * gapY + 56)

        // 节点坐标：每列垂直居中
        var position: [String: (x: Int, y: Int)] = [:]
        func nodeKey(_ column: Int, _ address: UInt) -> String { "\(column)_\(address)" }
        for (columnIndex, column) in columns.enumerated() {
            let total = rowCounts[columnIndex]
            let top = (height - total * gapY) / 2 + 6
            for (row, address) in column.addresses.enumerated() {
                position[nodeKey(columnIndex, address)] = (columnX(columnIndex), top + row * gapY)
            }
            if column.overflow > 0 {
                position[nodeKey(columnIndex, UInt.max)] = (columnX(columnIndex), top + column.addresses.count * gapY)
            }
        }

        var svg = """
        <svg viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="对象引用图">
        <defs>
          <marker id="arrowIn" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#d63384"/></marker>
          <marker id="arrowOut" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#1c7ed6"/></marker>
          <marker id="arrowCycle" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#e03131"/></marker>
          <marker id="arrowUnknown" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#868e96"/></marker>
          <marker id="arrowWeak" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#b26a00"/></marker>
          <marker id="arrowUnowned" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#7048e8"/></marker>
          <marker id="arrowUnownedUnsafe" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#5f3dc4"/></marker>
          <marker id="arrowNonStrong" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#c2255c"/></marker>
        </defs>
        <rect x="0" y="0" width="\(width)" height="\(height)" fill="#fbfcfd" rx="10"/>
        """
        // 线型按 ownership：unknown 灰色点线（明确表示无元数据），环边红色加粗优先。
        // unconfirmedStrong 沿用强引用配色但用虚线区分「未确证」，不冒充 confirmed。
        func edgeStyle(_ edge: ReferenceEdge, isIncoming: Bool,
                       inCycle: Bool) -> (color: String, arrow: String, dashed: Bool) {
            if inCycle && edge.ownership.participatesInCycleDetection {
                return ("#e03131", "arrowCycle", false)
            }
            switch edge.ownership {
            case .unknown: return ("#868e96", "arrowUnknown", true)
            case .weak: return ("#b26a00", "arrowWeak", true)
            case .unowned: return ("#7048e8", "arrowUnowned", true)
            case .unownedUnsafe: return ("#5f3dc4", "arrowUnownedUnsafe", true)
            case .nonStrong: return ("#c2255c", "arrowNonStrong", true)
            case .unconfirmedStrong:
                return (isIncoming ? "#d63384" : "#1c7ed6", isIncoming ? "arrowIn" : "arrowOut", true)
            case .strong:
                return (isIncoming ? "#d63384" : "#1c7ed6", isIncoming ? "arrowIn" : "arrowOut", false)
            }
        }
        // 连线先画，节点后画，避免线压在节点上
        func edgePath(from: (x: Int, y: Int), to: (x: Int, y: Int), label: String,
                      color: String, arrow: String, dashed: Bool = false,
                      strokeWidth: Double = 1.6, verticalOffset: Int = 0) -> String {
            let x1 = from.x + boxW, y1 = from.y + boxH / 2 + verticalOffset
            let x2 = to.x, y2 = to.y + boxH / 2 + verticalOffset
            let midX = (x1 + x2) / 2
            let curve = "M\(x1) \(y1) C\(midX) \(y1), \(midX) \(y2), \(x2) \(y2)"
            let dash = dashed ? " stroke-dasharray='5 3'" : ""
            let text = label.isEmpty ? "" : """
            <text x="\(midX)" y="\((y1 + y2) / 2 - 5)" font-size="9" fill="#6c757d" text-anchor="middle" paint-order="stroke" stroke="#fbfcfd" stroke-width="3">\(escapeHTML(label))</text>
            """
            return "<path d='\(curve)' fill='none' stroke='\(color)' stroke-width='\(strokeWidth)'\(dash) marker-end='url(#\(arrow))'/>" + text
        }
        // 同一对节点可能同时有 strong 与 weak 边；路径重叠时实线会填满虚线空隙。
        // 先收集可见边，再给并行线分配不同的垂直位置。
        typealias DrawnEdge = (edge: ReferenceEdge, source: (x: Int, y: Int),
                               destination: (x: Int, y: Int), isIncoming: Bool)
        var drawnEdges: [DrawnEdge] = []
        // incoming：L1 -> 目标，L2 -> 对应 L1 来源
        for edge in report.incoming {
            let level = report.incomingLevel[edge.from] ?? 1
            guard let sourceColumn = columnIndex(forLevel: level),
                  let source = position[nodeKey(sourceColumn, edge.from)] else { continue }
            let target: (x: Int, y: Int)? = edge.to == report.address
                ? position[nodeKey(centerColumn, report.address)]
                : columnIndex(forLevel: level - 1).flatMap { position[nodeKey($0, edge.to)] }
            guard let destination = target else { continue }
            drawnEdges.append((edge, source, destination, true))
        }
        // outgoing（含 weak / unowned 非强边，虚线）：目标 -> 各引用对象
        for edge in allOutgoing {
            guard let center = position[nodeKey(centerColumn, report.address)],
                  let destination = position[nodeKey(outgoingColumn, edge.to)] else { continue }
            drawnEdges.append((edge, center, destination, false))
        }
        func pathKey(_ item: DrawnEdge) -> String {
            "\(item.source.x),\(item.source.y)>\(item.destination.x),\(item.destination.y)"
        }
        var pathCounts: [String: Int] = [:]
        for item in drawnEdges { pathCounts[pathKey(item), default: 0] += 1 }
        var pathIndexes: [String: Int] = [:]
        for item in drawnEdges {
            let key = pathKey(item)
            let index = pathIndexes[key, default: 0]
            pathIndexes[key] = index + 1
            let offset = (2 * index - (pathCounts[key] ?? 1) + 1) * 6
            let inCycle = isCycleEdge(item.edge) && item.edge.ownership.participatesInCycleDetection
            let style = edgeStyle(item.edge, isIncoming: item.isIncoming, inCycle: inCycle)
            svg += edgePath(from: item.source, to: item.destination,
                            label: item.edge.ivarName ?? "",
                            color: style.color, arrow: style.arrow,
                            dashed: style.dashed, strokeWidth: inCycle ? 2.6 : 1.6,
                            verticalOffset: offset)
        }
        // 节点
        for (columnIndex, column) in columns.enumerated() {
            for address in column.addresses {
                guard let point = position[nodeKey(columnIndex, address)] else { continue }
                let isCenter = columnIndex == centerColumn
                let isOut = column.isOutgoing
                let fill = isCenter ? "#343a40" : (isOut ? "#e7f5ff" : "#fff0f6")
                let stroke = isCenter ? "#212529" : (isOut ? "#1c7ed6" : "#d63384")
                let titleColor = isCenter ? "#ffffff" : "#212529"
                let subColor = isCenter ? "#ced4da" : "#868e96"
                let name = isCenter ? shortClassName(report.className) : shortClassName(className(of: address, report: report))
                let relevantEdge = isOut ? allOutgoing.first { $0.to == address } : report.incoming.first { $0.from == address }
                let tooltip = "\(className(of: address, report: report)) \(hex(address)) 经 \(relevantEdge?.ivarName ?? "?")"
                let rawIvar = isCenter ? "查询目标" : ivarByAddress[address].map { "经 " + $0 }
                let ivarText = rawIvar.map { $0.count > 18 ? String($0.prefix(17)) + "…" : $0 } ?? ""
                svg += """
                <a href="#n_\(address)"><g class="gnode"><title>\(escapeHTML(tooltip))</title>
                <rect x="\(point.x)" y="\(point.y)" width="\(boxW)" height="\(boxH)" rx="8" fill="\(fill)" stroke="\(stroke)" stroke-width="1.4"/>
                <text x="\(point.x + 9)" y="\(point.y + 18)" font-size="11.5" font-weight="600" fill="\(titleColor)">\(escapeHTML(name))</text>
                <text x="\(point.x + 9)" y="\(point.y + 33)" font-size="10" fill="\(subColor)">\(shortAddress(address))</text>
                <text x="\(point.x + 9)" y="\(point.y + 50)" font-size="10" font-weight="500" fill="\(isCenter ? "#ced4da" : "#c2255c")">\(escapeHTML(ivarText))</text>
                </g></a>
                """
            }
            if column.overflow > 0, let point = position[nodeKey(columnIndex, UInt.max)] {
                svg += """
                <g><rect x="\(point.x)" y="\(point.y)" width="\(boxW)" height="\(boxH)" rx="8" fill="#f1f3f5" stroke="#ced4da" stroke-dasharray="4 3"/>
                <text x="\(point.x + 9)" y="\(point.y + 28)" font-size="11" fill="#868e96">+\(column.overflow) 个（见下方列表）</text></g>
                """
            }
        }
        return svg + "</svg>"
    }

    /// 循环引用链卡片：每条链按「节点 --属性名--> 节点 … ↩ 目标」展开，
    /// 链从目标出发、最终回到目标；红色边在上方引用图中同步高亮
    private class func cycleChainsHTML(for report: MemoryGraphScanner.ReferenceReport) -> String {
        var html = """
        <div class="card cycle-card">
          <h2>循环引用链</h2>
        """
        if report.cycles.isEmpty {
            html += "<p class='empty'>本次搜索范围内未发现经过该对象的强引用环；请结合退出页面复查判断是否释放。</p>"
        } else {
            for (index, chain) in report.cycles.enumerated() {
                let hasUnconfirmed = chain.edges.contains { $0.ownership == .unconfirmedStrong }
                html += "<div class='chain'><span class='chain-idx'>#\(index + 1)</span>"
                if hasUnconfirmed {
                    html += "<span class='chain-unconfirmed'>含未确证边</span>"
                }
                for link in chain.edges {
                    let fullName = chain.classNameByAddress[link.from] ?? className(of: link.from, report: report)
                    let isTarget = link.from == report.address
                    let hop = (link.ivarName ?? "?") + (link.isIndirect ? "*" : "")
                    html += """
                    <span class='chain-node\(isTarget ? " is-target" : "")' title='\(escapeHTML(fullName)) \(hex(link.from))'>\(escapeHTML(shortClassName(fullName)))</span><span class='hop'>--\(escapeHTML(hop))--&gt;</span>
                    """
                }
                let targetName = chain.classNameByAddress[report.address] ?? report.className
                html += "<span class='chain-node is-target' title='\(escapeHTML(targetName)) \(hex(report.address))'>↩ \(escapeHTML(shortClassName(targetName)))</span>"
                html += "<span class='chain-len'>\(chain.edges.count) 条边</span></div>"
            }
            html += "<p class='chain-note'>* 表示经容器 / 闭包透传；链从目标出发最终回到目标，环上的边在引用图中标红加粗。「含未确证边」表示该链上有类属性因所有权元数据缺失按默认 strong 参与找环，需结合实际声明核对是否为 weak。</p>"
        }
        return html + "</div>"
    }

    /// NotificationCenter 的 block 注册由全局中心长期持有。Foundation 返回的
    /// __NSObserver token 不保证反向持有 block，因此这类泄漏不能伪装成循环引用。
    private class func notificationRetentionHTML(for report: MemoryGraphScanner.ReferenceReport) -> String {
        guard !report.notificationRetentions.isEmpty else { return "" }
        var html = """
        <div class="card retention-card">
          <h2>NotificationCenter 长期持有（非循环）</h2>
          <p>发现通知回调 block 强持有该对象。持有根是 NotificationCenter 的内部注册表；即使对象保存了 observer token，也不一定能从 token 沿对象字段走回 block，所以不会出现在“循环引用链”。未调用 removeObserver 前，该对象不能释放。</p>
          <ul>
        """
        for edge in report.notificationRetentions {
            html += """
            <li>\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.from, report: report)))</span> <span class="addr">\(hex(edge.from))</span></li>
            """
        }
        let observerTokens = report.outgoing.filter {
            className(of: $0.to, report: report).contains("__NSObserver")
        }
        if !observerTokens.isEmpty {
            html += "</ul><h3>目标保存的 observer token</h3><ul>"
            for edge in observerTokens {
                html += """
                <li>经 \(escapeHTML(edge.ivarName ?? "?"))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.to, report: report)))</span> <span class="addr">\(hex(edge.to))</span></li>
                """
            }
        }
        return html + "</ul></div>"
    }

    /// 单对象引用报告页：引用图 + 循环链 + 目标信息 + incoming（按反查层级分组）+ outgoing
    private class func referenceReportHTML(for report: MemoryGraphScanner.ReferenceReport,
                                           quick: Bool = false) -> String {
        var body = """
        \(lookupBarHTML(initialValue: hex(report.address)))
        <div class="card">
          <h1>引用关系报告</h1>
          <p class="target">\(escapeHTML(report.className)) <span class="addr">\(hex(report.address))</span> · \(report.size) 字节</p>
          <p class="addr">识别 \(String(format: "%.2f", report.identifyDuration)) 秒 · 引用查询 \(String(format: "%.2f", report.scanDuration)) 秒 · 对象 \(report.scannedObjectCount) 个 · 反查全堆 \(report.incomingSweepCount) 次 · 查环展开 \(report.cycleSearchVisitedObjects) 个对象 · 未确证/未知边 \(report.unconfirmedEdgeCount) 条\(report.cycleSearchTruncated ? " · ⚠ 查环预算触顶，结果不完整" : "")</p>
          \(quick ? "<p><button onclick=\"mgLookupDeepAddress('\(hex(report.address))')\">完整扫描引用链</button>（增加反查层级与查环预算）</p>" : "")
        </div>
        <div class="card">
          <h2>引用图</h2>
          <div class="legend"><span><i class="dot-inc"></i>引用它（incoming）</span><span><i class="dot-out"></i>它引用（outgoing）</span><span><i class="dot-cycle"></i>循环链上的边</span><span><i class="dot-weakline"></i>weak / unowned（虚线）</span><span><i class="dot-unknown"></i>unknown（无可用所有权元数据）</span><span class="legend-tip">箭头为引用方向 · 点节点看详情</span></div>
          <div class="graph-scroll">\(referenceGraphSVG(for: report))</div>
        </div>
        """
        body += notificationRetentionHTML(for: report)
        body += cycleChainsHTML(for: report)
        // incoming：参与找环的强引用（confirmed + 未确证）与不参与找环的 unknown 分开，
        // 避免 unknown 因存放在 report.incoming 中被页面标题误导成 strong。每条边带
        // ownership 徽标，未确证的 strong 会明确标「疑似」。
        let strongIncoming = report.incoming.filter { $0.ownership.participatesInCycleDetection }
        let unknownIncoming = report.incoming.filter { $0.ownership == .unknown }
        let nonStrongIncoming = report.incoming.filter {
            !$0.ownership.participatesInCycleDetection && $0.ownership != .unknown
        }
        body += """
        <div class="card">
          <h2>谁引用了它（参与找环的强引用）</h2>
        """
        if strongIncoming.isEmpty {
            body += "<p class='empty'>未发现可参与找环的 strong 引用来源</p>"
        } else {
            let levels = Set(strongIncoming.compactMap { report.incomingLevel[$0.from] }).sorted()
            for level in levels {
                body += "<h3>第 \(level) 层引用</h3><ul>"
                for edge in strongIncoming where report.incomingLevel[edge.from] == level {
                    body += """
                    <li id="n_\(edge.from)">\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.from, report: report)))</span> <span class="addr">\(hex(edge.from))</span></li>
                    """
                }
                body += "</ul>"
            }
        }
        body += "</div>"
        if !unknownIncoming.isEmpty {
            body += "<div class='card'><h2>谁可能引用了它（unknown，不参与找环）</h2><ul>"
            for edge in unknownIncoming {
                body += """
                <li id="n_\(edge.from)">\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.from, report: report)))</span> <span class="addr">\(hex(edge.from))</span></li>
                """
            }
            body += "</ul></div>"
        }
        if !nonStrongIncoming.isEmpty {
            body += "<div class='card nonstrong-card'><h2>谁以非强方式引用了它（不持有、不参与找环）</h2>"
            let levels = Set(nonStrongIncoming.compactMap { report.incomingLevel[$0.from] }).sorted()
            for level in levels {
                body += "<h3>第 \(level) 层引用</h3><ul>"
                for edge in nonStrongIncoming where report.incomingLevel[edge.from] == level {
                    body += """
                    <li id="n_\(edge.from)">\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.from, report: report)))</span> <span class="addr">\(hex(edge.from))</span></li>
                    """
                }
                body += "</ul>"
            }
            body += "</div>"
        }
        // outgoing 同样分离「参与找环的强引用」/ unknown；徽标会标出未确证项
        let strongOutgoing = report.outgoing.filter { $0.ownership.participatesInCycleDetection }
        let unknownOutgoing = report.outgoing.filter { $0.ownership == .unknown }
        body += """
        <div class="card">
          <h2>它引用了谁（参与找环的强引用）</h2>
        """
        if strongOutgoing.isEmpty {
            body += "<p class='empty'>未发现可参与找环的 strong 引用对象</p>"
        } else {
            body += "<ul>"
            for edge in strongOutgoing {
                body += """
                <li id="n_\(edge.to)">\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.to, report: report)))</span> <span class="addr">\(hex(edge.to))</span></li>
                """
            }
            body += "</ul>"
        }
        body += "</div>"
        if !unknownOutgoing.isEmpty {
            body += "<div class='card'><h2>它可能引用了谁（unknown，不参与找环）</h2><ul>"
            for edge in unknownOutgoing {
                body += """
                <li id="n_\(edge.to)">\(escapeHTML(edgeIvarLabel(edge)))\(ownershipBadge(edge.ownership))<br><span class="cls">\(escapeHTML(className(of: edge.to, report: report)))</span> <span class="addr">\(hex(edge.to))</span></li>
                """
            }
            body += "</ul></div>"
        }
        body += nonStrongHTML(for: report)
        // 准确性说明：按来源给出能力边界，不把 unknown 说成 strong
        body += """
        <div class="card note-card">
          <h2>每条边的 strong / weak / unowned 判定依据</h2>
          <table class="own-table">
            <tr><th>来源</th><th>能否准确区分</th><th>依据</th></tr>
            <tr><td>Swift 类属性</td><td><b>strong / weak / unowned / unowned(unsafe)</b>；描述符未匹配时标「疑似 strong」</td><td>名称和偏移取受保护的 reflectionMirror SPI；ownership 唯一取 <code>__swift5_fieldmd</code> 的 Xw / Xo / Xu / 无尾缀，不读取反射 <code>isStrong</code>。类名含 symbolic reference 或跨类同名字段歧义导致描述符匹配失败时，按存储属性默认 strong 参与找环并标注未确证</td></tr>
            <tr><td>ObjC 类属性</td><td><b>strong / weak 准确</b>；其余非强标「非强」</td><td><code>class_getIvarLayout</code> + <code>class_getWeakIvarLayout</code>；不在两份布局中的对象 ivar 可能是 <code>__unsafe_unretained</code></td></tr>
            <tr><td>ObjC block 捕获</td><td><b>有符号时身份可定位；ownership 准确</b></td><td>invoke 指针定位具体 block；BlockDescriptor extended layout 标明 STRONG / WEAK / UNRETAINED / BYREF</td></tr>
            <tr><td>Swift 原生闭包捕获</td><td><b>有符号的属性闭包可定位；可证明偏移的捕获可判 ownership</b></td><td>函数字段代码指针可还原 <code>closure #N in ...</code>；<code>__swift5_capture</code> 的 CaptureTypeRecord 提供 Xw / Xo / Xu / 无尾缀；无尾缀 strong 可能是多字值，其后的槽降级为 unknown</td></tr>
            <tr><td><code>@convention(block)</code> 桥接</td><td><b>不能，标 unknown</b></td><td>桥接 block 无 extended layout（实测 flags=0x43000002）；弱捕获在 Swift 上下文层</td></tr>
          </table>
          <p><code>unknown</code> 边（闭包 / 容器透传无元数据）只作为潜在引用展示，不参与循环检测；
          循环引用链使用确认的 strong 边与「疑似 strong」边（类存储属性元数据缺失，按语言默认 strong 参与，链上标注「含未确证边」，需核对是否为 weak）。
          isa 的 <code>weakly_referenced</code> 位只是对象级 sticky 标记，不指向任何具体边，不参与判定。</p>
        </div>
        """

        return """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>引用关系报告</title>
        <style>
          body { font-family: -apple-system, sans-serif; background: #f2f3f5; margin: 0; padding: 16px; }
          .card { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 16px; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
          h1 { font-size: 18px; margin: 0 0 8px; }
          h2 { font-size: 16px; margin: 0 0 8px; color: #d63384; }
          .card:last-child h2 { color: #1c7ed6; }
          h3 { font-size: 13px; margin: 12px 0 4px; color: #868e96; }
          .target { font-size: 14px; margin: 0; word-break: break-all; }
          ul { list-style: none; margin: 0; padding: 0; }
          li { padding: 8px 0; border-bottom: 1px solid #f1f3f5; font-size: 14px; word-break: break-all; }
          li:last-child { border-bottom: none; }
          .cls { color: #495057; }
          .addr { color: #adb5bd; font-size: 12px; }
          .empty { color: #868e96; font-size: 14px; margin: 0; }
          .legend { display: flex; flex-wrap: wrap; gap: 12px; font-size: 12px; color: #6c757d; margin: 0 0 10px; }
          .legend span { display: inline-flex; align-items: center; gap: 4px; }
          .legend i { width: 10px; height: 10px; border-radius: 3px; display: inline-block; }
          .dot-inc { background: #fff0f6; border: 1.5px solid #d63384; }
          .dot-out { background: #e7f5ff; border: 1.5px solid #1c7ed6; }
          .dot-cycle { background: #ffe3e3; border: 1.5px solid #e03131; }
          .dot-unknown { background: #f1f3f5; border: 1.5px dashed #868e96; }
          .dot-weakline { background: #fff4e0; border: 1.5px dashed #b26a00; }
          .legend-tip { color: #adb5bd; }
          .graph-scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; border-radius: 8px; }
          .graph-scroll svg { display: block; max-width: none; }
          .gnode:hover rect { stroke-width: 2.8; }
          li:target { background: #fff9db; }
          .cycle-card h2 { color: #e03131; }
          .retention-card { border-left: 5px solid #f08c00; }
          .retention-card h2 { color: #d9480f; }
          .retention-card p { color: #5f3b13; line-height: 1.55; }
          .chain { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 10px 0; border-bottom: 1px solid #f1f3f5; font-size: 13px; }
          .chain:last-of-type { border-bottom: none; }
          .chain-idx { color: #adb5bd; font-size: 12px; margin-right: 2px; }
          .chain-node { background: #fff0f6; border: 1.5px solid #e03131; border-radius: 6px; padding: 4px 8px; color: #212529; white-space: nowrap; }
          .chain-node.is-target { background: #343a40; border-color: #212529; color: #fff; }
          .hop { color: #e03131; font-size: 12px; white-space: nowrap; }
          .chain-len { color: #adb5bd; font-size: 12px; margin-left: 4px; white-space: nowrap; }
          .chain-unconfirmed { background: #fff4e0; color: #b26a00; font-size: 11px; border-radius: 4px; padding: 1px 5px; white-space: nowrap; }
          .chain-note { color: #868e96; font-size: 12px; margin: 10px 0 0; }
          .note-card h2 { color: #6c757d; }
          .note-card p { color: #495057; font-size: 13px; line-height: 1.6; margin: 6px 0; }
          .note-card code { background: #f1f3f5; border-radius: 3px; padding: 1px 4px; font-size: 12px; }
          .own { font-size: 11px; border-radius: 4px; padding: 1px 5px; margin-left: 4px; white-space: nowrap; }
          .own-strong { background: #e6fcf5; color: #0b7285; }
          .own-unconfirmedStrong { background: #e7f5ff; color: #1971c2; }
          .own-weak { background: #fff4e0; color: #b26a00; }
          .own-unowned { background: #f3e9ff; color: #7048e8; }
          .own-unownedUnsafe { background: #ede9fe; color: #5f3dc4; }
          .own-nonStrong { background: #fff0f6; color: #c2255c; }
          .own-unknown { background: #f1f3f5; color: #6c757d; }
          .own-table { border-collapse: collapse; width: 100%; font-size: 12px; margin: 8px 0; }
          .own-table th, .own-table td { border: 1px solid #e9ecef; padding: 6px; text-align: left; vertical-align: top; }
          .own-table th { background: #f8f9fa; color: #495057; }
          .nonstrong-card h2 { color: #7048e8; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

final class MGWKWebViewController: UIViewController {

    // MARK: - Properties

    private var localURL: URL

    private var webView: WKWebView!
    private var messageProxy: MGWeakScriptMessageHandler?
    private var latestLookupNumber = 0

    // MARK: - Init

    init(localURL: URL) {
        self.localURL = localURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        loadLocalURL()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .white

        setupNavigationItems()

        let configuration = WKWebViewConfiguration()
        let proxy = MGWeakScriptMessageHandler(owner: self)
        configuration.userContentController.add(proxy, name: "memoryLookup")
        messageProxy = proxy
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            // Fallback on earlier versions
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 页面由调用方模态弹出：左侧关闭，右侧分享当前 HTML 文件。
    /// 按钮挂在 navigationItem 上，调用方需用 UINavigationController 包装后 present。
    private func setupNavigationItems() {
        navigationItem.title = localURL.lastPathComponent.hasPrefix("memory_graph_search_")
            ? "内存图查询" : "引用关系报告"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .action, target: self, action: #selector(share))
    }

    // MARK: - Load

    private func loadLocalURL() {
        // 加载本地 HTML 文件
        webView.loadFileURL(
            localURL,
            allowingReadAccessTo: localURL.deletingLastPathComponent()
        )
    }

    fileprivate func beginLookup() -> Int {
        latestLookupNumber += 1
        return latestLookupNumber
    }

    fileprivate func showGeneratedHTML(_ html: String, requestNumber: Int) {
        guard requestNumber == latestLookupNumber else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memory_lookup_\(UUID().uuidString).html")
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
            localURL = url
            navigationItem.title = "内存图查询结果"
            loadLocalURL()
        } catch {
            let alert = UIAlertController(title: "报告保存失败", message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: - Public Methods

    func reload() {
        webView.reload()
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    /// 分享当前展示的 HTML 文件本体：报告内联了 SVG / CSS，单文件即可离线查看。
    /// 传文件 URL 而非 HTML 文本，AirDrop / 存储到文件 / 第三方 App 才会按 .html 接收。
    @objc func share() {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            let alert = UIAlertController(
                title: "HTML 文件不存在",
                message: localURL.lastPathComponent,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        let activityVC = UIActivityViewController(activityItems: [localURL], applicationActivities: nil)
        // iPad 上分享面板是 popover，没有锚点会在 present 时抛异常
        activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activityVC, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

private final class MGWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MGWKWebViewController?

    init(owner: MGWKWebViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let owner = owner, let query = message.body as? String else { return }
        MemoryGraphManager.lookupMemoryQuery(query, from: owner)
    }
}

// MARK: - WKNavigationDelegate

extension MGWKWebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
    }

    func webView(_ webView: WKWebView,
                 didFinish navigation: WKNavigation!) {
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
    }
}
