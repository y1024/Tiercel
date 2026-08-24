//
//  DownloadTask.swift
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

public protocol DownloadTaskDelegate: TaskDelegate {
    func downloadTaskFileExists(_ task: DownloadTask)
    
    func downloadTaskWillValidateFile(_ task: DownloadTask)
    
    func downloadTask(_ task: DownloadTask, didValidateFile result: Result<Bool, FileChecksumHelper.FileVerificationError>)
    
}

public class DownloadTask: Task<DownloadTask> {

    private enum CallbackSource {
        case activeTransfer
        case recovery
    }

    private enum PendingAction: Equatable {
        case suspend
        case cancel
        case remove

    }
    
    private enum CodingKeys: CodingKey {
        case resumeData
        case response
    }
    
    private var acceptableStatusCodes: Range<Int> { 200..<300 }
    
    
    public var response: HTTPURLResponse? {
        mutableDownloadState.read {
            $0.response ?? $0.underlyingDownloadTask?.response as? HTTPURLResponse
        }
    }
    
    
    public var filePath: String {
        cache.filePath(fileName: fileName)!
    }
    
    public var pathExtension: String? {
        let pathExtension = (filePath as NSString).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension
    }
    
    
    private struct MutableDownloadState {
        var resumeData: DownloadResumeData?
        var response: HTTPURLResponse?
        var shouldValidateFile: Bool = false
        var underlyingDownloadTask: URLSessionDownloadTask?
        var pendingAction: PendingAction?
    }
    
    private var currentRequestObservation: NSKeyValueObservation?
    
    private var underlyingDownloadTask: URLSessionDownloadTask? {
        get {
            mutableDownloadState.read { $0.underlyingDownloadTask }
        }
        set {
            mutableDownloadState.write {
                currentRequestObservation?.invalidate()
                currentRequestObservation = newValue?.observe(\.currentRequest,
                                                               options: .new) { [weak self] task, change in
                    guard let self = self else { return }
                    if let newRequest = change.newValue, let url = newRequest?.url {
                        self.mutableState.write { $0.currentURL = url }
                        self.delegate?.taskDidUpdateCurrentURL(self)
                    }
                }
                $0.underlyingDownloadTask = newValue
            }
        }
    }
    
    private let mutableDownloadState = Protected(MutableDownloadState())

    var isSuspending: Bool {
        mutableDownloadState.read {
            if case .suspend = $0.pendingAction { return true }
            return false
        }
    }

    var activeSessionTask: URLSessionDownloadTask? {
        underlyingDownloadTask
    }

    var resumeDataTmpFileName: String? {
        mutableDownloadState.read { $0.resumeData?.tmpFileName }
    }
    
    
    init(_ url: URL,
         headers: [String: String]? = nil,
         fileName: String? = nil,
         cache: Cache,
         operationQueue: DispatchQueue) {
        super.init(url,
                   headers: headers,
                   cache: cache,
                   operationQueue: operationQueue)
        if let fileName = fileName, !fileName.isEmpty {
            mutableState.write { $0.fileName = fileName }
        }
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fixDelegateMethodError),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }
    
    public override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let superEncoder = container.superEncoder()
        try super.encode(to: superEncoder)
        let downloadState = mutableDownloadState.read { $0 }
        try container.encodeIfPresent(downloadState.resumeData, forKey: .resumeData)
        if let response = downloadState.response ?? downloadState.underlyingDownloadTask?.response as? HTTPURLResponse {
            let responseData = try NSKeyedArchiver.archivedData(
                withRootObject: response,
                requiringSecureCoding: true
            )
            try container.encode(responseData, forKey: .response)
        }
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let superDecoder = try container.superDecoder()
        try super.init(from: superDecoder)
        try mutableDownloadState.write {
            // 兼容旧版
            if let data = try? container.decodeIfPresent(Data.self, forKey: .resumeData) {
                $0.resumeData = DownloadResumeData(data: data)
            } else {
                $0.resumeData = try? container.decodeIfPresent(DownloadResumeData.self, forKey: .resumeData)
            }
            if let responseData = try container.decodeIfPresent(Data.self, forKey: .response) {
                $0.response = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HTTPURLResponse.self,
                                                                      from: responseData)
            }
        }
        
    }
    
    
    deinit {
        currentRequestObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    func restoreRunningStatus(with underlyingDownloadTask: URLSessionDownloadTask) {
        self.underlyingDownloadTask = underlyingDownloadTask
        mutableState.write {
            $0.status = .running
            $0.error = nil
            if let url = underlyingDownloadTask.currentRequest?.url {
                $0.currentURL = url
            }
        }
        delegate?.taskDidUpdateCurrentURL(self)
        delegate?.task(self, didChangeStatusTo: .running)
    }

    func restoreSuspendedStatus() {
        let didRestore = mutableState.write { state -> Bool in
            guard state.status == .running else { return false }
            state.status = .suspended
            return true
        }
        guard didRestore else { return }
        self.underlyingDownloadTask = nil
        delegate?.task(self, didChangeStatusTo: .suspended)
    }
    
    @objc private func fixDelegateMethodError() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let underlyingDownloadTask = self.mutableDownloadState.read { $0.underlyingDownloadTask }
            underlyingDownloadTask?.suspend()
            underlyingDownloadTask?.resume()
        }
    }
    
    
    override func execute(_ executer: Executer<DownloadTask>?) {
        executer?.execute(self)
    }
    
    
}


// MARK: - control
extension DownloadTask {
    
    func start(using session: URLSession, immediately: Bool) {
        guard !isSuspending else { return }
        cache.createDirectory()
        switch mutableState.read({ $0.status }) {
        case .waiting, .suspended, .failed:
            if cache.fileExists(fileName: fileName) {
                prepareForStart(using: session, fileExists: true)
            } else {
                if immediately {
                    prepareForStart(using: session, fileExists: false)
                } else {
                    mutableState.write { $0.status = .waiting }
                    delegate?.task(self, didChangeStatusTo: .waiting)
                    mutableState.read { $0.progressExecuter }?.execute(self)
                    executeControl()
                }
            }
        case .succeeded:
            executeControl()
            // 幂等重启不重放完成回调，与既有发布语义保持一致
            succeeded(fromRunning: false, immediately: false)
        case .running:
            mutableState.write { $0.status = .running }
            delegate?.task(self, didChangeStatusTo: .running)
            executeControl()
        default: break
        }
    }
    
    private func prepareForStart(using session: URLSession, fileExists: Bool) {
        mutableState.write {
            $0.status = .running
            $0.speed = 0
            if $0.startDate == 0 {
                $0.startDate = Date().timeIntervalSince1970
            }
            $0.error = nil
        }
        delegate?.task(self, didChangeStatusTo: .running)
        mutableDownloadState.write { $0.response = nil }
        start(using: session, fileExists: fileExists)
    }
    
    private func start(using session: URLSession, fileExists: Bool) {
        if fileExists {
            (delegate as? DownloadTaskDelegate)?.downloadTaskFileExists(self)
            if let fileInfo = try? FileManager.default.attributesOfItem(atPath: cache.filePath(fileName: fileName)!),
               let length = fileInfo[.size] as? Int64 {
                progress.totalUnitCount = length
            }
            executeControl()
            operationQueue.async {
                self.completeWithLocalFile()
            }
        } else {
            let underlyingDownloadTask: URLSessionDownloadTask
            if let resumeData = mutableDownloadState.read({ $0.resumeData }),
               let tmpFileName = resumeData.tmpFileName,
               cache.retrieveTmpFile(tmpFileName) {
                underlyingDownloadTask = session.downloadTask(withResumeData: resumeData.data)
            } else {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0)
                if let headers = mutableState.read({ $0.headers }) {
                    request.allHTTPHeaderFields = headers
                }
                underlyingDownloadTask = session.downloadTask(with: request)
                progress.completedUnitCount = 0
                progress.totalUnitCount = 0
            }
            self.underlyingDownloadTask = underlyingDownloadTask
            progress.setUserInfoObject(progress.completedUnitCount, forKey: .fileCompletedCountKey)
            delegate?.taskDidStart(self)
            executeControl()
            underlyingDownloadTask.resume()
        }
    }
    
    func suspend(onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard !isSuspending else { return }
        let previousStatus = mutableState.read { $0.status }
        guard previousStatus == .running || previousStatus == .waiting else { return }
        mutableState.write {
            $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        }

        guard previousStatus == .running, let sessionTask = underlyingDownloadTask else {
            mutableState.write { $0.status = .suspended }
            delegate?.task(self, didChangeStatusTo: .suspended)
            mutableState.read { $0.progressExecuter }?.execute(self)
            executeControl()
            executeCompletion(false)
            delegate?.task(self, didDetermineStatus: false)
            return
        }

        mutableDownloadState.write { $0.pendingAction = .suspend }
        delegate?.taskDidCompleteFromRunning(self)
        delegate?.task(self, didDetermineStatus: true)
        // didCompleteWithError is the single source of truth for resumeData.
        sessionTask.cancel(byProducingResumeData: { _ in })
    }
    
    func cancel(onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard mutableState.read({ $0.status }) != .succeeded else { return }
        finishCancelOrRemove(status: .canceled, completely: false, onMainQueue: onMainQueue, handler: handler)
    }
    
    
    
    func remove(completely: Bool = false, onMainQueue: Bool = true, handler: Handler<DownloadTask>? = nil) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        finishCancelOrRemove(status: .removed, completely: completely, onMainQueue: onMainQueue, handler: handler)
    }
    
    
    func update(_ newHeaders: [String: String]? = nil, newFileName: String? = nil) {
        let oldFileName = mutableState.write { state -> String? in
            state.headers = newHeaders
            if let newFileName = newFileName,
                !newFileName.isEmpty,
                state.fileName != newFileName {
                let oldFileName = state.fileName
                state.fileName = newFileName
                return oldFileName
            }
            return nil
        }
        if let oldFileName = oldFileName, let newFileName = newFileName {
            cache.updateFileName(oldFileName, to: newFileName)
        }
    }
    
    private func validateFile() {
        guard let validateHandler = mutableState.read({ $0.validateExecuter }) else { return }
        
        guard mutableDownloadState.read({ $0.shouldValidateFile }) else {
            validateHandler.execute(self)
            return
        }
        
        let (verificationCode, verificationType) = mutableState.read {
            ($0.verificationCode, $0.verificationType)
        }
        guard let verificationCode = verificationCode else { return }
        
        FileChecksumHelper.validateFile(filePath, code: verificationCode, type: verificationType) { [weak self] (result) in
            guard let self = self else { return }
            self.mutableDownloadState.write { $0.shouldValidateFile = false }
            switch result {
            case .success:
                self.mutableState.write { $0.validation = .correct }
            case .failure:
                self.mutableState.write { $0.validation = .incorrect }
            }
            (self.delegate as? DownloadTaskDelegate)?.downloadTask(self, didValidateFile: result)
            validateHandler.execute(self)
        }
    }
    
}



// MARK: - status handle
extension DownloadTask {

    private func finishSuspending(resumeData data: Data?) {
        dispatchPrecondition(condition: .onQueue(operationQueue))
        guard mutableDownloadState.read({ $0.pendingAction }) == .suspend else { return }

        let resumeData = data.flatMap(DownloadResumeData.init(data:))
        if cache.fileExists(fileName: fileName) {
            // Cancellation can race with a completed download. Preserve the
            // requested suspended status, but the destination file wins over
            // any recovery data produced for the finished transfer.
            clearResumeData()
            if let tmpFileName = resumeData?.tmpFileName {
                cache.removeTmpFile(tmpFileName)
            }
        } else if let resumeData = resumeData {
            replaceResumeData(with: resumeData)
        } else {
            // A nil or malformed value means this cancellation cannot resume;
            // stale data from an earlier transfer must not be reused.
            clearResumeData()
        }

        mutableDownloadState.write { $0.pendingAction = nil }
        let progressExecuter = mutableState.write { state -> Executer<DownloadTask>? in
            state.status = .suspended
            return state.progressExecuter
        }
        delegate?.task(self, didChangeStatusTo: .suspended)
        progressExecuter?.execute(self)
        executeControl()
        executeCompletion(false)
        delegate?.task(self, didDetermineStatus: false)
    }

    private func replaceResumeData(with resumeData: DownloadResumeData) {
        let newTmpFileName = resumeData.tmpFileName
        let oldTmpFileName = mutableDownloadState.write { state -> String? in
            let oldTmpFileName = state.resumeData?.tmpFileName
            state.resumeData = resumeData
            return oldTmpFileName
        }
        if let oldTmpFileName = oldTmpFileName,
           oldTmpFileName != newTmpFileName {
            cache.removeTmpFile(oldTmpFileName)
        }
        if let newTmpFileName = newTmpFileName {
            cache.storeTmpFile(newTmpFileName)
        }
    }

    private func clearResumeData() {
        let tmpFileName = mutableDownloadState.write { state -> String? in
            let tmpFileName = state.resumeData?.tmpFileName
            state.resumeData = nil
            return tmpFileName
        }
        if let tmpFileName = tmpFileName {
            cache.removeTmpFile(tmpFileName)
        }
    }
    
    private func finishCancelOrRemove(status: Status,
                                      completely: Bool,
                                      onMainQueue: Bool,
                                      handler: Handler<DownloadTask>?) {
        let sessionTask = underlyingDownloadTask
        let wasRunning = mutableState.read { $0.status == .running }
        mutableDownloadState.write { $0.pendingAction = status == .canceled ? .cancel : .remove }
        mutableState.write {
            $0.controlExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
            $0.status = status
        }
        delegate?.task(self, didChangeStatusTo: status)
        cache.remove(self, completely: completely)
        if wasRunning {
            delegate?.taskDidCompleteFromRunning(self)
        }
        delegate?.taskDidCancelOrRemove(self)
        executeControl()
        executeCompletion(false)
        delegate?.task(self, didDetermineStatus: wasRunning)

        if let sessionTask = sessionTask {
            sessionTask.cancel()
        } else {
            mutableDownloadState.write { $0.pendingAction = nil }
        }
    }

    /// - Parameter immediately: false 表示对已成功任务的幂等重启，跳过 success/completion 回调与完成通知
    func succeeded(fromRunning: Bool, immediately: Bool = true) {
        mutableState.write {
            if $0.endDate == 0 {
                $0.endDate = Date().timeIntervalSince1970
                $0.timeRemaining = 0
            }
            $0.status = .succeeded
        }
        delegate?.task(self, didChangeStatusTo: .succeeded)
        progress.completedUnitCount = progress.totalUnitCount
        mutableState.read { $0.progressExecuter }?.execute(self)
        if immediately {
            executeCompletion(true)
        }
        validateFile()
        delegate?.task(self, didSucceed: fromRunning)
    }
    
    
    private func determineStatus(with error: Error, isRecoveryCallback: Bool) {
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            if let resumeData = DownloadResumeData(data: data) {
                replaceResumeData(with: resumeData)
            } else {
                clearResumeData()
            }
        }
        let backgroundCancellationReason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
        let isCancellation = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let shouldSuspend = backgroundCancellationReason != nil || (isRecoveryCallback && isCancellation)
        let newStatus: Status = shouldSuspend ? .suspended : .failed
        mutableState.write {
            $0.error = error
            $0.status = newStatus
        }
        delegate?.task(self, didChangeStatusTo: newStatus)
        finishDeterminingStatus()
    }

    private func determineStatus(withStatusCode statusCode: Int) {
        mutableState.write {
            $0.error = TiercelError.unacceptableStatusCode(code: statusCode)
            $0.status = .failed
        }
        delegate?.task(self, didChangeStatusTo: .failed)
        finishDeterminingStatus()
    }

    private func finishDeterminingStatus() {
        mutableState.read { $0.progressExecuter }?.execute(self)
        executeCompletion(false)
        delegate?.task(self, didDetermineStatus: true)
    }
}

// MARK: - closure
extension DownloadTask {
    @discardableResult
    public func validateFile(code: String,
                             type: FileChecksumHelper.VerificationType,
                             onMainQueue: Bool = true,
                             handler: @escaping Handler<DownloadTask>) -> Self {
        operationQueue.async {
            let (verificationCode, verificationType) = self.mutableState.read {
                ($0.verificationCode, $0.verificationType)
            }
            if verificationCode == code &&
                verificationType == type &&
                self.validation != .unkown {
                self.mutableDownloadState.write { $0.shouldValidateFile = false }
            } else {
                self.mutableDownloadState.write { $0.shouldValidateFile = true }
                self.mutableState.write {
                    $0.verificationCode = code
                    $0.verificationType = type
                }
                (self.delegate as? DownloadTaskDelegate)?.downloadTaskWillValidateFile(self)
            }
            let shouldValidate = self.mutableState.write { state -> Bool in
                state.validateExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
                return state.status == .succeeded
            }
            if shouldValidate {
                self.validateFile()
            }
        }
        return self
    }
    
    private func executeCompletion(_ isSucceeded: Bool) {
        let (completionExecuter, successExecuter, failureExecuter) = mutableState.read {
            ($0.completionExecuter, $0.successExecuter, $0.failureExecuter)
        }
        if let completionExecuter = completionExecuter {
            completionExecuter.execute(self)
        } else if isSucceeded {
            successExecuter?.execute(self)
        } else {
            failureExecuter?.execute(self)
        }
        NotificationCenter.default.postNotification(name: DownloadTask.didCompleteNotification, downloadTask: self)
    }
    
    private func executeControl() {
        let controlExecuter = mutableState.write { state -> Executer<DownloadTask>? in
            let controlExecuter = state.controlExecuter
            state.controlExecuter = nil
            return controlExecuter
        }
        controlExecuter?.execute(self)
    }
}



// MARK: - info
extension DownloadTask {
    
    func updateSpeedAndTimeRemaining() {
        
        let dataCount = progress.completedUnitCount
        let lastData: Int64 = progress.userInfo[.fileCompletedCountKey] as? Int64 ?? 0
        
        if dataCount > lastData {
            // 计算频率为每秒
            let speed = dataCount - lastData
            updateTimeRemaining(speed)
        }
        progress.setUserInfoObject(dataCount, forKey: .fileCompletedCountKey)
        
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
}

// MARK: - callback
extension DownloadTask {
    private func callbackSource(for task: URLSessionDownloadTask) -> CallbackSource? {
        if let underlyingDownloadTask = underlyingDownloadTask {
            return underlyingDownloadTask === task ? .activeTransfer : nil
        }
        switch status {
        case .running, .suspended:
            return .recovery
        default:
            return nil
        }
    }

    func didWriteData(downloadTask: URLSessionDownloadTask, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let source = callbackSource(for: downloadTask),
              status == .running || (source == .recovery && status == .suspended)
        else { return }
        progress.completedUnitCount = totalBytesWritten
        progress.totalUnitCount = totalBytesExpectedToWrite
        mutableState.read { $0.progressExecuter }?.execute(self)
        delegate?.taskDidUpdateProgress(self)
        NotificationCenter.default.postNotification(name: DownloadTask.runningNotification, downloadTask: self)
    }
    
    
    func didFinishDownloading(task: URLSessionDownloadTask, to location: URL) {
        guard let source = callbackSource(for: task),
              status == .running || (source == .recovery && status == .suspended),
              let statusCode = (task.response as? HTTPURLResponse)?.statusCode,
              acceptableStatusCodes.contains(statusCode)
        else { return }
        cache.storeFile(at: location, to: URL(fileURLWithPath: filePath))
        if cache.fileExists(fileName: fileName) {
            clearResumeData()
        }
        
    }
    
    private func completeWithLocalFile() {
        guard mutableState.read({ $0.status }) == .running else { return }
        clearResumeData()
        succeeded(fromRunning: false)
    }

    func didComplete(task: URLSessionDownloadTask, error: Error?) {
        guard let source = callbackSource(for: task) else {
            // A stale transfer may still have an instance mapping even after another transfer became active.
            // Removing by ObjectIdentifier cannot affect the current active transfer's mapping.
            (delegate as? UnderlyingTaskDelegate)?.taskDidFinishUnderlyingTask(self, sessionTask: task)
            return
        }

        let response = task.response as? HTTPURLResponse
        mutableDownloadState.write { $0.response = response }
        
        let pendingAction = mutableDownloadState.read { $0.pendingAction }
        self.underlyingDownloadTask = nil
        (delegate as? UnderlyingTaskDelegate)?.taskDidFinishUnderlyingTask(self, sessionTask: task)
            
        if let pendingAction = pendingAction {
            switch pendingAction {
            case .suspend:
                let data = error.flatMap {
                    ($0 as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                }
                finishSuspending(resumeData: data)
            case .cancel, .remove:
                mutableDownloadState.write {
                    if $0.pendingAction == pendingAction {
                        $0.pendingAction = nil
                    }
                }
            }
            return
        }
            
        delegate?.taskDidCompleteFromRunning(self)

        if response != nil {
            progress.totalUnitCount = task.countOfBytesExpectedToReceive
            progress.completedUnitCount = task.countOfBytesReceived
            progress.setUserInfoObject(task.countOfBytesReceived, forKey: .fileCompletedCountKey)
        }
            
        if let error = error {
            determineStatus(with: error, isRecoveryCallback: source == .recovery)
        } else {
            let statusCode = response?.statusCode ?? -1
            let isAcceptable = acceptableStatusCodes.contains(statusCode)
            if isAcceptable {
                clearResumeData()
                succeeded(fromRunning: true)
            } else {
                determineStatus(withStatusCode: statusCode)
            }
        }
    }
    
}



extension Array where Element == DownloadTask {
    @discardableResult
    public func progress(onMainQueue: Bool = true, handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.progress(onMainQueue: onMainQueue, handler: handler) }
        return self
    }
    
    @discardableResult
    public func success(onMainQueue: Bool = true, handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.success(onMainQueue: onMainQueue, handler: handler) }
        return self
    }
    
    @discardableResult
    public func failure(onMainQueue: Bool = true, handler: @escaping Handler<DownloadTask>) -> [Element] {
        self.forEach { $0.failure(onMainQueue: onMainQueue, handler: handler) }
        return self
    }
    
    public func validateFile(codes: [String],
                             type: FileChecksumHelper.VerificationType,
                             onMainQueue: Bool = true,
                             handler: @escaping Handler<DownloadTask>) -> [Element] {
        for (index, task) in self.enumerated() {
            guard let code = codes.safeObject(at: index) else { continue }
            task.validateFile(code: code, type: type, onMainQueue: onMainQueue, handler: handler)
        }
        return self
    }
}
