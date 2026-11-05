import XCTest
@testable import nvModern

final class WorkspaceSidebarTreeBuilderTests: XCTestCase {
    func testCompactsConsecutiveSingleChildFolders() {
        let tree: [String: [MillerItem]] = [
            "": [folder("Projects", name: "Projects")],
            "Projects": [folder("Projects/nvModern", name: "nvModern")],
            "Projects/nvModern": [folder("Projects/nvModern/Design", name: "Design")],
            "Projects/nvModern/Design": [note("Projects/nvModern/Design/sidebar.md", name: "sidebar.md")]
        ]

        let collapsedRows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: nil,
            expandedFolderPaths: []
        )

        XCTAssertEqual(collapsedRows.count, 1)
        XCTAssertEqual(collapsedRows[0].displayName, "Projects / nvModern / Design")
        XCTAssertEqual(collapsedRows[0].relativePath, "Projects/nvModern/Design")
        XCTAssertTrue(collapsedRows[0].hasChildren)

        let expandedRows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: nil,
            expandedFolderPaths: ["Projects/nvModern/Design"]
        )

        XCTAssertEqual(expandedRows.map(\.displayName), ["Projects / nvModern / Design", "sidebar.md"])
        XCTAssertEqual(expandedRows.map(\.depth), [0, 1])
    }

    func testCompactionStopsWhereAChoiceExists() {
        let tree: [String: [MillerItem]] = [
            "": [folder("Projects", name: "Projects")],
            "Projects": [
                folder("Projects/nvModern", name: "nvModern"),
                folder("Projects/trading", name: "trading")
            ]
        ]

        let rows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: nil,
            expandedFolderPaths: []
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, "Projects")
        XCTAssertEqual(rows[0].relativePath, "Projects")
    }

    func testFocusedRootStartsItsChildrenAtDepthZero() {
        let tree: [String: [MillerItem]] = [
            "Projects/nvModern": [
                folder("Projects/nvModern/Design", name: "Design"),
                note("Projects/nvModern/readme.md", name: "readme.md")
            ]
        ]

        let rows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: "Projects/nvModern",
            expandedFolderPaths: []
        )

        XCTAssertEqual(rows.map(\.displayName), ["Design", "readme.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 0])
    }

    func testDocumentAncestorsIncludeEveryFolderLevel() {
        XCTAssertEqual(
            WorkspaceSidebarTreeBuilder.ancestorFolderPaths(
                forDocumentPath: "Projects/nvModern/Design/sidebar.md"
            ),
            ["Projects", "Projects/nvModern", "Projects/nvModern/Design"]
        )
    }

    func testFilterFindsCollapsedDescendantsAndKeepsTheirLineage() {
        let tree: [String: [MillerItem]] = [
            "": [folder("Projects", name: "Projects")],
            "Projects": [
                folder("Projects/nvModern", name: "nvModern"),
                folder("Projects/trading", name: "trading")
            ],
            "Projects/nvModern": [folder("Projects/nvModern/Design", name: "Design")],
            "Projects/nvModern/Design": [note("Projects/nvModern/Design/sidebar.md", name: "sidebar.md")],
            "Projects/trading": [note("Projects/trading/strategy.md", name: "strategy.md")]
        ]

        let rows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: nil,
            expandedFolderPaths: [],
            filterQuery: "sidebar"
        )

        XCTAssertEqual(rows.map(\.displayName), [
            "Projects",
            "nvModern / Design",
            "sidebar.md"
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    func testFilterMatchesPathsCaseInsensitively() {
        let tree: [String: [MillerItem]] = [
            "": [folder("Projects", name: "Projects")],
            "Projects": [note("Projects/Release Notes.md", name: "Release Notes.md")]
        ]

        let rows = WorkspaceSidebarTreeBuilder.rows(
            childrenByFolder: tree,
            rootPath: nil,
            expandedFolderPaths: [],
            filterQuery: "RELEASE"
        )

        XCTAssertEqual(rows.map(\.displayName), ["Projects", "Release Notes.md"])
    }

    private func folder(_ path: String, name: String) -> MillerItem {
        MillerItem(relativePath: path, name: name, kind: .folder, modifiedDate: nil)
    }

    private func note(_ path: String, name: String) -> MillerItem {
        MillerItem(relativePath: path, name: name, kind: .note, modifiedDate: nil)
    }
}
