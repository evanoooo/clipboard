nonisolated struct PasteInsertResult: Sendable {
    let id: Int64
    let group: Int?
    let appID: Int64?
    /// 写入后的 sort_order，用于撤销删除时回到原位。
    let sortOrder: Int64
    /// 是否真正增加了可见历史条数（新建非隐藏条目，或将已软删除条目恢复为可见）。
    let didIncreaseTotalCount: Bool

    static let failed = PasteInsertResult(
        id: -1,
        group: nil,
        appID: nil,
        sortOrder: 0,
        didIncreaseTotalCount: false
    )
}
