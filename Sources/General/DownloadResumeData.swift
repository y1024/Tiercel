//
//  DownloadResumeData.swift
//  Tiercel
//
//  Created by Daniels on 2021/10/23.
//  Copyright © 2021 Daniels. All rights reserved.
//

import Foundation

final class DownloadResumeData: Codable {
    
    private enum CodingKeys: CodingKey {
        case data
    }
    
    private enum Keys {
        static let infoVersionKey = "NSURLSessionResumeInfoVersion"
        static let infoTempFileNameKey = "NSURLSessionResumeInfoTempFileName"
        static let infoLocalPathKey = "NSURLSessionResumeInfoLocalPath"
        static let archiveRootObjectKey = "NSKeyedArchiveRootObjectKey"
    }

    let data: Data

    private let dictionary: [String: Any]

    /// v2+ 格式直接携带临时文件名；v1 只有完整的本地路径，取其尾段
    var tmpFileName: String? {
        guard let version = dictionary[Keys.infoVersionKey] as? Int else { return nil }
        if version > 1 {
            return dictionary[Keys.infoTempFileNameKey] as? String
        }
        guard let path = dictionary[Keys.infoLocalPathKey] as? String else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    
    init?(data: Data) {
        guard let dictionary = Self.decode(data) else { return nil }
        guard let correctData = try? PropertyListSerialization.data(fromPropertyList: dictionary,
                                                                    format: PropertyListSerialization.PropertyListFormat.xml,
                                                                    options: PropertyListSerialization.WriteOptions())
        else {
            return nil
        }
        self.dictionary = dictionary
        self.data = correctData
    }
    

    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode(Data.self, forKey: .data)
        guard let dictionary = Self.decode(data) else {
            throw DecodingError.dataCorruptedError(forKey: .data,
                                                   in: container,
                                                   debugDescription: "Invalid URLSession resume data")
        }
        self.data = data
        self.dictionary = dictionary
    }
    
    /// 把 resumeData 解析成字典
    ///
    /// - Parameter data:
    /// - Returns:
    private static func decode(_ data: Data) -> [String: Any]? {
        // In beta versions, resumeData is NSKeyedArchive encoded instead of plist
        var object: NSDictionary?
        if let keyedUnarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            // URLSession resumeData uses a private legacy archive whose nested classes
            // cannot be fully described by the secure-coding allowlist.
            keyedUnarchiver.requiresSecureCoding = false
            do {
                object = try keyedUnarchiver.decodeTopLevelObject(of: NSDictionary.self,
                                                                  forKey: Keys.archiveRootObjectKey)
                if object == nil {
                    object = try keyedUnarchiver.decodeTopLevelObject(of: NSDictionary.self,
                                                                      forKey: NSKeyedArchiveRootObjectKey)
                }
            } catch {
            }
            keyedUnarchiver.finishDecoding()
        }
        
        if object == nil {
            do {
                object = try PropertyListSerialization.propertyList(from: data,
                                                                    options: .mutableContainersAndLeaves,
                                                                    format: nil) as? NSDictionary
            } catch {}
        }
        if let object = object as? [String: Any] {
            return object
        } else {
            return nil
        }
    }
}
