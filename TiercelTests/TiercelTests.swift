//
//  TiercelTests.swift
//  TiercelTests
//
//  Created by Daniels on 2020/8/17.
//  Copyright © 2020 Daniels. All rights reserved.
//

import XCTest
@testable import Tiercel

class TiercelTests: XCTestCase {

    private final class TaskDelegateSpy: TaskDelegate, UnderlyingTaskDelegate {
        var statuses: [Status] = []
        var didRemove = false
        var didDetermineStatusCount = 0
        var didCompleteFromRunningCount = 0
        var finishedSessionTasks: [URLSessionTask] = []

        func task<TaskType>(_ task: Task<TaskType>, didChangeStatusTo newValue: Status) {
            statuses.append(newValue)
        }

        func taskDidStart<TaskType>(_ task: Task<TaskType>) {}

        func taskDidCancelOrRemove<TaskType>(_ task: Task<TaskType>) {
            didRemove = true
        }

        func task<TaskType>(_ task: Task<TaskType>, didSucceed fromRunning: Bool) {}
        func task<TaskType>(_ task: Task<TaskType>, didDetermineStatus fromRunning: Bool) {
            didDetermineStatusCount += 1
        }
        func taskDidUpdateCurrentURL<TaskType>(_ task: Task<TaskType>) {}
        func taskDidUpdateProgress<TaskType>(_ task: Task<TaskType>) {}
        func taskDidCompleteFromRunning<TaskType>(_ task: Task<TaskType>) {
            didCompleteFromRunningCount += 1
        }

        func taskDidFinishUnderlyingTask<TaskType>(_ task: Task<TaskType>, sessionTask: URLSessionTask) {
            finishedSessionTasks.append(sessionTask)
        }
    }

    private final class DiscardingStateProvider: SessionStateProvider {
        var lookupCount = 0
        var didCleanUpDiscardedTransfer = false

        func task<TaskType, R>(for url: URL, as type: R.Type) -> R? where R : Task<TaskType> {
            lookupCount += 1
            return nil
        }

        func task<TaskType, R>(for sessionTask: URLSessionTask, as type: R.Type) -> R? where R : Task<TaskType> {
            lookupCount += 1
            return nil
        }

        func shouldDiscardCallbacks(for sessionTask: URLSessionTask) -> Bool { true }

        func didFinishDiscardedTransfer(_ sessionTask: URLSessionTask) {
            didCleanUpDiscardedTransfer = true
        }

        func didBecomeInvalidation(withError error: Error?) {}
        func didFinishEvents(forBackgroundURLSession session: URLSession) {}
        func log(_ error: Error, message: String) {}
    }

    private final class MappedStateProvider: SessionStateProvider {
        let mappedTask: DownloadTask
        let mappedSessionTask: URLSessionTask
        var urlLookupCount = 0

        init(mappedTask: DownloadTask, mappedSessionTask: URLSessionTask) {
            self.mappedTask = mappedTask
            self.mappedSessionTask = mappedSessionTask
        }

        func task<TaskType, R>(for url: URL, as type: R.Type) -> R? where R : Task<TaskType> {
            urlLookupCount += 1
            return nil
        }

        func task<TaskType, R>(for sessionTask: URLSessionTask, as type: R.Type) -> R? where R : Task<TaskType> {
            guard sessionTask === mappedSessionTask else { return nil }
            return mappedTask as? R
        }

        func shouldDiscardCallbacks(for sessionTask: URLSessionTask) -> Bool { false }
        func didFinishDiscardedTransfer(_ sessionTask: URLSessionTask) {}
        func didBecomeInvalidation(withError error: Error?) {}
        func didFinishEvents(forBackgroundURLSession session: URLSession) {}
        func log(_ error: Error, message: String) {}
    }

    private final class NilRequestDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
        private let testResponse = HTTPURLResponse(url: URL(string: "https://example.com/file")!,
                                                   statusCode: 200,
                                                   httpVersion: nil,
                                                   headerFields: nil)

        override var currentRequest: URLRequest? { nil }
        override var response: URLResponse? { testResponse }
    }

    private func makeTask() -> (DownloadTask, Cache, DispatchQueue) {
        let identifier = "TiercelTests.\(UUID().uuidString)"
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent(identifier)
        let cache = Cache(identifier, downloadPath: root)
        let queue = DispatchQueue(label: identifier)
        let task = DownloadTask(URL(string: "https://example.com/file")!,
                                cache: cache,
                                operationQueue: queue)
        return (task, cache, queue)
    }

    private func makeManager() -> SessionManager {
        let identifier = "TiercelTests.\(UUID().uuidString)"
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent(identifier)
        let queue = DispatchQueue(label: identifier)
        return SessionManager(identifier,
                              configuration: SessionConfiguration(),
                              cache: Cache(identifier, downloadPath: root),
                              operationQueue: queue)
    }

    /// 通过持久化 plist 预置一个任务进 manager，避免测试发起真实网络请求
    private func makeManagerWithPersistedTask(status: Status) throws -> (SessionManager, DownloadTask) {
        let identifier = "TiercelTests.\(UUID().uuidString)"
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent(identifier)
        let cache = Cache(identifier, downloadPath: root)
        let url = URL(string: "https://example.com/persisted")!
        let persisted = DownloadTask(url, cache: cache, operationQueue: DispatchQueue(label: "\(identifier).seed"))
        persisted.mutableState.write { $0.status = status }
        let data = try PropertyListEncoder().encode([persisted])
        let path = (cache.downloadPath as NSString).appendingPathComponent("\(cache.identifier)_Tasks.plist")
        try data.write(to: URL(fileURLWithPath: path))

        let queue = DispatchQueue(label: identifier)
        let manager = SessionManager(identifier,
                                     configuration: SessionConfiguration(),
                                     cache: cache,
                                     operationQueue: queue)
        let restored = try XCTUnwrap(manager.fetchTask(url))
        return (manager, restored)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testCancelWaitingTaskCompletesLogicallyWithoutWillState() throws {
        let (task, _, queue) = makeTask()
        let delegate = TaskDelegateSpy()
        task.delegate = delegate
        var didCallHandler = false

        queue.sync {
            task.cancel(onMainQueue: false) { _ in didCallHandler = true }
        }

        XCTAssertEqual(task.status, .canceled)
        XCTAssertEqual(delegate.statuses, [.canceled])
        XCTAssertTrue(delegate.didRemove)
        XCTAssertTrue(didCallHandler)
    }

    func testTaskControlRejectsTaskNotOwnedByManager() throws {
        let (manager, managedTask) = try makeManagerWithPersistedTask(status: .waiting)
        let url = managedTask.url
        let foreignIdentifier = "TiercelTests.\(UUID().uuidString)"
        let foreignRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent(foreignIdentifier)
        let foreignTask = DownloadTask(url,
                                       cache: Cache(foreignIdentifier, downloadPath: foreignRoot),
                                       operationQueue: DispatchQueue(label: foreignIdentifier))
        var handlerCallCount = 0

        manager.suspend(foreignTask, onMainQueue: false) { _ in handlerCallCount += 1 }
        manager.cancel(foreignTask, onMainQueue: false) { _ in handlerCallCount += 1 }
        manager.remove(foreignTask, onMainQueue: false) { _ in handlerCallCount += 1 }
        manager.operationQueue.sync {}

        XCTAssertEqual(handlerCallCount, 0)
        XCTAssertTrue(manager.fetchTask(url) === managedTask)
    }

    func testCancelingLastTaskCompletesManager() throws {
        let (manager, task) = try makeManagerWithPersistedTask(status: .waiting)
        var completionStatuses: [Status] = []
        manager.completion(onMainQueue: false) { completionStatuses.append($0.status) }

        manager.cancel(task, onMainQueue: false)
        manager.operationQueue.sync {}

        XCTAssertEqual(manager.status, .canceled)
        XCTAssertTrue(manager.tasks.isEmpty)
        XCTAssertEqual(completionStatuses, [.canceled])
    }

    func testRemovingLastTaskCompletesManager() throws {
        let (manager, task) = try makeManagerWithPersistedTask(status: .waiting)
        var completionStatuses: [Status] = []
        manager.completion(onMainQueue: false) { completionStatuses.append($0.status) }

        manager.remove(task, onMainQueue: false)
        manager.operationQueue.sync {}

        XCTAssertEqual(manager.status, .removed)
        XCTAssertTrue(manager.tasks.isEmpty)
        XCTAssertEqual(completionStatuses, [.removed])
    }

    func testTotalRemoveCompletesManagerOnlyOnce() throws {
        let (manager, _) = try makeManagerWithPersistedTask(status: .waiting)
        var completionStatuses: [Status] = []
        manager.completion(onMainQueue: false) { completionStatuses.append($0.status) }

        manager.totalRemove()
        manager.operationQueue.sync {}

        XCTAssertEqual(manager.status, .removed)
        XCTAssertTrue(manager.tasks.isEmpty)
        XCTAssertEqual(completionStatuses, [.removed])
    }

    func testPersistedWaitingTaskRestoresAsSuspended() throws {
        let (_, task) = try makeManagerWithPersistedTask(status: .waiting)

        XCTAssertEqual(task.status, .suspended)
    }

    func testRepeatedSuspendKeepsFirstHandlerAndReleasesSlotOnce() {
        let (task, _, queue) = makeTask()
        let delegate = TaskDelegateSpy()
        let sessionTask = URLSession.shared.downloadTask(with: task.url)
        task.delegate = delegate
        var firstHandlerCalled = false
        var secondHandlerCalled = false

        queue.sync {
            task.restoreRunningStatus(with: sessionTask)
            task.suspend(onMainQueue: false) { _ in firstHandlerCalled = true }
            task.suspend(onMainQueue: false) { _ in secondHandlerCalled = true }
            task.didComplete(task: sessionTask, error: URLError(.cancelled))
        }

        XCTAssertTrue(firstHandlerCalled)
        XCTAssertFalse(secondHandlerCalled)
        XCTAssertEqual(delegate.didCompleteFromRunningCount, 1)
        XCTAssertEqual(delegate.didDetermineStatusCount, 2)
    }

    func testLegacyWillRemoveStateDecodesAsRemoved() throws {
        let (task, cache, queue) = makeTask()
        let encodedData = try JSONEncoder().encode(task)
        let encodedString = try XCTUnwrap(String(data: encodedData, encoding: .utf8))
        let data = try XCTUnwrap(encodedString.replacingOccurrences(of: "\"waiting\"", with: "\"willRemove\"")
            .data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.userInfo[.cache] = cache
        decoder.userInfo[.operationQueue] = queue

        let restoredTask = try decoder.decode(DownloadTask.self, from: data)

        XCTAssertEqual(restoredTask.status, .removed)
    }

    func testDecodingTaskWithoutRequiredContextThrows() throws {
        let (task, _, _) = makeTask()
        let data = try JSONEncoder().encode(task)

        XCTAssertThrowsError(try JSONDecoder().decode(DownloadTask.self, from: data))
    }

    func testUnknownPersistedTaskStatusThrows() throws {
        let (task, cache, queue) = makeTask()
        let encodedData = try JSONEncoder().encode(task)
        let encodedString = try XCTUnwrap(String(data: encodedData, encoding: .utf8))
        let data = try XCTUnwrap(encodedString.replacingOccurrences(of: "\"waiting\"",
                                                                    with: "\"futureStatus\"")
            .data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.userInfo[.cache] = cache
        decoder.userInfo[.operationQueue] = queue

        XCTAssertThrowsError(try decoder.decode(DownloadTask.self, from: data))
    }

    func testOrphanRunningTaskRestoresAsSuspended() throws {
        let (task, _, queue) = makeTask()
        let delegate = TaskDelegateSpy()
        task.delegate = delegate
        task.mutableState.write { $0.status = .running }

        queue.sync {
            task.restoreSuspendedStatus()
        }

        XCTAssertEqual(task.status, .suspended)
        XCTAssertEqual(delegate.statuses, [.suspended])
    }

    func testLateSuccessHandlerIsReplayed() {
        let (task, _, _) = makeTask()
        task.mutableState.write { $0.status = .succeeded }
        let expectation = expectation(description: "late success handler")

        task.success(onMainQueue: false) { _ in expectation.fulfill() }

        wait(for: [expectation], timeout: 1)
    }

    func testLateFailureAndCompletionHandlersAreReplayed() {
        let (failureTask, _, _) = makeTask()
        failureTask.mutableState.write { $0.status = .failed }
        let failureExpectation = expectation(description: "late failure handler")
        failureTask.failure(onMainQueue: false) { _ in failureExpectation.fulfill() }

        let (completionTask, _, _) = makeTask()
        completionTask.mutableState.write { $0.status = .suspended }
        let completionExpectation = expectation(description: "late completion handler")
        completionTask.completion(onMainQueue: false) { _ in completionExpectation.fulfill() }

        wait(for: [failureExpectation, completionExpectation], timeout: 1)
    }

    func testInvalidPersistedResumeDataThrows() {
        let data = Data(#"{"data":"AA=="}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(DownloadResumeData.self, from: data))
    }

    func testInvalidPersistedResumeDataDoesNotDiscardCachedTasks() throws {
        let (firstTask, cache, queue) = makeTask()
        let secondTask = DownloadTask(URL(string: "https://example.com/another-file")!,
                                      cache: cache,
                                      operationQueue: queue)
        let encoder = PropertyListEncoder()
        var propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: encoder.encode([firstTask, secondTask]),
                                                    options: .mutableContainersAndLeaves,
                                                    format: nil) as? [[String: Any]]
        )
        propertyList[0]["resumeData"] = ["data": Data([0])]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList,
                                                      format: .binary,
                                                      options: 0)
        let path = (cache.downloadPath as NSString).appendingPathComponent("\(cache.identifier)_Tasks.plist")
        try data.write(to: URL(fileURLWithPath: path))

        let restoredTasks = cache.retrieveAllTasks(with: queue)

        XCTAssertEqual(restoredTasks.count, 2)
        XCTAssertNil(restoredTasks.first?.resumeDataTmpFileName)
    }

    func testDidFinishDownloadingUsesTaskMappingWhenCurrentRequestIsNil() throws {
        let (task, cache, queue) = makeTask()
        let sessionTask = NilRequestDownloadTask()
        let provider = MappedStateProvider(mappedTask: task, mappedSessionTask: sessionTask)
        let delegate = SessionDelegate()
        delegate.stateProvider = provider
        let location = URL(fileURLWithPath: (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(UUID().uuidString))
        try Data("completed".utf8).write(to: location)
        queue.sync {
            task.restoreRunningStatus(with: sessionTask)
        }

        delegate.urlSession(URLSession.shared,
                            downloadTask: sessionTask,
                            didFinishDownloadingTo: location)

        XCTAssertTrue(cache.fileExists(fileName: task.fileName))
        XCTAssertEqual(provider.urlLookupCount, 0)
    }

    func testFinalProgressCallbackObservesSucceededStatus() {
        let (task, _, queue) = makeTask()
        var callbackStatus: Status?
        task.progress(onMainQueue: false) { callbackStatus = $0.status }
        task.mutableState.write { $0.status = .running }
        task.progress.totalUnitCount = 1

        queue.sync {
            task.succeeded(fromRunning: true)
        }

        XCTAssertEqual(callbackStatus, .succeeded)
    }

    func testRemoveFileCompletesBeforeFileExistsCheck() throws {
        let (_, cache, _) = makeTask()
        let path = try XCTUnwrap(cache.filePath(fileName: "completed-file"))
        try Data("completed".utf8).write(to: URL(fileURLWithPath: path))

        cache.removeFile(path)

        XCTAssertFalse(cache.fileExists(fileName: "completed-file"))
    }

    func testUnexpectedCancellationWithoutPendingActionFails() {
        let (task, _, queue) = makeTask()
        let sessionTask = URLSession.shared.downloadTask(with: task.url)

        queue.sync {
            task.restoreRunningStatus(with: sessionTask)
            task.didComplete(task: sessionTask, error: URLError(.cancelled))
        }

        XCTAssertEqual(task.status, .failed)
    }

    func testMismatchedCompletionOnlyCleansUpStaleTransferMapping() {
        let (task, _, queue) = makeTask()
        let delegate = TaskDelegateSpy()
        let activeTransfer = URLSession.shared.downloadTask(with: task.url)
        let staleTransfer = URLSession.shared.downloadTask(with: task.url)
        task.delegate = delegate

        queue.sync {
            task.restoreRunningStatus(with: activeTransfer)
            task.didComplete(task: staleTransfer, error: URLError(.cancelled))
        }

        XCTAssertTrue(task.activeSessionTask === activeTransfer)
        XCTAssertEqual(task.status, .running)
        XCTAssertTrue(delegate.finishedSessionTasks.contains { $0 === staleTransfer })
    }

    func testBackgroundCancellationSuspends() {
        let (task, _, queue) = makeTask()
        let sessionTask = URLSession.shared.downloadTask(with: task.url)
        let error = NSError(domain: NSURLErrorDomain,
                            code: NSURLErrorCancelled,
                            userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: 0])

        queue.sync {
            task.restoreRunningStatus(with: sessionTask)
            task.didComplete(task: sessionTask, error: error)
        }

        XCTAssertEqual(task.status, .suspended)
    }

    func testRecoveryCancellationPreservesResponseAndSuspendedStatus() throws {
        let (task, _, queue) = makeTask()
        let sessionTask = NilRequestDownloadTask()
        task.mutableState.write { $0.status = .suspended }

        queue.sync {
            task.didComplete(task: sessionTask, error: URLError(.cancelled))
        }

        XCTAssertEqual(task.status, .suspended)
        XCTAssertEqual(task.response?.statusCode, 200)
    }

    func testDiscardedSessionTaskCompletionOnlyCleansUpTransfer() throws {
        let provider = DiscardingStateProvider()
        let delegate = SessionDelegate()
        delegate.stateProvider = provider
        let sessionTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/file")!)

        delegate.urlSession(URLSession.shared,
                            task: sessionTask,
                            didCompleteWithError: URLError(.cancelled))

        XCTAssertEqual(provider.lookupCount, 0)
        XCTAssertTrue(provider.didCleanUpDiscardedTransfer)
    }

    func testReconcilePrefersRunningTransferBeforeProgress() {
        XCTAssertTrue(SessionManager.shouldPreferTransfer(state: .running,
                                                          bytesReceived: 1,
                                                          taskIdentifier: 1,
                                                          overState: .suspended,
                                                          bytesReceived: 100,
                                                          taskIdentifier: 2))
    }

    func testReconcilePrefersProgressThenNewestTransfer() {
        XCTAssertTrue(SessionManager.shouldPreferTransfer(state: .running,
                                                          bytesReceived: 100,
                                                          taskIdentifier: 1,
                                                          overState: .running,
                                                          bytesReceived: 50,
                                                          taskIdentifier: 2))
        XCTAssertTrue(SessionManager.shouldPreferTransfer(state: .running,
                                                          bytesReceived: 100,
                                                          taskIdentifier: 2,
                                                          overState: .running,
                                                          bytesReceived: 100,
                                                          taskIdentifier: 1))
    }

    func testIdempotentRestartOfSucceededTaskDoesNotReplayCompletion() {
        let (task, _, queue) = makeTask()
        let delegate = TaskDelegateSpy()
        task.delegate = delegate

        var successCount = 0
        var completionCount = 0
        var progressCount = 0
        task.success(onMainQueue: false) { _ in successCount += 1 }
        task.completion(onMainQueue: false) { _ in completionCount += 1 }
        task.progress(onMainQueue: false) { _ in progressCount += 1 }

        task.mutableState.write { $0.status = .succeeded }

        queue.sync {
            task.start(using: URLSession.shared, immediately: true)
        }

        XCTAssertEqual(successCount, 0)
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(progressCount, 1)
        XCTAssertEqual(delegate.statuses, [.succeeded])
        XCTAssertEqual(task.status, .succeeded)
    }

    func testSucceededTasksStayUniqueAcrossRepeatedSuccess() {
        let (task, _, _) = makeTask()
        let manager = makeManager()
        task.mutableState.write { $0.status = .succeeded }

        // determineStatus 带 operationQueue 归属断言，必须入队调用
        manager.operationQueue.sync {
            manager.task(task, didSucceed: false)
            manager.task(task, didSucceed: false)
        }

        XCTAssertEqual(manager.succeededTasks.count, 1)
    }

    func testTmpFileNameExtractionSupportsLegacyV1ResumeData() throws {
        let v1Dictionary: [String: Any] = [
            "NSURLSessionResumeInfoVersion": 1,
            "NSURLSessionResumeInfoLocalPath": "/var/mobile/tmp/CFNetworkDownload_abc123.tmp"
        ]
        let v1Data = try PropertyListSerialization.data(fromPropertyList: v1Dictionary,
                                                        format: .xml,
                                                        options: 0)
        let v1ResumeData = try XCTUnwrap(DownloadResumeData(data: v1Data))
        XCTAssertEqual(v1ResumeData.tmpFileName, "CFNetworkDownload_abc123.tmp")

        let v2Dictionary: [String: Any] = [
            "NSURLSessionResumeInfoVersion": 2,
            "NSURLSessionResumeInfoTempFileName": "CFNiOSDownload_def456.tmp"
        ]
        let v2Data = try PropertyListSerialization.data(fromPropertyList: v2Dictionary,
                                                        format: .xml,
                                                        options: 0)
        let v2ResumeData = try XCTUnwrap(DownloadResumeData(data: v2Data))
        XCTAssertEqual(v2ResumeData.tmpFileName, "CFNiOSDownload_def456.tmp")
    }

    func testCorruptedEntryDoesNotDiscardOtherPersistedTasks() throws {
        let (firstTask, cache, queue) = makeTask()
        let secondTask = DownloadTask(URL(string: "https://example.com/another-file")!,
                                      cache: cache,
                                      operationQueue: queue)
        let encoder = PropertyListEncoder()
        var propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: encoder.encode([firstTask, secondTask]),
                                                    options: .mutableContainersAndLeaves,
                                                    format: nil) as? [[String: Any]]
        )
        // 父类 Task 的字段经 superEncoder 存放在顶层 "super" 子字典中
        var superFields = try XCTUnwrap(propertyList[0]["super"] as? [String: Any])
        superFields["status"] = "futureStatus"
        propertyList[0]["super"] = superFields
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList,
                                                      format: .binary,
                                                      options: 0)
        let path = (cache.downloadPath as NSString).appendingPathComponent("\(cache.identifier)_Tasks.plist")
        try data.write(to: URL(fileURLWithPath: path))

        let restoredTasks = cache.retrieveAllTasks(with: queue)

        XCTAssertEqual(restoredTasks.count, 1)
        XCTAssertEqual(restoredTasks.first?.url.absoluteString, secondTask.url.absoluteString)
    }

}
