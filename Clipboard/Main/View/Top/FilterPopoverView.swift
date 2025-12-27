//
//  FilterPopoverView.swift
//  Clipboard
//
//  Created by crown on 2025/12/12.
//

import SwiftUI

struct FilterPopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var topBarVM: TopBarViewModel

    @State private var appInfoList: [(name: String, path: String)] = []
    @State private var isLoadingApps: Bool = false
    @State private var showAllApps: Bool = false
    @State private var tagTypes: [PasteModelType] = []

    // MARK: - 统一的三列网格布局
    private let threeColumnGrid = [
        GridItem(.flexible(), spacing: Const.space8),
        GridItem(.flexible(), spacing: Const.space8),
        GridItem(.flexible(), spacing: Const.space8),
    ]

    private var displayedAppInfo: [(name: String, path: String)] {
        let totalCount = appInfoList.count
        if totalCount <= 9 {
            return appInfoList
        } else {
            if showAllApps {
                return appInfoList
            } else {
                return Array(appInfoList.prefix(8))
            }
        }
    }

    private var shouldShowMoreButton: Bool {
        appInfoList.count > 9
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Const.space16) {
                if !tagTypes.isEmpty {
                    typeSection
                }

                if !appInfoList.isEmpty {
                    appSection
                }

                dateSection

                if topBarVM.hasActiveFilters {
                    clearFiltersButton
                }
            }
            .padding(Const.space16)
        }
        .frame(width: 480.0, height: 270.0)
        .focusEffectDisabled()
        .task {
            await loadAppInfo()
        }
    }

    // MARK: - Type Section

    private var typeSection: some View {
        filterSection(title: "Type") {
            ForEach(tagTypes, id: \.self) { type in
                if type == .string {
                    textTypeButton()
                } else {
                    let iconAndLabel = type.iconAndLabel
                    FilterButton(
                        systemImage: iconAndLabel.icon,
                        label: iconAndLabel.label,
                        isSelected: topBarVM.selectedTypes.contains(type),
                        action: { topBarVM.toggleType(type) }
                    )
                }
            }
        }
    }

    private func textTypeButton() -> some View {
        let isSelected = topBarVM.isTextTypeSelected()
        let iconName = if #available(macOS 15.0, *) { "text.document" } else { "doc.text" }
        
        return FilterButton(
            systemImage: iconName,
            label: "文本",
            isSelected: isSelected,
            action: { topBarVM.toggleTextType() }
        )
    }

    // MARK: - App Section

    private var appSection: some View {
        filterSection(title: "App") {
            ForEach(displayedAppInfo, id: \.name) { appInfo in
                appButton(name: appInfo.name, path: appInfo.path)
            }

            if shouldShowMoreButton {
                moreButton
            }
        }
    }

    private func appButton(name: String, path: String) -> some View {
        FilterButton(
            icon: {
                if FileManager.default.fileExists(atPath: path) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: Const.space16))
                        .foregroundStyle(.secondary)
                }
            },
            label: name,
            isSelected: topBarVM.selectedAppNames.contains(name),
            action: {
                topBarVM.toggleApp(name)
            },
        )
    }

    private var moreButton: some View {
        FilterButton(
            systemImage: showAllApps ? "chevron.up.circle" : "chevron.down.circle",
            label: showAllApps ? "收起" : "更多",
            isSelected: false,
            action: { showAllApps.toggle() }
        )
    }

    // MARK: - Date Section

    private var dateSection: some View {
        filterSection(title: "Date") {
            ForEach(TopBarViewModel.DateFilterOption.allCases, id: \.self) { option in
                let isSelected = topBarVM.selectedDateFilter == option
                FilterButton(
                    systemImage: "calendar",
                    label: option.displayName,
                    isSelected: isSelected,
                    action: { topBarVM.setDateFilter(isSelected ? nil : option) }
                )
            }
        }
    }

    // MARK: - Clear Filters Button

    private var clearFiltersButton: some View {
        FilterButton(
            systemImage: "xmark.circle",
            label: "清除筛选",
            isSelected: false,
            action: { topBarVM.clearAllFilters() }
        )
    }

    // MARK: - Reusable Components

    /// 通用筛选区块
    private func filterSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Const.space8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: threeColumnGrid, spacing: Const.space8) {
                content()
            }
        }
    }

    // MARK: - Helper Methods

    private func loadAppInfo() async {
        isLoadingApps = true
        async let info = PasteDataStore.main.getAllAppInfo()
        async let types = PasteDataStore.main.getAllTagTypes()

        let (appInfo, tagTypeList) = await (info, types)

        await MainActor.run {
            appInfoList = appInfo
            tagTypes = tagTypeList
            isLoadingApps = false
        }
    }
}
