nonisolated struct PasteInsertResult: Sendable {
    let id: Int64
    let group: Int?
    let appID: Int64?
    /// 写入后的 sort_order，用于撤销删除时回到原位。
    let sortOrder: Int64

    static let failed = PasteInsertResult(id: -1, group: nil, appID: nil, sortOrder: 0)
}
