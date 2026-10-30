//
//  PasteFTSMigration.swift
//  Clipboard
//
//  FTS5 virtual table migration and sync triggers.
//

import Foundation
import SQLite

enum PasteFTSMigration {
    nonisolated static let ftsTableName = "clip_fts"

    nonisolated static func setup(on database: Connection) throws {
        let tableExists = try isFTSTableCreated(on: database)

        if !tableExists {
            // Create FTS5 external content virtual table.
            // Using trigram tokenizer with case_sensitive 0 for substring matching.
            try database.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
                    search_text,
                    alias_search,
                    content='Clip',
                    content_rowid='id',
                    tokenize='trigram case_sensitive 0'
                );
            """)
        }

        // Create or replace synchronizing triggers
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS clip_ai AFTER INSERT ON Clip BEGIN
                INSERT INTO clip_fts(rowid, search_text, alias_search)
                VALUES (new.id, new.search_text, new.alias_search);
            END;

            CREATE TRIGGER IF NOT EXISTS clip_ad AFTER DELETE ON Clip BEGIN
                INSERT INTO clip_fts(clip_fts, rowid, search_text, alias_search)
                VALUES('delete', old.id, old.search_text, old.alias_search);
            END;

            DROP TRIGGER IF EXISTS clip_au;
            CREATE TRIGGER clip_au AFTER UPDATE OF search_text, alias_search ON Clip BEGIN
                INSERT INTO clip_fts(clip_fts, rowid, search_text, alias_search)
                VALUES('delete', old.id, old.search_text, old.alias_search);
                INSERT INTO clip_fts(rowid, search_text, alias_search)
                VALUES (new.id, new.search_text, new.alias_search);
            END;
        """)

        if !tableExists {
            try rebuildIndex(on: database)
        }
    }

    nonisolated static func isFTSTableCreated(on database: Connection) throws -> Bool {
        let count = try database.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clip_fts'"
        ) as? Int64 ?? 0
        return count > 0
    }

    nonisolated static func rebuildIndex(on database: Connection) throws {
        try database.execute("INSERT INTO clip_fts(clip_fts) VALUES('rebuild');")
    }
}
