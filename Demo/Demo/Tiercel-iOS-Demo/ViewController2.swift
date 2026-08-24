//
//  ViewController2.swift
//  Example
//
//  Created by Daniels on 2018/3/16.
//  Copyright © 2018 Daniels. All rights reserved.
//

import UIKit
import Tiercel

class ViewController2: BaseViewController {

    override func viewDidLoad() {
        
        sessionManager = appDelegate.sessionManager2

        super.viewDidLoad()


        URLStrings = [
            "https://officecdn-microsoft-com.akamaized.net/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_Office_16.24.19041401_Installer.pkg",
            "http://dldir1.qq.com/qqfile/QQforMac/QQ_V6.5.2.dmg",
            "https://b88962-3067044499.antpcdn.com:19001/b/pkg-ant.baidu.com/issue/netdisk/MACguanjia/8.7.4/BaiduNetdisk_mac_8.7.4_arm64.dmg",
            "http://issuecdn.baidupcs.com/issue/netdisk/MACguanjia/BaiduNetdisk_mac_2.2.3.dmg",
            "https://qd.myapp.com/myapp/qqteam/pcqq/QQ9.0.8_2.exe",
            "https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.1.13.dmg",
            "https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/126b7ce6/QQ_7.0.0_260812_01.dmg",
            "http://pcclient.download.youku.com/ikumac/youkumac_1.6.7.04093.dmg?spm=a2hpd.20022519.m_235549.5!2~5~5~5!2~P!3~A&file=youkumac_1.6.7.04093.dmg",
            "http://dldir1.qq.com/qqfile/QQforMac/QQ_V4.2.4.dmg"
        ]
        

        setupManager()

        updateUI()
        tableView.reloadData()
        
    }
}


// MARK: - tap event
extension ViewController2 {

    @IBAction func addDownloadTask(_ sender: Any) {
        let downloadURLStrings = sessionManager.tasks.map { $0.url.absoluteString }
        guard let URLString = URLStrings.first(where: { !downloadURLStrings.contains($0) }) else { return }
        
        sessionManager.download(URLString) { [weak self] _ in
            guard let self = self else { return }
            let index = self.sessionManager.tasks.count - 1
            self.tableView.insertRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
            self.updateUI()
        }
    }

    @IBAction func deleteDownloadTask(_ sender: UIButton) {
        let count = sessionManager.tasks.count
        guard count > 0 else { return }
        let index = count - 1
        guard let task = sessionManager.tasks.safeObject(at: index) else { return }
        // tableView 刷新、 删除 task 都是异步的，如果操作过快会导致数据不一致，所以需要限制 button 的点击
        sender.isEnabled = false
        sessionManager.remove(task, completely: false) { [weak self] _ in
            self?.tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
            self?.updateUI()
            sender.isEnabled = true
        }
    }
    
    
    @IBAction func sort(_ sender: Any) {
        sessionManager.tasksSort { (task1, task2) -> Bool in
            if task1.startDate < task2.startDate {
                return task1.startDate < task2.startDate
            } else {
                return task2.startDate < task1.startDate
            }
        }
        tableView.reloadData()
    }
}



