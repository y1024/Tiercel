//
//  Task.swift
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

public protocol TaskDelegate: AnyObject {
        
    func task<TaskType>(_ task: Task<TaskType>, didChangeStatusTo newValue: Status)
    
    func taskDidStart<TaskType>(_ task: Task<TaskType>)

    func taskDidCancelOrRemove<TaskType>(_ task: Task<TaskType>)
    
    func task<TaskType>(_ task: Task<TaskType>, didSucceed fromRunning: Bool)
    
    func task<TaskType>(_ task: Task<TaskType>, didDetermineStatus fromRunning: Bool)
    
    func taskDidUpdateCurrentURL<TaskType>(_ task: Task<TaskType>)
    
    func taskDidUpdateProgress<TaskType>(_ task: Task<TaskType>)
    
    func taskDidCompleteFromRunning<TaskType>(_ task: Task<TaskType>)

}

protocol UnderlyingTaskDelegate: AnyObject {
    func taskDidFinishUnderlyingTask<TaskType>(_ task: Task<TaskType>, sessionTask: URLSessionTask)
}


extension Task {
    public enum Validation: Int {
        case unkown
        case correct
        case incorrect
    }
}

public class Task<TaskType>: NSObject, Codable {
    
    private enum CodingKeys: CodingKey {
        case url
        case currentURL
        case fileName
        case headers
        case startDate
        case endDate
        case totalBytes
        case completedBytes
        case verificationCode
        case status
        case verificationType
        case validation
        case error
    }
    
    weak var delegate: TaskDelegate?

    let cache: Cache

    let operationQueue: DispatchQueue

    public let url: URL
    
    public let progress: Progress = Progress()

    struct MutableState {
        var headers: [String: String]?
        var verificationCode: String?
        var verificationType: FileChecksumHelper.VerificationType = .md5
        var status: Status = .waiting
        var validation: Validation = .unkown
        var currentURL: URL
        var startDate: Double = 0
        var endDate: Double = 0
        var speed: Int64 = 0
        var fileName: String
        var timeRemaining: Int64 = 0
        var error: Error?

        var progressExecuter: Executer<TaskType>?
        var successExecuter: Executer<TaskType>?
        var failureExecuter: Executer<TaskType>?
        var controlExecuter: Executer<TaskType>?
        var completionExecuter: Executer<TaskType>?
        var validateExecuter: Executer<TaskType>?
    }
    
    let mutableState: Protected<MutableState>

    public var status: Status {
        mutableState.read { $0.status }
    }
    
    var currentURL: URL {
        mutableState.read { $0.currentURL }
    }
    
    public var validation: Validation {
        mutableState.read { $0.validation }
    }
    
    public var startDate: Double {
        mutableState.read { $0.startDate }
    }
    
    public var startDateString: String {
        startDate.tr.convertTimeToDateString()
    }

    public var endDate: Double {
        mutableState.read { $0.endDate }
    }
    
    public var endDateString: String {
        endDate.tr.convertTimeToDateString()
    }


    public var speed: Int64 {
        mutableState.read { $0.speed }
    }
    
    public var speedString: String {
        speed.tr.convertSpeedToString()
    }

    /// 默认为url的md5加上文件扩展名
    public var fileName: String {
        mutableState.read { $0.fileName }
    }

    public  var timeRemaining: Int64 {
        mutableState.read { $0.timeRemaining }
    }
    
    public var timeRemainingString: String {
        timeRemaining.tr.convertTimeToString()
    }

    public var error: Error? {
        mutableState.read { $0.error }
    }

    init(_ url: URL,
                  headers: [String: String]? = nil,
                  cache: Cache,
                  operationQueue:DispatchQueue) {
        self.cache = cache
        self.url = url
        self.operationQueue = operationQueue
        mutableState = Protected(MutableState(headers: headers, currentURL: url, fileName: url.tr.fileName))
        super.init()
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(progress.totalUnitCount, forKey: .totalBytes)
        try container.encode(progress.completedUnitCount, forKey: .completedBytes)
        let state = mutableState.read { $0 }
        try container.encode(state.currentURL, forKey: .currentURL)
        try container.encode(state.fileName, forKey: .fileName)
        try container.encodeIfPresent(state.headers, forKey: .headers)
        try container.encode(state.startDate, forKey: .startDate)
        try container.encode(state.endDate, forKey: .endDate)
        try container.encode(state.status.rawValue, forKey: .status)
        try container.encodeIfPresent(state.verificationCode, forKey: .verificationCode)
        try container.encode(state.verificationType.rawValue, forKey: .verificationType)
        try container.encode(state.validation.rawValue, forKey: .validation)
        if let error = state.error {
            let errorData = try NSKeyedArchiver.archivedData(withRootObject: error as NSError,
                                                             requiringSecureCoding: true)
            try container.encode(errorData, forKey: .error)
        }

    }
    
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        let currentURL = try container.decode(URL.self, forKey: .currentURL)
        let fileName = try container.decode(String.self, forKey: .fileName)
        mutableState = Protected(MutableState(currentURL: currentURL, fileName: fileName))
        guard let cache = decoder.userInfo[.cache] as? Cache else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Missing Cache in decoder.userInfo"))
        }
        guard let operationQueue = decoder.userInfo[.operationQueue] as? DispatchQueue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Missing operationQueue in decoder.userInfo"))
        }
        self.cache = cache
        self.operationQueue = operationQueue
        super.init()

        progress.totalUnitCount = try container.decode(Int64.self, forKey: .totalBytes)
        progress.completedUnitCount = try container.decode(Int64.self, forKey: .completedBytes)
        
        try mutableState.write {
            $0.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
            $0.startDate = try container.decode(Double.self, forKey: .startDate)
            $0.endDate = try container.decode(Double.self, forKey: .endDate)
            $0.verificationCode = try container.decodeIfPresent(String.self, forKey: .verificationCode)
            let statusString = try container.decode(String.self, forKey: .status)
            guard let status = Status(rawValue: statusString) else {
                throw DecodingError.dataCorruptedError(forKey: .status,
                                                       in: container,
                                                       debugDescription: "Unknown task status: \(statusString)")
            }
            switch status {
            case .waiting, .willSuspend:
                $0.status = .suspended
            case .willCancel:
                $0.status = .canceled
            case .willRemove:
                $0.status = .removed
            default:
                $0.status = status
            }
            let verificationTypeInt = try container.decode(Int.self, forKey: .verificationType)
            guard let verificationType = FileChecksumHelper.VerificationType(rawValue: verificationTypeInt) else {
                throw DecodingError.dataCorruptedError(forKey: .verificationType,
                                                       in: container,
                                                       debugDescription: "Unknown verification type: \(verificationTypeInt)")
            }
            $0.verificationType = verificationType
            let validationType = try container.decode(Int.self, forKey: .validation)
            guard let validation = Validation(rawValue: validationType) else {
                throw DecodingError.dataCorruptedError(forKey: .validation,
                                                       in: container,
                                                       debugDescription: "Unknown validation state: \(validationType)")
            }
            $0.validation = validation
            if let errorData = try container.decodeIfPresent(Data.self, forKey: .error) {
                $0.error = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self,
                                                                   from: errorData)
            }
        }
    }

    func execute(_ Executer: Executer<TaskType>?) {
        fatalError("Subclasses must override.")
    }

}


extension Task {
    @discardableResult
    public func progress(onMainQueue: Bool = true, handler: @escaping Handler<TaskType>) -> Self {
        mutableState.write {
            $0.progressExecuter = Executer(onMainQueue: onMainQueue, handler: handler)
        }
        return self
    }

    @discardableResult
    public func success(onMainQueue: Bool = true, handler: @escaping Handler<TaskType>) -> Self {
        let executer = Executer(onMainQueue: onMainQueue, handler: handler)
        let shouldReplay = mutableState.write {
            $0.successExecuter = executer
            return $0.status == .succeeded && $0.completionExecuter == nil
        }
        if shouldReplay {
            operationQueue.async {
                self.execute(executer)
            }
        }
        return self

    }

    @discardableResult
    public func failure(onMainQueue: Bool = true, handler: @escaping Handler<TaskType>) -> Self {
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
                self.execute(executer)
            }
        }
        return self
    }
    
    @discardableResult
    public func completion(onMainQueue: Bool = true, handler: @escaping Handler<TaskType>) -> Self {
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
                self.execute(executer)
            }
        }
        return self
    }
    
}
