//
//  SessionManager.swift
//  Tiercel
//
//  Created by Daniels on 2018/3/16.
//  Copyright © 2018 Daniels. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

public class SessionManager {
    
    enum MaintainTasksAction {
        case append(DownloadTask)
        case remove(DownloadTask)
        case succeeded(DownloadTask)
        case appendRunningTasks(DownloadTask)
        case removeRunningTasks(DownloadTask)
    }
    
    public let operationQueue: DispatchQueue

    private let operationQueueKey = DispatchSpecificKey<UUID>()

    private let operationQueueID = UUID()
    
    public let cache: Cache
    
    public let identifier: String
    
    public var completionHandler: (() -> Void)?
    
    private var timer: DispatchSourceTimer?
    
    private var session: URLSession?
    
    private var shouldCreatSession: Bool = false

    private struct RestartRequest {
        let task: DownloadTask
        let onMainQueue: Bool
        let handler: Handler<DownloadTask>?
    }

    private var restartRequests: [RestartRequest] = []

    /// Prevents per-task terminal callbacks from completing the manager while a
    /// total cancel/remove operation is still walking its task snapshot.
    private var isPerformingTotalTaskControl = false

    public var configuration: SessionConfiguration {
        get { mutableState.read { $0.configuration } }
        set {
            var oldMaxConcurrentTasksLimit: Int = 0
            mutableState.write {
                oldMaxConcurrentTasksLimit = $0.configuration.maxConcurrentTasksLimit
                $0.configuration = newValue
            }
            operationQueue.async {
                if !self.shouldCreatSession {
                    self.shouldCreatSession = true
                    let (status, maxConcurrentTasksLimit, runningTasks, tasks) = self.mutableState.read {
                        ($0.status, $0.configuration.maxConcurrentTasksLimit, $0.runningTasks, $0.tasks)
                    }
                    if status == .running {
                        let restartTasks: [DownloadTask]
                        if maxConcurrentTasksLimit <= oldMaxConcurrentTasksLimit {
                            restartTasks = runningTasks + tasks.filter { $0.status == .waiting }
                        } else {
                            restartTasks = tasks.filter { $0.status == .waiting || $0.status == .running }
                        }
                        self.restartRequests = restartTasks.map {
                            RestartRequest(task: $0, onMainQueue: true, handler: nil)
                        }
                        self.totalSuspendOnOperationQueue()
                    } else {
                        self.invalidateSessionForRecreationIfNeeded()
                    }
                }
            }
        }
    }
    
    private struct MutableState {
        var logger: Logable
        var isControlNetworkActivityIndicator: Bool = true
        var configuration: SessionConfiguration
        var status: Status = .waiting
        var tasks: [DownloadTask] = []
        var taskMap: [URL: DownloadTask] = [URL: DownloadTask]()
        var sessionTaskMap: [ObjectIdentifier: DownloadTask] = [:]
        var discardedSessionTasks: [ObjectIdentifier: URLSessionTask] = [:]
        var urlMap: [URL: URL] = [URL: URL]()
        var runningTasks: [DownloadTask] = []
        var succeededTasks: [DownloadTask] = []
        var speed: Int64 = 0
        var timeRemaining: Int64 = 0
        
        var progressExecuter: Executer<SessionManager>?
        var successExecuter: Executer<SessionManager>?
        var failureExecuter: Executer<SessionManager>?
        var completionExecuter: Executer<SessionManager>?
        var controlExecuter: Executer<SessionManager>?
        var isSuspending: Bool = false
    }
    
    private let mutableState: Protected<MutableState>
    
    public var logger: Logable {
        mutableState.read { $0.logger }
    }
    
    public var isControlNetworkActivityIndicator: Bool {
        get { mutableState.read { $0.isControlNetworkActivityIndicator } }
        set { mutableState.write { $0.isControlNetworkActivityIndicator = newValue } }
    }
    
    
    public var canRunImmediately: Bool {
        mutableState.read { $0.runningTasks.count < $0.configuration.maxConcurrentTasksLimit }
    }
    
    public var status: Status {
        mutableState.read { $0.status }
    }
    
    public var tasks: [DownloadTask] {
        mutableState.read { $0.tasks }
    }
    
    public var succeededTasks: [DownloadTask] {
        mutableState.read { $0.succeededTasks }
    }
    
    private let _progress = Progress()
    public var progress: Progress {
        mutableState.read {
            _progress.completedUnitCount = $0.tasks.reduce(0, { $0 + $1.progress.completedUnitCount })
            _progress.totalUnitCount = $0.tasks.reduce(0, { $0 + $1.progress.totalUnitCount })
        }
        return _progress
    }
    
    public var speed: Int64 {
        mutableState.read { $0.speed }
    }
    
    public var speedString: String {
        speed.tr.convertSpeedToString()
    }
    
    public var timeRemaining: Int64 {
        mutableState.read { $0.timeRemaining }
    }
    
    public var timeRemainingString: String {
        timeRemaining.tr.convertTimeToString()
    }
    
    private var progressExecuter: Executer<SessionManager>? {
        get { mutableState.read { $0.progressExecuter } }
        set { mutableState.write { $0.progressExecuter = newValue } }
    }
    
    private var successExecuter: Executer<SessionManager>? {
        get { mutableState.read { $0.successExecuter } }
        set { mutableState.write { $0.successExecuter = newValue } }
    }
    
    private var failureExecuter: Executer<SessionManager>? {
        get { mutableState.read { $0.failureExecuter } }
        set { mutableState.write { $0.failureExecuter = newValue } }
    }
    
    private var completionExecuter: Executer<SessionManager>? {
        get { mutableState.read { $0.completionExecuter } }
        set { mutableState.write { $0.completionExecuter = newValue } }
    }
    
    private var controlExecuter: Executer<SessionManager>? {
        get { mutableState.read { $0.controlExecuter } }
        set { mutableState.write { $0.controlExecuter = newValue } }
    }
    
    
    
    public init(_ identifier: String,
                configuration: SessionConfiguration,
                logger: Logable? = nil,
                cache: Cache? = nil,
                operationQueue: DispatchQueue = DispatchQueue(label: "com.Tiercel.SessionManager.operationQueue",
                                                              autoreleaseFrequency: .workItem)) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.Daniels.Tiercel"
        let composeIdentifier = "\(bundleIdentifier).\(identifier)"
        self.identifier = composeIdentifier
        let logger = logger ?? Logger(identifier: composeIdentifier, option: .default)
        mutableState = Protected(MutableState(logger: logger,
                                              configuration: configuration))
        self.operationQueue = operationQueue
        operationQueue.setSpecific(key: operationQueueKey, value: operationQueueID)
        self.cache = cache ?? Cache(identifier)
        self.cache.logger = logger
        self.cache.retrieveAllTasks(with: operationQueue)
            .filter { $0.status != .canceled && $0.status != .removed }
            .forEach { maintainTasks(with: .append($0)) }
        log(.sessionManager(self, message: "retrieveTasks"))
        mutableState.write { state in
            state.tasks.forEach {
                $0.delegate = self
                state.urlMap[$0.currentURL] = $0.url
            }
            state.succeededTasks = state.tasks.filter { $0.status == .succeeded }
        }
        operationQueue.sync {
            shouldCreatSession = true
            createSession()
            restoreStatus()
        }
    }
    
    deinit {
        invalidate()
    }
    
    private func invalidate() {
        if DispatchQueue.getSpecific(key: operationQueueKey) == operationQueueID {
            invalidateOnOperationQueue()
        } else {
            operationQueue.sync {
                self.invalidateOnOperationQueue()
            }
        }
    }

    private func invalidateOnOperationQueue() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        session?.invalidateAndCancel()
        session = nil
        invalidateTimer()
    }
    
    
    private func createSession() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard shouldCreatSession else { return }
        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: identifier)
        mutableState.read { state in
            sessionConfiguration.timeoutIntervalForRequest = state.configuration.timeoutIntervalForRequest
            sessionConfiguration.httpMaximumConnectionsPerHost = 100000
            sessionConfiguration.allowsCellularAccess = state.configuration.allowsCellularAccess
            if #available(iOS 13, macOS 10.15, *) {
                sessionConfiguration.allowsConstrainedNetworkAccess = state.configuration.allowsConstrainedNetworkAccess
                sessionConfiguration.allowsExpensiveNetworkAccess = state.configuration.allowsExpensiveNetworkAccess
            }
        }
        let sessionDelegate = SessionDelegate()
        sessionDelegate.stateProvider = self
        let delegateQueue = OperationQueue(maxConcurrentOperationCount: 1,
                                           underlyingQueue: operationQueue,
                                           name: "com.Tiercel.SessionManager.delegateQueue")
        session = URLSession(configuration: sessionConfiguration,
                             delegate: sessionDelegate,
                             delegateQueue: delegateQueue)
        shouldCreatSession = false
    }
}


// MARK: - download
extension SessionManager {
    
    
    /// 开启一个下载任务
    ///
    /// - Parameters:
    ///   - url: URLConvertible
    ///   - headers: headers
    ///   - fileName: 下载文件的文件名，如果传nil，则默认为url的md5加上文件扩展名
    /// - Returns: 如果url有效，则返回对应的task；如果url无效，则返回nil
    @discardableResult
    public func download(_ url: URLConvertible,
                         headers: [String: String]? = nil,
                         fileName: String? = nil,
                         onMainQueue: Bool = true,
                         handler: Handler<DownloadTask>? = nil) -> DownloadTask? {
        do {
            let validURL = try url.asURL()
            var task: DownloadTask!
            operationQueue.sync {
                task = fetchTask(validURL)
                if let task = task {
                    task.update(headers, newFileName: fileName)
                } else {
                    task = DownloadTask(validURL,
                                        headers: headers,
                                        fileName: fileName,
                                        cache: cache,
                                        operationQueue: operationQueue)
                    task.delegate = self
                    maintainTasks(with: .append(task))
                }
                storeTasks()
                _start(task, onMainQueue: onMainQueue, handler: handler)
            }
            return task
        } catch {
            log(.error(error, message: "create dowloadTask failed"))
            return nil
        }
        
    }
    
    
    /// 批量开启多个下载任务, 所有任务都会并发下载
    ///
    /// - Parameters:
    ///   - urls: [URLConvertible]
    ///   - headers: headers
    ///   - fileNames: 下载文件的文件名，如果传nil，则默认为url的md5加上文件扩展名
    /// - Returns: 返回url数组中有效url对应的task数组
    @discardableResult
    public func multiDownload(_ urls: [URLConvertible],
                              headersArray: [[String: String]]? = nil,
                              fileNames: [String]? = nil,
                              onMainQueue: Bool = true,
                              handler: Handler<SessionManager>? = nil) -> [DownloadTask] {
        if let headersArray = headersArray,
           !headersArray.isEmpty && headersArray.count != urls.count {
            log(.error(TiercelError.headersMatchFailed, message: "create multiple dowloadTasks failed"))
            return [DownloadTask]()
        }
        
        if let fileNames = fileNames,
           !fileNames.isEmpty && fileNames.count != urls.count {
            log(.error(TiercelError.fileNamesMatchFailed, message: "create multiple dowloadTasks failed"))
            return [DownloadTask]()
        }
        
        var urlSet = Set<URL>()
        var uniqueTasks = [DownloadTask]()
        
        operationQueue.sync {
            for (index, url) in urls.enumerated() {
                guard let validURL = try? url.asURL() else {
                    log(.error(TiercelError.invalidURL(url: url), message: "create dowloadTask failed"))
                    continue
                }
                guard urlSet.insert(validURL).inserted else {
                    log(.error(TiercelError.duplicateURL(url: url), message: "create dowloadTask failed"))
                    continue
                }
                let fileName = fileNames?.safeObject(at: index)
                let headers = headersArray?.safeObject(at: index)
                
                var task: DownloadTask!
                task = fetchTask(validURL)
                if let task = task {
                    task.update(headers, newFileName: fileName)
                } else {
                    task = DownloadTask(validURL,
                                        headers: headers,
                                        fileName: fileName,
                                        cache: cache,
                                        operationQueue: operationQueue)
                    task.delegate = self
                    maintainTasks(with: .append(task))
                }
                uniqueTasks.append(task)
            }
            storeTasks()
            Executer(onMainQueue: onMainQueue, handler: handler).execute(self)
            // TODO: - 待优化
            operationQueue.async {
                uniqueTasks.forEach {
                    if $0.status != .succeeded {
                        self._start($0)
                    }
                }
            }
        }
        return uniqueTasks
    }
}

// MARK: - single task control
extension SessionManager {
    
    public func fetchTask(_ url: URLConvertible) -> DownloadTask? {
        do {
            let validURL = try url.asURL()
            return mutableState.read { $0.taskMap[validURL] }
        } catch {
            log(.error(TiercelError.invalidURL(url: url), message: "fetch task failed"))
            return nil
        }
    }
    
    func mapTask(_ currentURL: URL) -> DownloadTask? {
        mutableState.read {
            let url = $0.urlMap[currentURL] ?? currentURL
            return $0.taskMap[url]
        }
    }
    
    
    
    /// 开启任务
    /// 会检查存放下载完成的文件中是否存在跟fileName一样的文件
    /// 如果存在则不会开启下载，直接调用task的successHandler
    public func start(_ url: URLConvertible, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            self._start(url, onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    public func start(_ task: DownloadTask, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            self._start(task.url, onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    private func _start(_ url: URLConvertible, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        guard let task = self.fetchTask(url) else {
            log(.error(TiercelError.fetchDownloadTaskFailed(url: url), message: "can't start downloadTask"))
            return
        }
        _start(task, onMainQueue: onMainQueue, handler: handler)
    }
    
    private func _start(_ task: DownloadTask, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard !shouldCreatSession, let session = session else {
            enqueueRestart(task, onMainQueue: onMainQueue, handler: handler)
            return
        }
        guard !task.isSuspending else { return }

        task.mutableState.write {
            $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        }
        // 幂等重启已成功任务不会产生真实传输，保持 manager 终态，
        // 让后续 determineStatus 走终态早退守卫而不是重新收敛
        if task.status != .succeeded {
            didStart()
        }
        task.start(using: session, immediately: canRunImmediately)
    }

    private func enqueueRestart(_ task: DownloadTask,
                                onMainQueue: Bool,
                                handler: Handler<DownloadTask>?) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        let request = RestartRequest(task: task, onMainQueue: onMainQueue, handler: handler)
        if let index = restartRequests.firstIndex(where: { $0.task === task }) {
            // Internal restarts must not erase a user-supplied start callback already waiting to run.
            if handler != nil {
                restartRequests[index] = request
            }
        } else {
            restartRequests.append(request)
        }
    }
    
    
    /// 暂停任务，会触发sessionDelegate的完成回调
    public func suspend(_ url: URLConvertible, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard let task = self.fetchTask(url) else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: url), message: "can't suspend downloadTask"))
                return
            }
            task.suspend(onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    public func suspend(_ task: DownloadTask, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard self.fetchTask(task.url) === task else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: task.url), message: "can't suspend downloadTask"))
                return
            }
            task.suspend(onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    /// 取消任务
    /// 不会对已经完成的任务造成影响
    /// 其他状态的任务都可以被取消，被取消的任务会被移除
    /// 会删除还没有下载完成的缓存文件
    /// 会触发sessionDelegate的完成回调
    public func cancel(_ url: URLConvertible, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard let task = self.fetchTask(url) else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: url), message: "can't cancel downloadTask"))
                return
            }
            task.cancel(onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    public func cancel(_ task: DownloadTask, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard self.fetchTask(task.url) === task else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: task.url), message: "can't cancel downloadTask"))
                return
            }
            task.cancel(onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    
    /// 移除任务
    /// 所有状态的任务都可以被移除
    /// 会删除还没有下载完成的缓存文件
    /// 可以选择是否删除下载完成的文件
    /// 会触发sessionDelegate的完成回调
    ///
    /// - Parameters:
    ///   - url: URLConvertible
    ///   - completely: 是否删除下载完成的文件
    public func remove(_ url: URLConvertible, completely: Bool = false, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard let task = self.fetchTask(url) else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: url), message: "can't remove downloadTask"))
                return
            }
            task.remove(completely: completely, onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    public func remove(_ task: DownloadTask, completely: Bool = false, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        operationQueue.async {
            guard self.fetchTask(task.url) === task else {
                self.log(.error(TiercelError.fetchDownloadTaskFailed(url: task.url),
                                message: "can't remove downloadTask"))
                return
            }
            task.remove(completely: completely, onMainQueue: onMainQueue, handler: handler)
        }
    }
    
    public func moveTask(at sourceIndex: Int, to destinationIndex: Int) {
        operationQueue.sync {
            let didMove = mutableState.write { state -> Bool in
                let indices = state.tasks.indices
                guard indices ~= sourceIndex && indices ~= destinationIndex else { return false }
                guard sourceIndex != destinationIndex else { return true }
                let task = state.tasks[sourceIndex]
                state.tasks.remove(at: sourceIndex)
                state.tasks.insert(task, at: destinationIndex)
                return true
            }
            guard didMove else {
                log(.error(TiercelError.indexOutOfRange,
                           message: "move task failed, sourceIndex: \(sourceIndex), destinationIndex: \(destinationIndex)"))
                return
            }
        }
    }
    
}

// MARK: - total tasks control
extension SessionManager {
    
    public func totalStart(onMainQueue: Bool = true, handler: Handler<SessionManager>? = nil) {
        operationQueue.async {
            self.mutableState.read { $0.tasks }.forEach { task in
                if task.status != .succeeded {
                    self._start(task)
                }
            }
            Executer(onMainQueue: onMainQueue, handler: handler).execute(self)
        }
    }
    
    public func totalSuspend(onMainQueue: Bool = true, handler: Handler<SessionManager>? = nil) {
        operationQueue.async {
            self.totalSuspendOnOperationQueue(onMainQueue: onMainQueue, handler: handler)
        }
    }

    private func totalSuspendOnOperationQueue(onMainQueue: Bool = true,
                                              handler: Handler<SessionManager>? = nil) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        let tasks: [DownloadTask]? = mutableState.write {
            guard $0.status == .running || $0.status == .waiting else { return nil }
            $0.isSuspending = true
            $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
            return $0.tasks
        }
        guard let tasks = tasks else {
            invalidateSessionForRecreationIfNeeded()
            return
        }
        tasks.forEach { $0.suspend() }
        determineStatus(fromRunningTask: false)
    }
    
    public func totalCancel(onMainQueue: Bool = true, handler: Handler<SessionManager>? = nil) {
        operationQueue.async {
            let tasks: [DownloadTask]? = self.mutableState.write {
                guard $0.status != .succeeded && $0.status != .canceled else { return nil }
                $0.status = .canceled
                $0.isSuspending = false
                $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
                return $0.tasks
            }
            guard let tasks = tasks else { return }
            self.didChangeStatus(to: .canceled)
            self.isPerformingTotalTaskControl = true
            tasks.forEach { $0.cancel() }
            self.isPerformingTotalTaskControl = false
            self.executeControl()
            self.ending(false)
        }
    }
    
    public func totalRemove(completely: Bool = false, onMainQueue: Bool = true, handler: Handler<SessionManager>? = nil) {
        operationQueue.async {
            let tasks: [DownloadTask]? = self.mutableState.write {
                guard $0.status != .removed else { return nil }
                $0.status = .removed
                $0.isSuspending = false
                $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
                return $0.tasks
            }
            guard let tasks = tasks else { return }
            self.didChangeStatus(to: .removed)
            self.isPerformingTotalTaskControl = true
            tasks.forEach { $0.remove(completely: completely) }
            self.isPerformingTotalTaskControl = false
            self.executeControl()
            self.ending(false)
        }
    }
    
    public func tasksSort(by areInIncreasingOrder: (DownloadTask, DownloadTask) throws -> Bool) rethrows {
        if DispatchQueue.getSpecific(key: operationQueueKey) == operationQueueID {
            try sortTasks(by: areInIncreasingOrder)
        } else {
            try operationQueue.sync {
                try sortTasks(by: areInIncreasingOrder)
            }
        }
    }

    private func sortTasks(by areInIncreasingOrder: (DownloadTask, DownloadTask) throws -> Bool) rethrows {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        var tasks = mutableState.read { $0.tasks }
        try tasks.sort(by: areInIncreasingOrder)
        mutableState.write { $0.tasks = tasks }
    }
}


// MARK: - status handle
extension SessionManager {
    
    private func maintainTasks(with action: MaintainTasksAction) {
        
        mutableState.write { state in
            switch action {
            case let .append(task):
                state.tasks.append(task)
                state.taskMap[task.url] = task
                state.urlMap[task.currentURL] = task.url
            case let .remove(task):
                state.taskMap.removeValue(forKey: task.url)
                state.urlMap = state.urlMap.filter { $0.value != task.url }
                state.tasks.removeAll {
                    $0 === task
                }
                if task.status == .removed {
                    state.succeededTasks.removeAll {
                        $0 === task
                    }
                }
            case let .succeeded(task):
                if !state.succeededTasks.contains(where: { $0 === task }) {
                    state.succeededTasks.append(task)
                }
            case let .appendRunningTasks(task):
                if !state.runningTasks.contains(where: { $0 === task }) {
                    state.runningTasks.append(task)
                }
            case let .removeRunningTasks(task):
                state.runningTasks.removeAll {
                    $0.url.absoluteString == task.url.absoluteString
                }
            }
        }
    }
    
    private func updateUrlMapper(with task: DownloadTask) {
        mutableState.write { $0.urlMap[task.currentURL] = task.url }
        storeTasks()
    }
    
    private func restoreStatus() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        // getAllTasks 是异步快照。只允许对查询开始时已存在的逻辑任务做恢复，
        // 避免 completion 返回前用户新建的任务被旧快照修改。
        let (restorableTasks, runningTaskIDs) = mutableState.read { state in
            let restorableTasks = Dictionary(uniqueKeysWithValues: state.tasks.map {
                (ObjectIdentifier($0), $0)
            })
            let runningTaskIDs = Set(state.tasks
                .filter { $0.status == .running }
                .map(ObjectIdentifier.init))
            return (restorableTasks, runningTaskIDs)
        }
        session?.getTasksWithCompletionHandler { [weak self] (dataTasks, uploadTasks, downloadTasks) in
            guard let self = self else { return }
            dispatchPrecondition(condition: .onQueue(operationQueue))
            reconcile(
                downloadTasks: downloadTasks,
                restorableTasks: restorableTasks,
                runningTaskIDs: runningTaskIDs
            )
        }
    }

    private func reconcile(downloadTasks: [URLSessionDownloadTask],
                           restorableTasks: [ObjectIdentifier: DownloadTask],
                           runningTaskIDs: Set<ObjectIdentifier>) {
        dispatchPrecondition(condition: .onQueue(operationQueue))

        // 先按逻辑 DownloadTask 分组。一个逻辑任务在异常退出或重复启动后，可能对应多个系统 transfer，
        // 因此不能在遍历 getAllTasks 结果时直接按 URL 恢复第一个任务。
        var candidates: [ObjectIdentifier: (task: DownloadTask, transfers: [URLSessionDownloadTask])] = [:]

        for downloadTask in downloadTasks {
            // canceling transfer 的最终回调可能早于或晚于本次对账，交给 delegate 的恢复回调路径处理。
            // 这里既不接管，也不标记为 discarded，避免吞掉回调中的 resumeData。
            guard downloadTask.state == .running || downloadTask.state == .suspended else { continue }

            // 找不到缓存逻辑任务的活跃 transfer 属于真正的孤儿任务，需要主动终止。
            guard let currentURL = downloadTask.currentRequest?.url ?? downloadTask.originalRequest?.url,
                  let task = mapTask(currentURL) else {
                discardTransfer(downloadTask)
                continue
            }

            // succeeded 是不可回退的终态；其余非终态以仍然存在的系统 transfer 为真实传输状态，
            // 即使缓存还是 suspended 或 failed，也允许在下一阶段恢复为 running。
            guard task.status != .succeeded else {
                discardTransfer(downloadTask)
                continue
            }

            let identifier = ObjectIdentifier(task)
            guard restorableTasks[identifier] === task else {
                // 查询发起后新建的任务不属于本次恢复。若这个 transfer 已由新任务接管则保持原样，
                // 否则它是与新逻辑任务同 URL 的旧 transfer，需要淘汰。
                if task.activeSessionTask !== downloadTask {
                    discardTransfer(downloadTask)
                }
                continue
            }
            if var candidate = candidates[identifier] {
                candidate.transfers.append(downloadTask)
                candidates[identifier] = candidate
            } else {
                candidates[identifier] = (task, [downloadTask])
            }
        }

        // 每个逻辑任务只采纳一个权威 transfer。选择顺序为 running、已下载字节数、较新的 taskIdentifier；
        // 这样既不会依赖 getAllTasks 的返回顺序，也能尽量保留下载进度。
        var adoptedTasks = Set<ObjectIdentifier>()
        for (identifier, candidate) in candidates {
            if let activeTransfer = candidate.task.activeSessionTask {
                // The task was started after getAllTasks began. That new transfer is already mapped
                // and must remain authoritative; adopting an older snapshot transfer would orphan it.
                adoptedTasks.insert(identifier)
                candidate.transfers
                    .filter { $0 !== activeTransfer }
                    .forEach { discardTransfer($0) }
                continue
            }
            guard let adoptedTransfer = preferredTransfer(in: candidate.transfers) else { continue }
            adoptedTasks.insert(identifier)

            // adopted transfer 重新建立逻辑任务、runningTasks 和实例映射，确保后续回调按实例路由。
            didStart()
            candidate.task.restoreRunningStatus(with: adoptedTransfer)
            taskDidStart(candidate.task)
            if adoptedTransfer.state == .suspended {
                adoptedTransfer.resume()
            }

            // 同一逻辑任务的其他 transfer 已被本次对账淘汰。它们的回调只用于释放底层资源，
            // 不得覆盖 adopted transfer 的进度、resumeData 或最终状态。
            candidate.transfers
                .filter { $0 !== adoptedTransfer }
                .forEach { discardTransfer($0) }
        }

        // 缓存声称仍在 running、但系统中不存在可采纳 transfer 的任务已经成为孤儿状态。
        // 将其降级为 suspended，允许用户安全重新开始，而不是永久卡在 running。
        mutableState.read { $0.tasks }
            .filter {
                let identifier = ObjectIdentifier($0)
                return $0.status == .running &&
                    runningTaskIDs.contains(identifier) &&
                    !adoptedTasks.contains(identifier) &&
                    $0.activeSessionTask == nil
            }
            .forEach { $0.restoreSuspendedStatus() }

        storeTasks()
        // 没有任何系统传输被恢复时，重新计算 Manager 的 suspended/completed 聚合状态。
        if adoptedTasks.isEmpty {
            shouldSuspendOrComplete()
        }
    }

    private func preferredTransfer(in transfers: [URLSessionDownloadTask]) -> URLSessionDownloadTask? {
        return transfers.sorted { lhs, rhs in
            return SessionManager.shouldPreferTransfer(state: lhs.state,
                                                       bytesReceived: lhs.countOfBytesReceived,
                                                       taskIdentifier: lhs.taskIdentifier,
                                                       overState: rhs.state,
                                                       bytesReceived: rhs.countOfBytesReceived,
                                                       taskIdentifier: rhs.taskIdentifier)
        }.first
    }

    static func shouldPreferTransfer(state: URLSessionTask.State,
                                     bytesReceived: Int64,
                                     taskIdentifier: Int,
                                     overState otherState: URLSessionTask.State,
                                     bytesReceived otherBytesReceived: Int64,
                                     taskIdentifier otherTaskIdentifier: Int) -> Bool {
        let isRunning = state == .running
        let otherIsRunning = otherState == .running
        if isRunning != otherIsRunning {
            return isRunning
        }
        if bytesReceived != otherBytesReceived {
            return bytesReceived > otherBytesReceived
        }
        return taskIdentifier > otherTaskIdentifier
    }

    private func discardTransfer(_ sessionTask: URLSessionTask, shouldCancel: Bool = true) {
        let identifier = ObjectIdentifier(sessionTask)
        mutableState.write {
            $0.discardedSessionTasks[identifier] = sessionTask
            $0.sessionTaskMap.removeValue(forKey: identifier)
        }
        if shouldCancel && sessionTask.state != .canceling {
            sessionTask.cancel()
        }
    }
    
    
    private func shouldSuspendOrComplete() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        let result = mutableState.read { state -> (isSuspended: Bool, isCompleted: Bool)? in
            guard !state.tasks.isEmpty else { return nil }
            if state.tasks.allSatisfy({ $0.status == .succeeded }) {
                return (false, true)
            }
            let isCompleted = state.tasks.allSatisfy { $0.status == .succeeded || $0.status == .failed }
            if isCompleted {
                return (false, true)
            }
            let isSuspended = state.tasks.allSatisfy { $0.status == .suspended || $0.status == .succeeded || $0.status == .failed }
            return (isSuspended, false)
        }
        guard let (isSuspended, isCompleted) = result else { return }

        // 复用统一收尾，保证 storeTasks/invalidateTimer 与常规路径一致
        if isCompleted {
            finishCompletedTasks(mutableState.read { $0.tasks })
        } else if isSuspended {
            finishSuspending()
        }
    }

    @discardableResult
    private func invalidateSessionForRecreationIfNeeded() -> Bool {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard shouldCreatSession else { return false }
        session?.invalidateAndCancel()
        session = nil
        return true
    }
    
    private func didStart() {
        let didTransition = mutableState.write { state -> Bool in
            guard state.status != .running else { return false }
            state.status = .running
            return true
        }
        guard didTransition else { return }
        
        if isControlNetworkActivityIndicator {
#if canImport(UIKit) && !os(visionOS)
            DispatchQueue.tr.executeOnMain {
                UIApplication.shared.isNetworkActivityIndicatorVisible = true
            }
#endif
        }
        createTimer()
        didChangeStatus(to: .running)
        progressExecuter?.execute(self)
        
    }
    
    private func updateProgress() {
        progressExecuter?.execute(self)
        NotificationCenter.default.postNotification(name: SessionManager.runningNotification, sessionManager: self)
    }
    
    
    private func storeTasks() {
        cache.storeTasks(mutableState.read { $0.tasks })
    }
    
    private func determineStatus(fromRunningTask: Bool) {
        dispatchPrecondition(condition: .onQueue(operationQueue))

        let (currentStatus, tasks, isSuspending) = mutableState.read {
            ($0.status, $0.tasks, $0.isSuspending)
        }
        
        // 处理 isSuspending 中的情况
        if isSuspending {
            let didFinishSuspending = tasks.allSatisfy {
                !$0.isSuspending && ($0.status == .suspended || $0.status == .succeeded || $0.status == .failed)
            }
            guard didFinishSuspending else { return }
            mutableState.write { $0.isSuspending = false }
            finishSuspending()
            return
        }
        
        // 处理已经有最终状态的情况
        switch currentStatus {
        case .canceled, .removed:
            if tasks.isEmpty && !isPerformingTotalTaskControl {
                ending(false)
            } else {
                storeTasks()
            }
            return
        case .suspended, .succeeded, .failed:
            storeTasks()
            return
        default:
            break
        }

        // 处理 running 的情况
        let isCompleted = tasks.allSatisfy { $0.status == .succeeded || $0.status == .failed }
        if isCompleted {
            finishCompletedTasks(tasks)
            return
        }

        let isSuspended = tasks.allSatisfy {
            $0.status == .suspended ||
            $0.status == .succeeded ||
            $0.status == .failed
        }
        if isSuspended {
            finishSuspending()
            return
        }

        storeTasks()

        guard fromRunningTask else { return }
        operationQueue.async {
            self.startNextTask()
        }
    }

    private func finishCompletedTasks(_ tasks: [DownloadTask]) {
        let isSucceeded = tasks.allSatisfy { $0.status == .succeeded }
        let status: Status = isSucceeded ? .succeeded : .failed
        mutableState.write { $0.timeRemaining = 0 }
        progressExecuter?.execute(self)
        mutableState.write { $0.status = status }
        didChangeStatus(to: status)
        ending(isSucceeded)
        invalidateSessionForRecreationIfNeeded()
    }

    private func finishSuspending() {
        mutableState.write { $0.status = .suspended }
        didChangeStatus(to: .suspended)
        if !invalidateSessionForRecreationIfNeeded() {
            executeControl()
            ending(false)
        }
    }
    
    private func ending(_ isSucceeded: Bool) {
        executeCompletion(isSucceeded)
        storeTasks()
        invalidateTimer()
    }
    
    
    private func startNextTask() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard let session = session,
              let waitingTask = mutableState.read({ $0.tasks.first(where: { $0.status == .waiting }) })
        else { return }
        waitingTask.start(using: session, immediately: canRunImmediately)
    }
}

// MARK: - info
extension SessionManager {
        
    private func createTimer() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        if timer == nil {
            timer = DispatchSource.makeTimerSource(flags: .strict, queue: operationQueue)
            timer?.schedule(deadline: .now(), repeating: 1)
            timer?.setEventHandler(handler: { [weak self] in
                guard let self = self else { return }
                self.updateSpeedAndTimeRemaining()
            })
            timer?.resume()
        }
    }
    
    private func invalidateTimer() {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        timer?.cancel()
        timer = nil
    }
    
    private func updateSpeedAndTimeRemaining() {
        let speed: Int64 = mutableState.read { state in
            state.runningTasks.reduce(Int64(0), {
                $1.updateSpeedAndTimeRemaining()
                return $0 + $1.speed
            })
        }
        updateTimeRemaining(speed)
    }
    
    private func updateTimeRemaining(_ speed: Int64) {
        var timeRemaining: Double
        if speed != 0 {
            timeRemaining = (Double(progress.totalUnitCount) - Double(progress.completedUnitCount)) / Double(speed)
            if timeRemaining >= 0.8 && timeRemaining < 1 {
                timeRemaining += 1
            }
        } else {
            timeRemaining = 0
        }
        mutableState.write {
            $0.speed = speed
            $0.timeRemaining = Int64(timeRemaining)
        }
    }
    
    private func didChangeStatus(to newValue: Status) {
        log(.sessionManager(self, message: newValue.rawValue))
        if newValue == .suspended ||
            newValue == .canceled ||
            newValue == .removed ||
            newValue == .succeeded ||
            newValue == .failed {
            if isControlNetworkActivityIndicator {
#if canImport(UIKit) && !os(visionOS)
                DispatchQueue.tr.executeOnMain {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                }
#endif
            }
        }
    }
    
    private func log(_ type: LogType) {
        logger.log(type)
    }
}

// MARK: - closure
extension SessionManager {
    @discardableResult
    public func progress(onMainQueue: Bool = true, handler: @escaping Handler<SessionManager>) -> Self {
        progressExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        return self
    }
    
    @discardableResult
    public func success(onMainQueue: Bool = true, handler: @escaping Handler<SessionManager>) -> Self {
        let executer = Executer(onMainQueue: onMainQueue, handler: handler)
        let shouldReplay = mutableState.write {
            $0.successExecuter = executer
            return $0.status == .succeeded && $0.completionExecuter == nil
        }
        if shouldReplay {
            operationQueue.async {
                executer.execute(self)
            }
        }
        return self
    }
    
    @discardableResult
    public func failure(onMainQueue: Bool = true, handler: @escaping Handler<SessionManager>) -> Self {
        let executer = Executer(onMainQueue: onMainQueue, handler: handler)
        let shouldReplay = mutableState.write {
            $0.failureExecuter = executer
            return $0.completionExecuter == nil &&
                ($0.status == .suspended ||
                 $0.status == .canceled ||
                 $0.status == .removed ||
                 $0.status == .failed)
        }
        if shouldReplay {
            operationQueue.async {
                executer.execute(self)
            }
        }
        return self
    }
    
    @discardableResult
    public func completion(onMainQueue: Bool = true, handler: @escaping Handler<SessionManager>) -> Self {
        let executer = Executer(onMainQueue: onMainQueue, handler: handler)
        let shouldReplay = mutableState.write {
            $0.completionExecuter = executer
            return $0.status == .suspended ||
                $0.status == .canceled ||
                $0.status == .removed ||
                $0.status == .succeeded ||
                $0.status == .failed
        }
        if shouldReplay {
            operationQueue.async {
                executer.execute(self)
            }
        }
        return self
    }
    
    private func executeCompletion(_ isSucceeded: Bool) {
        if let completionExecuter = completionExecuter {
            completionExecuter.execute(self)
        } else if isSucceeded {
            successExecuter?.execute(self)
        } else {
            failureExecuter?.execute(self)
        }
        NotificationCenter.default.postNotification(name: SessionManager.didCompleteNotification, sessionManager: self)
    }
    
    private func executeControl() {
        controlExecuter?.execute(self)
        controlExecuter = nil
    }
}

// MARK: - TaskDelegate
extension SessionManager: TaskDelegate, UnderlyingTaskDelegate {
    public func task<TaskType>(_ task: Task<TaskType>, didChangeStatusTo newValue: Status) {
        if let task = task as? DownloadTask {
            log(.downloadTask(task, message: newValue.rawValue))
        }
    }
    
    public func taskDidStart<TaskType>(_ task: Task<TaskType>) {
        if let task = task as? DownloadTask {
            maintainTasks(with: .appendRunningTasks(task))
            if let sessionTask = task.activeSessionTask {
                mutableState.write { $0.sessionTaskMap[ObjectIdentifier(sessionTask)] = task }
            }
            storeTasks()
        }
    }
    
    public func taskDidCancelOrRemove<TaskType>(_ task: Task<TaskType>) {
        if let task = task as? DownloadTask {
            maintainTasks(with: .remove(task))
            let isEmpty = mutableState.write { state -> Bool in
                guard state.tasks.isEmpty else { return false }
                state.status = task.status
                return true
            }
            if isEmpty {
                didChangeStatus(to: task.status)
                invalidateTimer()
            }
        }
    }
    
    public func taskDidCompleteFromRunning<TaskType>(_ task: Task<TaskType>) {
        if let task = task as? DownloadTask {
            maintainTasks(with: .removeRunningTasks(task))
        }
    }

    public func taskDidFinishUnderlyingTask<TaskType>(_ task: Task<TaskType>, sessionTask: URLSessionTask) {
        mutableState.write { $0.sessionTaskMap.removeValue(forKey: ObjectIdentifier(sessionTask)) }
    }
    
    public func task<TaskType>(_ task: Task<TaskType>, didSucceed fromRunning: Bool) {
        if let task = task as? DownloadTask {
            maintainTasks(with: .succeeded(task))
        }
        determineStatus(fromRunningTask: fromRunning)
    }
    
    public func task<TaskType>(_ task: Task<TaskType>, didDetermineStatus fromRunning: Bool) {
        determineStatus(fromRunningTask: fromRunning)
    }
    
    public func taskDidUpdateCurrentURL<TaskType>(_ task: Task<TaskType>) {
        if let task = task as? DownloadTask {
            updateUrlMapper(with: task)
        }
    }
    
    public func taskDidUpdateProgress<TaskType>(_ task: Task<TaskType>) {
        updateProgress()
    }
    
}

extension SessionManager: DownloadTaskDelegate {
    public func downloadTaskFileExists(_ task: DownloadTask) {
        log(.downloadTask(task, message: "file already exists"))
    }
    
    public func downloadTaskWillValidateFile(_ task: DownloadTask) {
        storeTasks()
    }
    
    public func downloadTask(_ task: DownloadTask, didValidateFile result: Result<Bool, FileChecksumHelper.FileVerificationError>) {
        switch result {
        case .success:
            log(.downloadTask(task, message: "file validation successful"))
        case let .failure(error):
            log(.error(error, message: "file validation failed, url: \(task.url)"))
        }
        storeTasks()
    }
    
}

// MARK: - SessionStateProvider
extension SessionManager: SessionStateProvider {
    func task<TaskType, R>(for url: URL, as type: R.Type) -> R? where R : Task<TaskType> {
        return mapTask(url) as? R
    }

    func task<TaskType, R>(for sessionTask: URLSessionTask, as type: R.Type) -> R? where R : Task<TaskType> {
        return mutableState.read { $0.sessionTaskMap[ObjectIdentifier(sessionTask)] as? R }
    }

    func shouldDiscardCallbacks(for sessionTask: URLSessionTask) -> Bool {
        return mutableState.read { $0.discardedSessionTasks[ObjectIdentifier(sessionTask)] != nil }
    }

    func didFinishDiscardedTransfer(_ sessionTask: URLSessionTask) {
        let identifier = ObjectIdentifier(sessionTask)
        mutableState.write {
            $0.discardedSessionTasks.removeValue(forKey: identifier)
            $0.sessionTaskMap.removeValue(forKey: identifier)
        }
    }
    
    func log(_ error: Error, message: String) {
        log(.error(error, message: message))
    }
    
    func didBecomeInvalidation(withError error: Error?) {
        createSession()
        let restartRequests = restartRequests
        self.restartRequests.removeAll()
        restartRequests.forEach { request in
            // A queued task may have been canceled or removed while the old session was invalidating.
            // Only replay the request when the same logical task is still owned by this manager.
            guard fetchTask(request.task.url) === request.task,
                  request.task.status != .canceled,
                  request.task.status != .removed
            else { return }
            _start(request.task, onMainQueue: request.onMainQueue, handler: request.handler)
        }
    }
    
    func didFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.tr.executeOnMain {
            self.completionHandler?()
            self.completionHandler = nil
        }
    }
}
