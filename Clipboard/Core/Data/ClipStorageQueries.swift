//
//  ClipStorageQueries.swift
//  Clipboard
//
//  热库（Clip.sqlite3）与冷归档库（ClipArchive.sqlite3）共用的存储统计与淘汰 SQL 构造器，
//  避免双库维护多份手写 SQL 片段产生口径漂移。
//

import Foundation

nonisolated enum ClipStorageQueries {
    static let byteSizeExpr = "(CASE WHEN media_size > 0 THEN media_size ELSE LENGTH(data) END)"
    static let timestampSecondsExpr = "(CASE WHEN timestamp > 10000000000 THEN timestamp / 1000 ELSE timestamp END)"

    static let typeProportionsSQL = """
        SELECT type, COUNT(*) AS count, COALESCE(SUM(\(byteSizeExpr)), 0) AS total_bytes
        FROM Clip
        GROUP BY type
    """

    static func topStorageItemsWhereClause(for filter: StoragePresetFilter, nowSec: Int64) -> String {
        let thirtyDaysAgoSec = nowSec - (30 * 24 * 60 * 60)
        let ninetyDaysAgoSec = nowSec - (90 * 24 * 60 * 60)
        let sixMonthsAgoSec = nowSec - (180 * 24 * 60 * 60)

        var whereClause = "WHERE 1=1"
        switch filter {
        case .all:
            break
        case .oneMonthUnstarredImages:
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND (\(timestampSecondsExpr) < \(thirtyDaysAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .threeMonthsUnstarredImages:
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND (\(timestampSecondsExpr) < \(ninetyDaysAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .sixMonthsUnstarredImages:
            whereClause += """
             AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') \
            AND (\(timestampSecondsExpr) < \(sixMonthsAgoSec)) \
            AND (`group` IS NULL OR `group` = -1)
            """
        case .largeImages:
            whereClause += " AND (tag = 'image' OR type LIKE '%png%' OR type LIKE '%tiff%' OR type LIKE '%jpeg%' OR type LIKE '%image%') AND \(byteSizeExpr) > 5000000"
        case .largeRichText:
            whereClause += " AND (tag = 'rich' OR type LIKE '%rtf%' OR type LIKE '%html%') AND LENGTH(data) > 1000000"
        }
        return whereClause
    }

    static func topStorageItemsSQL(whereClause: String, limit: Int) -> String {
        """
        SELECT id, unique_id, type, timestamp, app_id, tag, `group`, \(byteSizeExpr) AS byte_size, SUBSTR(search_text, 1, 100)
        FROM Clip
        \(whereClause)
        ORDER BY byte_size DESC
        LIMIT \(limit)
        """
    }

    static func evictionWhereClause(cutoffSec: Int64) -> String {
        """
        WHERE (`group` IS NULL OR `group` = -1)
          AND (tag = 'image' OR lower(type) IN ('public.png', 'public.tiff', 'image/png', 'image/jpeg', 'image/tiff'))
          AND (\(timestampSecondsExpr) < \(cutoffSec))
        """
    }

    static func evictionCandidatesCountSQL(cutoffSec: Int64) -> String {
        """
        SELECT COUNT(*), COALESCE(SUM(\(byteSizeExpr)), 0)
        FROM Clip
        \(evictionWhereClause(cutoffSec: cutoffSec))
        """
    }

    static func evictionItemsSQL(selectIdColumn: String, cutoffSec: Int64) -> String {
        """
        SELECT \(selectIdColumn),
               \(byteSizeExpr),
               \(timestampSecondsExpr) AS ts_sec
        FROM Clip
        \(evictionWhereClause(cutoffSec: cutoffSec))
        ORDER BY ts_sec ASC
        """
    }
}
