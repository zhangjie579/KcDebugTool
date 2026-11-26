// 独立 macOS 回归：
// swiftc -O -o /private/tmp/mg-shared Sources/MemoryGraphCore.swift Tests/SharedContainerFixture.swift
// /private/tmp/mg-shared
import Foundation

final class MGSharedTarget: NSObject {}
final class MGSharedUnused: NSObject {}
final class MGSharedOwner: NSObject {
    var items: NSArray?
}

@main enum SharedContainerFixture {
    static func main() {
        let target = MGSharedTarget()
        let shared = NSArray(object: target)
        let first = MGSharedOwner()
        let second = MGSharedOwner()
        first.items = shared
        second.items = shared

        withExtendedLifetime((target, shared, first, second)) {
            let scanner = MemoryGraphScanner(classPrefixes: ["MGShared"])
            scanner.identifyObjects()
            let address = unsafeBitCast(target, to: UInt.self)
            guard let report = scanner.referenceReport(of: address) else { fatalError("目标对象未识别") }
            let sources = Set(report.incoming.filter { $0.to == address }.map(\.from))
            precondition(sources.contains(unsafeBitCast(first, to: UInt.self)), "第一个容器持有者丢失")
            precondition(sources.contains(unsafeBitCast(second, to: UInt.self)), "第二个容器持有者丢失")

            let matches = scanner.classInfos(matching: "MGSharedOwner")
            precondition(matches.contains { $0.instanceAddresses.count == 2 }, "省略模块名的类查询失败")
            let classAddress = unsafeBitCast(MGSharedOwner.self, to: UInt.self)
            precondition(scanner.classInfo(at: classAddress)?.instanceAddresses.count == 2,
                         "类地址查询失败")
            let quickScanner = MemoryGraphScanner()
            precondition(quickScanner.quickClassInfos(matching: "MGSharedOwner")
                .contains(where: { $0.instanceAddresses.count == 2 }) == true,
                         "快速类名查询失败")
            precondition(quickScanner.quickClassInfo(at: classAddress)?.instanceAddresses.count == 2,
                         "快速类地址查询失败")
            let unusedClassAddress = unsafeBitCast(MGSharedUnused.self, to: UInt.self)
            precondition(scanner.classInfo(at: unusedClassAddress)?.instanceAddresses.isEmpty == true,
                         "零实例类地址查询失败")
            precondition(quickScanner.quickClassInfo(at: unusedClassAddress)?.instanceAddresses.isEmpty == true,
                         "快速零实例类查询失败")
            let missingScanner = MemoryGraphScanner()
            precondition(missingScanner.quickClassInfos(matching: "MGDefinitelyMissingClass").isEmpty,
                         "不存在的类应立即返回空结果")
            precondition(missingScanner.inspectedHeapBlockCount == 0,
                         "不存在的类不应触发堆枚举")
            print("共享容器持有者与类查询通过")
        }
    }
}
