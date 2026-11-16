// 独立 macOS 回归：先将 Pods/RxSwift、RxRelay 源码编译为 /private/tmp 下的 dylib，
// 再与 MemoryGraphCore.swift 一同编译本文件。覆盖内联 Bag 捕获与 DisposeBag 长链。
import Foundation
import RxSwift
import RxRelay

final class MGRxCaptureRoot: NSObject {
    let bag = DisposeBag()
    let subject = PublishSubject<Int>()
    var received = 0
}

final class MGRxWideRoot: NSObject {
    let unrelated = (0..<500).map { _ in NSObject() }
    let bag = DisposeBag()
    let viewModel = MGRxWideViewModel()
    var received = 0
}

final class MGRxWideViewModel: NSObject {
    let unrelated = (0..<50).map { _ in NSObject() }
    let unrelatedRelays = (0..<400).map { _ in BehaviorRelay<Int>(value: 0) }
    let relay = BehaviorRelay<Int>(value: 0)
}

final class MGNotificationCaptureRoot: NSObject {
    var token: NSObjectProtocol?
    var received = 0
}

final class MGBlockObserverToken: NSObject {
    var callback: (@convention(block) () -> Void)?
}

private var mgGlobalStrongRoot: MGRxCaptureRoot?

private enum MGStaticStrongHolder {
    static var root: MGRxCaptureRoot?
}

@main
private enum RxSwiftCaptureFixture {
    static func main() {
        let strongRoot = MGRxCaptureRoot()
        strongRoot.subject.subscribe(onNext: { value in
            strongRoot.received += value
        }).disposed(by: strongRoot.bag)

        let weakRoot = MGRxCaptureRoot()
        weakRoot.subject.subscribe(onNext: { [weak weakRoot] value in
            weakRoot?.received += value
        }).disposed(by: weakRoot.bag)

        let bagRoot = MGRxCaptureRoot()
        Observable<Int>.create { _ in Disposables.create() }.subscribe(onNext: { value in
            bagRoot.received += value
        }).disposed(by: bagRoot.bag)
        let wideRoot = MGRxWideRoot()
        for _ in 0..<100 {
            Observable<Int>.create { _ in Disposables.create() }
                .subscribe()
                .disposed(by: wideRoot.bag)
        }
        let notificationName = Notification.Name("MGRxWideRootNotification")
        Observable<Notification>.create { observer in
            let token = NotificationCenter.default.addObserver(forName: notificationName,
                                                                object: nil, queue: nil) { notification in
                observer.on(.next(notification))
            }
            return Disposables.create { NotificationCenter.default.removeObserver(token) }
        }.subscribe(onNext: { _ in
            wideRoot.received += 1
        }).disposed(by: wideRoot.bag)
        // 同一 owner 的另一路订阅经 BehaviorRelay 持有；两条都应检出。
        wideRoot.viewModel.relay.subscribe(onNext: { value in
            wideRoot.received += value
        }).disposed(by: wideRoot.bag)
        let objcArray = NSMutableArray(object: strongRoot)
        let notificationRoot = MGNotificationCaptureRoot()
        notificationRoot.token = NotificationCenter.default.addObserver(
            forName: Notification.Name("MGNotificationCaptureFixture"),
            object: nil,
            queue: OperationQueue.main
        ) { _ in
            notificationRoot.received += 1
        }
        defer {
            if let token = notificationRoot.token { NotificationCenter.default.removeObserver(token) }
        }
        let syntheticRoot = MGNotificationCaptureRoot()
        let syntheticToken = MGBlockObserverToken()
        syntheticRoot.token = syntheticToken
        syntheticToken.callback = { syntheticRoot.received += 1 }
        let globalRoot = MGRxCaptureRoot()
        let staticRoot = MGRxCaptureRoot()
        mgGlobalStrongRoot = globalRoot
        MGStaticStrongHolder.root = staticRoot
        defer {
            mgGlobalStrongRoot = nil
            MGStaticStrongHolder.root = nil
        }

        // 伪造旧版校验会误收的“Swift 类”：bits 与父类都像真的，
        // 但没有有效 ClassDescriptor；扫描不能把它交给 class_getName。
        guard let fakeClass = malloc(80), let fakeObject = malloc(32) else {
            fatalError("测试堆块分配失败")
        }
        defer { free(fakeObject); free(fakeClass) }
        memset(fakeClass, 0, 80)
        memset(fakeObject, 0, 32)
        fakeClass.storeBytes(of: unsafeBitCast(NSObject.self, to: UInt.self), toByteOffset: 8, as: UInt.self)
        fakeClass.storeBytes(of: UInt(1), toByteOffset: 32, as: UInt.self)
        fakeObject.storeBytes(of: UInt(bitPattern: fakeClass), as: UInt.self)

        // 有效描述符 + 堆上类 metadata：可识别名称，但绝不能交给 reflectionMirror。
        guard let heapClass = malloc(80), let heapObject = malloc(32) else {
            fatalError("测试堆块分配失败")
        }
        defer { free(heapObject); free(heapClass) }
        memset(heapClass, 0, 80)
        memset(heapObject, 0, 32)
        let realMetadata = unsafeBitCast(type(of: strongRoot.subject), to: UnsafeRawPointer.self)
        memcpy(heapClass, realMetadata, 80)
        heapObject.storeBytes(of: UInt(bitPattern: heapClass), as: UInt.self)
        heapObject.storeBytes(of: unsafeBitCast(strongRoot, to: UInt.self), toByteOffset: 16, as: UInt.self)

        withExtendedLifetime((strongRoot, weakRoot, bagRoot, wideRoot, objcArray, notificationRoot,
                              syntheticRoot, globalRoot, staticRoot)) {
            precondition(enumerateHeapBlockRanges().contains { $0.lowerBound == UInt(bitPattern: fakeObject) },
                         "伪造堆块未进入枚举，回归测试无效")
            let scanner = MemoryGraphScanner()
            scanner.identifyObjects()
            precondition(!scanner.objects.contains { $0.address == UInt(bitPattern: fakeObject) },
                         "伪造的类 metadata 被误识别为对象")
            precondition(scanner.objects.contains { $0.address == UInt(bitPattern: heapObject) },
                         "堆上 metadata 测试对象未进入扫描")
            guard let heapReport = scanner.referenceReport(of: UInt(bitPattern: heapObject)) else {
                fatalError("堆上 metadata 对象无法查询")
            }
            precondition(heapReport.outgoing.contains {
                $0.to == unsafeBitCast(strongRoot, to: UInt.self)
                    && $0.ownership == .unconfirmedStrong
            }, "动态 metadata 原始字扫描丢失引用或误报为确认 strong")
            guard let strongReport = scanner.referenceReport(of: unsafeBitCast(strongRoot, to: UInt.self)),
                  let weakReport = scanner.referenceReport(of: unsafeBitCast(weakRoot, to: UInt.self)),
                  let bagReport = scanner.referenceReport(of: unsafeBitCast(bagRoot, to: UInt.self)),
                  let wideReport = scanner.referenceReport(of: unsafeBitCast(wideRoot, to: UInt.self)),
                  let notificationReport = scanner.referenceReport(of: unsafeBitCast(notificationRoot, to: UInt.self)),
                  let syntheticReport = scanner.referenceReport(of: unsafeBitCast(syntheticRoot, to: UInt.self)),
                  let globalReport = scanner.referenceReport(of: unsafeBitCast(globalRoot, to: UInt.self)),
                  let staticReport = scanner.referenceReport(of: unsafeBitCast(staticRoot, to: UInt.self)),
                  scanner.referenceReport(of: unsafeBitCast(objcArray, to: UInt.self)) != nil else {
                fatalError("RxSwift 测试对象未被堆扫描识别")
            }

            let hasSubjectCycle = strongReport.cycles.contains { cycle in
                cycle.edges.contains { strongReport.classNameByAddress[$0.to]?.contains("PublishSubject") == true }
                    && cycle.edges.contains { strongReport.classNameByAddress[$0.to]?.contains("AnonymousObserver") == true }
            }
            let hasConfirmedIncoming = strongReport.incoming.contains { edge in
                edge.ownership == .strong
                    && strongReport.classNameByAddress[edge.from]?.contains("AnonymousObserver") == true
            }
            let hasBagCycle = bagReport.cycles.contains { cycle in
                cycle.edges.contains { bagReport.classNameByAddress[$0.to]?.contains("DisposeBag") == true }
                    && cycle.edges.contains { bagReport.classNameByAddress[$0.to]?.contains("SinkDisposer") == true }
            }
            precondition(hasSubjectCycle, "PublishSubject 的强捕获环未检出")
            precondition(hasConfirmedIncoming, "强捕获未出现在确认 strong 来源列表")
            precondition(weakReport.cycles.isEmpty, "弱捕获被误报为循环引用")
            precondition(hasBagCycle, "DisposeBag 持有的订阅长环未检出")
            precondition(wideReport.cycles.contains { cycle in
                cycle.edges.contains { wideReport.classNameByAddress[$0.to]?.contains("DisposeBag") == true }
            }, "属性多的对象未检出 DisposeBag 订阅环")
            precondition(wideReport.cycles.contains { cycle in
                cycle.edges.contains { wideReport.classNameByAddress[$0.to]?.contains("BehaviorRelay") == true }
            }, "同一对象的第二条 RxSwift 订阅环未检出")
            let businessClosureCycles = wideReport.cycles.filter { cycle in
                cycle.edges.contains { $0.ivarName?.contains("RxSwiftCaptureFixture") == true }
            }
            precondition(businessClosureCycles.count >= 2,
                         "RxSwift 包装层未还原到 notification / relay 的业务闭包符号")
            precondition(wideReport.cycles.contains { cycle in
                cycle.edges.contains { wideReport.classNameByAddress[$0.to]?.contains("BehaviorRelay") == true }
                    && cycle.edges.contains { $0.ivarName?.contains("RxSwiftCaptureFixture") == true }
            }, "大量无关 Relay 之前耗尽预算，目标 relay 的业务闭包环未检出")
            // macOS Foundation 的 token 不持有 block：这是通知中心根持有造成的泄漏，
            // 不能伪造为从根对象出发的循环引用；block 强捕获仍应列为 incoming。
            precondition(notificationReport.cycles.isEmpty, "NotificationCenter 根持有被误报为循环引用")
            precondition(notificationReport.incoming.contains { edge in
                edge.ownership == .strong
                    && notificationReport.classNameByAddress[edge.from]?.contains("__NSMallocBlock__") == true
            }, "NotificationCenter block 的强捕获未列入来源")
            precondition(!notificationReport.notificationRetentions.isEmpty,
                         "NotificationCenter 外部根长期持有未单独告警")
            let hasTokenCycle = syntheticReport.cycles.contains { cycle in
                cycle.edges.contains {
                    syntheticReport.classNameByAddress[$0.to]?.contains("MGBlockObserverToken") == true
                }
            }
            precondition(hasTokenCycle, "真正的 token → block → owner 环未检出")
            precondition(globalReport.incoming.contains { edge in
                globalReport.classNameByAddress[edge.from]?.contains("全局/静态根") == true
            }, "顶层全局变量的强引用未进入 incoming")
            precondition(staticReport.incoming.contains { edge in
                staticReport.classNameByAddress[edge.from]?.contains("全局/静态根") == true
            }, "static 存储属性的强引用未进入 incoming")
            FileHandle.standardOutput.write(Data("RxSwift 环与 NotificationCenter 根持有/真环对照均通过\n".utf8))
        }
    }
}
