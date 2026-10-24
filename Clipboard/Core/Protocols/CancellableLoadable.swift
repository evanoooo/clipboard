//
//  CancellableLoadable.swift
//  Clipboard
//
//  Created on 2026/10/24.
//

import Foundation

/// 统一视图可取消后台异步加载任务的协议
@MainActor
protocol CancellableLoadable: AnyObject {
    func cancelLoad()
}
