//
//  MGTool.swift
//  SawaLudo
//
//  Created by 张杰 on 2026/11/8.
//

import UIKit
import WebKit

@objc(MemoryGraphManager)
@objcMembers
class MemoryGraphManager: NSObject {
    /// 引用关系快速排查：以当前触发入口的页面 VC 为目标，识别堆对象（秒级）后
    /// 反查目标被谁引用、它引用了谁。weak / unowned 自动排除。
    /// 注意：全量内存图（scan() + 模板导出）在大堆上耗时分钟级，排查单对象勿用。
    /// [MemoryGraphManager captureMemoryGraphFrom:self];
    class func captureMemoryGraph(from viewController: UIViewController) {
        let address = "0x" + String(unsafeBitCast(viewController, to: UInt.self), radix: 16)
        captureMemoryGraph(forAddress: address, from: viewController)
    }

    /// 按 16 进制字符串地址查询引用图，例如 "0x14f2ab100"（兼容 0x 前缀大小写、
    /// 无前缀、首尾空格）。适用于已从报告 / 日志里记下对象地址，想直接复看它的
    /// 引用关系，而不必重新定位对应 VC。 [MemoryGraphManager captureMemoryGraphForAddress:@"0x14f2ab100" from:self];
    /// - Parameters:
    ///   - addressString: 对象堆地址，如 "0x14f2ab100"
    ///   - viewController: 用于展示报告页 / 错误提示的当前页面
    class func captureMemoryGraph(forAddress addressString: String, from viewController: UIViewController) {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let scanner = MemoryGraphScanner()
            scanner.identifyObjects()
            guard let report = scanner.referenceReport(of: targetAddress, maxDepth: 2) else {
                DispatchQueue.main.async {
                    let alert = UIAlertController(
                        title: "未在堆中找到该对象",
                        message: "可能已正常释放，或地址已失效（0x\(String(targetAddress, radix: 16))）",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    viewController.present(alert, animated: true)
                }
                return
            }
            let html = referenceReportHTML(for: report)
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("reference_report.html")
            try? html.data(using: .utf8)?.write(to: url)

            DispatchQueue.main.async {
                let vc = MGWKWebViewController(localURL: url)
                // 报告页的关闭 / 分享按钮挂在 navigationItem 上，需包一层导航控制器才能显示
                viewController.present(UINavigationController(rootViewController: vc), animated: true)
            }
        }
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
          <h2>非强引用与字段</h2>
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
          <marker id="arrowNonStrong" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#c2255c"/></marker>
        </defs>
        <rect x="0" y="0" width="\(width)" height="\(height)" fill="#fbfcfd" rx="10"/>
        """
        // 线型按 ownership：unknown 灰色点线（明确表示无元数据），环边红色加粗优先
        func edgeStyle(_ edge: ReferenceEdge, isIncoming: Bool,
                       inCycle: Bool) -> (color: String, arrow: String, dashed: Bool) {
            if inCycle { return ("#e03131", "arrowCycle", false) }
            switch edge.ownership {
            case .unknown: return ("#868e96", "arrowUnknown", true)
            case .weak: return ("#b26a00", "arrowWeak", true)
            case .unowned: return ("#7048e8", "arrowUnowned", true)
            case .nonStrong: return ("#c2255c", "arrowNonStrong", true)
            case .strong:
                return (isIncoming ? "#d63384" : "#1c7ed6", isIncoming ? "arrowIn" : "arrowOut", false)
            }
        }
        // 连线先画，节点后画，避免线压在节点上
        func edgePath(from: (x: Int, y: Int), to: (x: Int, y: Int), label: String,
                      color: String, arrow: String, dashed: Bool = false,
                      strokeWidth: Double = 1.6) -> String {
            let x1 = from.x + boxW, y1 = from.y + boxH / 2
            let x2 = to.x, y2 = to.y + boxH / 2
            let midX = (x1 + x2) / 2
            let curve = "M\(x1) \(y1) C\(midX) \(y1), \(midX) \(y2), \(x2) \(y2)"
            let dash = dashed ? " stroke-dasharray='5 3'" : ""
            let text = label.isEmpty ? "" : """
            <text x="\(midX)" y="\((y1 + y2) / 2 - 5)" font-size="9" fill="#6c757d" text-anchor="middle" paint-order="stroke" stroke="#fbfcfd" stroke-width="3">\(escapeHTML(label))</text>
            """
            return "<path d='\(curve)' fill='none' stroke='\(color)' stroke-width='\(strokeWidth)'\(dash) marker-end='url(#\(arrow))'/>" + text
        }
        // incoming：L1 -> 目标，L2 -> 对应 L1 来源
        for edge in report.incoming {
            let level = report.incomingLevel[edge.from] ?? 1
            guard let sourceColumn = columnIndex(forLevel: level),
                  let source = position[nodeKey(sourceColumn, edge.from)] else { continue }
            let target: (x: Int, y: Int)? = edge.to == report.address
                ? position[nodeKey(centerColumn, report.address)]
                : columnIndex(forLevel: level - 1).flatMap { position[nodeKey($0, edge.to)] }
            guard let destination = target else { continue }
            let inCycle = isCycleEdge(edge)
            let style = edgeStyle(edge, isIncoming: true, inCycle: inCycle)
            svg += edgePath(from: source, to: destination,
                            label: edge.ivarName ?? "",
                            color: style.color, arrow: style.arrow,
                            dashed: style.dashed, strokeWidth: inCycle ? 2.6 : 1.6)
        }
        // outgoing（含 weak / unowned 非强边，虚线）：目标 -> 各引用对象
        for edge in allOutgoing {
            guard let center = position[nodeKey(centerColumn, report.address)],
                  let destination = position[nodeKey(outgoingColumn, edge.to)] else { continue }
            let inCycle = isCycleEdge(edge)
            let style = edgeStyle(edge, isIncoming: false, inCycle: inCycle)
            svg += edgePath(from: center, to: destination,
                            label: edge.ivarName ?? "",
                            color: style.color, arrow: style.arrow,
                            dashed: style.dashed, strokeWidth: inCycle ? 2.6 : 1.6)
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
            html += "<p class='empty'>未发现经过该对象的强引用环（可正常释放，或环超出搜索深度）</p>"
        } else {
            for (index, chain) in report.cycles.enumerated() {
                html += "<div class='chain'><span class='chain-idx'>#\(index + 1)</span>"
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
            html += "<p class='chain-note'>* 表示经容器 / 闭包透传；链从目标出发最终回到目标，环上的边在引用图中标红加粗。</p>"
        }
        return html + "</div>"
    }

    /// 单对象引用报告页：引用图 + 循环链 + 目标信息 + incoming（按反查层级分组）+ outgoing
    private class func referenceReportHTML(for report: MemoryGraphScanner.ReferenceReport) -> String {
        var body = """
        <div class="card">
          <h1>引用关系报告</h1>
          <p class="target">\(escapeHTML(report.className)) <span class="addr">\(hex(report.address))</span> · \(report.size) 字节</p>
        </div>
        <div class="card">
          <h2>引用图</h2>
          <div class="legend"><span><i class="dot-inc"></i>引用它（incoming）</span><span><i class="dot-out"></i>它引用（outgoing）</span><span><i class="dot-cycle"></i>循环链上的边</span><span><i class="dot-weakline"></i>weak / unowned（虚线）</span><span><i class="dot-unknown"></i>unknown（闭包捕获，无元数据）</span><span class="legend-tip">箭头为引用方向 · 点节点看详情</span></div>
          <div class="graph-scroll">\(referenceGraphSVG(for: report))</div>
        </div>
        """
        body += cycleChainsHTML(for: report)
        // incoming：confirmed strong 与不参与找环的 unknown 分开展示，
        // 避免 unknown 因存放在 report.incoming 中被页面标题误导成 strong。
        let strongIncoming = report.incoming.filter { $0.ownership == .strong }
        let unknownIncoming = report.incoming.filter { $0.ownership == .unknown }
        body += """
        <div class="card">
          <h2>谁引用了它（确认 strong）</h2>
        """
        if strongIncoming.isEmpty {
            body += "<p class='empty'>未发现确认的 strong 引用来源</p>"
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
        // outgoing 同样分离 confirmed strong / unknown
        let strongOutgoing = report.outgoing.filter { $0.ownership == .strong }
        let unknownOutgoing = report.outgoing.filter { $0.ownership == .unknown }
        body += """
        <div class="card">
          <h2>它引用了谁（确认 strong）</h2>
        """
        if strongOutgoing.isEmpty {
            body += "<p class='empty'>未发现确认的 strong 引用对象</p>"
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
            <tr><td>Swift 类属性</td><td><b>strong / weak / unowned</b></td><td>反射 <code>isStrong</code> 排除非强字段；Optional 非强字段统一标 weak，非 Optional 标 unowned</td></tr>
            <tr><td>ObjC 类属性</td><td><b>strong / weak 准确</b>；其余非强标「非强」</td><td><code>class_getIvarLayout</code> + <code>class_getWeakIvarLayout</code>；不在两份布局中的对象 ivar 可能是 <code>__unsafe_unretained</code></td></tr>
            <tr><td>ObjC block 捕获</td><td><b>有符号时身份可定位；ownership 准确</b></td><td>invoke 指针定位具体 block；BlockDescriptor extended layout 标明 STRONG / WEAK / UNRETAINED / BYREF</td></tr>
            <tr><td>Swift 原生闭包捕获</td><td><b>有符号的属性闭包可定位；ownership 标 unknown</b></td><td>函数字段代码指针可还原 <code>closure #N in ...</code>；context metadata 无 ownership 枚举，无法区分 <code>[x]</code> / <code>[weak x]</code></td></tr>
            <tr><td><code>@convention(block)</code> 桥接</td><td><b>不能，标 unknown</b></td><td>桥接 block 无 extended layout（实测 flags=0x43000002）；弱捕获在 Swift 上下文层</td></tr>
          </table>
          <p><code>unknown</code> 边只作为潜在引用展示，不参与循环检测；循环引用链只使用确认的 strong 边。
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
          .chain { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 10px 0; border-bottom: 1px solid #f1f3f5; font-size: 13px; }
          .chain:last-of-type { border-bottom: none; }
          .chain-idx { color: #adb5bd; font-size: 12px; margin-right: 2px; }
          .chain-node { background: #fff0f6; border: 1.5px solid #e03131; border-radius: 6px; padding: 4px 8px; color: #212529; white-space: nowrap; }
          .chain-node.is-target { background: #343a40; border-color: #212529; color: #fff; }
          .hop { color: #e03131; font-size: 12px; white-space: nowrap; }
          .chain-len { color: #adb5bd; font-size: 12px; margin-left: 4px; white-space: nowrap; }
          .chain-note { color: #868e96; font-size: 12px; margin: 10px 0 0; }
          .note-card h2 { color: #6c757d; }
          .note-card p { color: #495057; font-size: 13px; line-height: 1.6; margin: 6px 0; }
          .note-card code { background: #f1f3f5; border-radius: 3px; padding: 1px 4px; font-size: 12px; }
          .own { font-size: 11px; border-radius: 4px; padding: 1px 5px; margin-left: 4px; white-space: nowrap; }
          .own-strong { background: #e6fcf5; color: #0b7285; }
          .own-weak { background: #fff4e0; color: #b26a00; }
          .own-unowned { background: #f3e9ff; color: #7048e8; }
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

    private let localURL: URL

    private var webView: WKWebView!

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
        navigationItem.title = localURL.lastPathComponent
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
