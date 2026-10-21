//
//  FocusRegion.swift
//  Clipboard
//
//  Created by crown on 2026/4/11.
//

enum FocusRegion: CustomStringConvertible {
    case collection
    case search
    case chipEditing
    case aliasEditing
    case filter
    case popover

    var description: String {
        switch self {
        case .collection: "collection"
        case .search: "search"
        case .chipEditing: "chipEditing"
        case .aliasEditing: "aliasEditing"
        case .filter: "filter"
        case .popover: "popover"
        }
    }
}
