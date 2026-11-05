import XCTest
@testable import nvModern

final class PaletteSearchRankerTests: XCTestCase {
    private typealias Candidate = PaletteSearchRanker.Candidate<String>

    private func folder(_ id: String, _ path: String) -> Candidate {
        let items = PaletteSearchRanker.pathItems(path)
        return Candidate(id: id, label: items.last ?? "Workspace Root", items: items)
    }

    private func labels(_ query: String, _ candidates: [Candidate]) -> [String] {
        PaletteSearchRanker.rank(query: query, candidates: candidates).map(\.candidate.label)
    }

    private var folders: [Candidate] {
        [
            folder("sam", "10-Workspaces/00-Capture/00-Sam"),
            folder("article", "10-Workspaces/00-Capture/00-Sam/article-data"),
            folder("instagram", "10-Workspaces/00-Capture/00-Sam/instagram-remote-handoff"),
            folder("corporate", "10-Workspaces/10-Workbench/30-Articles/Corporate Review"),
            folder("alex", "10-Workspaces/10-Workbench/80-Alex"),
            folder("crv", "10-Workspaces/10-Workbench/80-Alex/CRV"),
            folder("manuals", "10-Workspaces/20-Reference/Manuals"),
            folder("storefront", "10-Workspaces/21-Storefront/storefront-outreach"),
        ]
    }

    func testExactFolderLeafWinsAndCrossFieldFuzzyMatchDisappears() {
        let result = labels("CRV", folders)
        XCTAssertEqual(result.first, "CRV")
        XCTAssertLessThan(result.firstIndex(of: "CRV")!, result.firstIndex(of: "Corporate Review")!)
        XCTAssertFalse(result.contains("00-Sam"))
    }

    func testParentQueryPrefersParentThenImmediateChild() {
        XCTAssertEqual(Array(labels("Alex", folders).prefix(2)), ["80-Alex", "CRV"])
    }

    func testTermsCanMatchAncestorAndLeaf() {
        XCTAssertEqual(labels("alex crv", folders).first, "CRV")
    }

    func testSlashQueryRequiresRootToLeafOrder() {
        XCTAssertEqual(labels("workbench/alex/crv", folders).first, "CRV")
        XCTAssertFalse(labels("crv/alex", folders).contains("CRV"))
    }

    func testSlashPartCanContainSeveralTokens() {
        XCTAssertEqual(labels("80-Alex/CRV", folders).first, "CRV")
    }

    func testFuzzyMatchCannotCrossFieldBoundaries() {
        let split = Candidate(id: "split", label: "Capture / Sam", items: ["Capture", "Sam"])
        XCTAssertTrue(labels("crv", [split]).isEmpty)
    }

    func testExactFieldBeatsExactTokenAndPrefix() {
        let candidates = [
            Candidate(id: "exact", label: "Rename", items: ["Rename"]),
            Candidate(id: "token", label: "Rename Document", items: ["Rename Document"]),
            Candidate(id: "prefix", label: "Renameable", items: ["Renameable"]),
        ]
        XCTAssertEqual(labels("rename", candidates), ["Rename", "Rename Document", "Renameable"])
    }

    func testLeafMatchBeatsTheSameMatchInAParent() {
        XCTAssertEqual(
            labels("alex", [folder("child", "Workspace/Alex/CRV"), folder("leaf", "Workspace/Alex")]),
            ["Alex", "CRV"]
        )
    }

    func testItemBeatsPropertyAtEqualSpecificity() {
        let item = Candidate(id: "item", label: "Rename", items: ["Rename"])
        let property = Candidate(
            id: "property",
            label: "Edit Name",
            items: ["Edit Name"],
            properties: ["aliases": ["rename"]]
        )
        XCTAssertEqual(labels("rename", [property, item]), ["Rename", "Edit Name"])
    }

    func testExactAliasBeatsPrefixItem() {
        let alias = Candidate(
            id: "alias",
            label: "Refile",
            items: ["Refile"],
            properties: ["aliases": ["move"]]
        )
        let prefix = Candidate(id: "prefix", label: "Movement", items: ["Movement"])
        XCTAssertEqual(labels("move", [prefix, alias]), ["Refile", "Movement"])
    }

    func testFallbackRankBreaksEqualAliasMatches() {
        let rename = Candidate(
            id: "rename",
            label: "Rename",
            items: ["Rename"],
            properties: ["aliases": ["move"]],
            fallbackRank: 12
        )
        let refile = Candidate(
            id: "refile",
            label: "Refile to",
            items: ["Refile to"],
            properties: ["aliases": ["move"]],
            fallbackRank: 10
        )
        XCTAssertEqual(labels("move", [rename, refile]), ["Refile to", "Rename"])
    }

    func testExactFilenameBeatsLongerFilenameWithSameFirstToken() {
        let exact = Candidate(id: "exact", label: "CRV.md", items: ["Workspace", "CRV.md"])
        let longer = Candidate(id: "longer", label: "CRV Notes.md", items: ["Workspace", "CRV Notes.md"])
        XCTAssertEqual(labels("crv", [longer, exact]), ["CRV.md", "CRV Notes.md"])
    }

    func testWeakestTermDominatesInsteadOfBeingAveragedAway() {
        let balanced = Candidate(
            id: "balanced",
            label: "Alpha Omega",
            items: ["Alpha Prefix", "Omega Prefix"]
        )
        let lopsided = Candidate(
            id: "lopsided",
            label: "Exact Alpha, weak Omega",
            items: ["Alpha", "Only Mostly Matching Omega"]
        )
        XCTAssertEqual(labels("alp omg", [lopsided, balanced]).first, "Alpha Omega")
    }

    func testResultsAreDeterministicWhenRanksTie() {
        let beta = Candidate(id: "b", label: "Beta", items: ["Shared"])
        let alpha = Candidate(id: "a", label: "Alpha", items: ["Shared"])
        XCTAssertEqual(labels("shared", [beta, alpha]), ["Alpha", "Beta"])
    }
}
