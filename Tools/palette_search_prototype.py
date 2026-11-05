#!/usr/bin/env python3
"""Prototype a shared, explainable ranking model for nvModern's palette.

The prototype deliberately keeps ranking ordinal.  It does not add unrelated
signals into one floating-point score:

* every query term gets its best field-local match;
* match specificity dominates match location;
* item fields dominate property fields at equal specificity;
* candidates compare their weakest term first (leximin / discrete maximin);
* phrase and path coherence, declared fallback rank, and title only break ties.

Run without arguments to execute the tests and print representative rankings.
Use ``--dataset folders --query Alex`` to inspect an individual query.
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
import unittest
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Hashable, Iterable, Mapping, Sequence


class Specificity(IntEnum):
    FUZZY = 1
    SUBSTRING = 2
    PREFIX = 3
    EXACT_TOKEN = 4
    EXACT_FIELD = 5


@dataclass(frozen=True, order=True)
class AtomicRank:
    """Comparable rank for one query term; larger is always better."""

    specificity: int
    location_kind: int
    location_detail: int
    quality: tuple[int, int, int, int]


@dataclass(frozen=True)
class MatchEvidence:
    term: str
    field_name: str
    field_value: str
    rank: AtomicRank
    positions: tuple[int, ...] = ()


@dataclass(frozen=True, order=True)
class CandidateRank:
    """Lexicographic candidate rank; no dimension can numerically compensate."""

    # Sorted weakest-first, so the worst term decides before a strong term can.
    term_ranks: tuple[AtomicRank, ...]
    coherence: tuple[int, int, int]
    fallback: int


@dataclass(frozen=True)
class SearchCandidate:
    identifier: Hashable
    label: str
    # General/root to specific/leaf.
    items: tuple[str, ...]
    properties: Mapping[str, tuple[str, ...]] = field(default_factory=dict)
    # Lower values are preferred only after query relevance is exhausted.
    fallback_rank: int = 100


@dataclass(frozen=True)
class RankedCandidate:
    candidate: SearchCandidate
    rank: CandidateRank
    matches: tuple[MatchEvidence, ...]


@dataclass(frozen=True)
class Query:
    raw: str
    terms: tuple[str, ...]
    phrase: str
    hierarchy_parts: tuple[str, ...]


PROPERTY_PRIORITY = {
    "aliases": 50,
    "keywords": 50,
    "category": 40,
    "extension": 40,
    "provider": 30,
    "tags": 20,
    "method": 10,
    "id": 0,
}

_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def normalize(value: str) -> str:
    """Fold case/diacritics and turn presentation punctuation into boundaries."""

    expanded = _CAMEL_BOUNDARY.sub(" ", value)
    decomposed = unicodedata.normalize("NFKD", expanded)
    folded = "".join(char for char in decomposed if not unicodedata.combining(char))
    return " ".join(_NON_ALNUM.sub(" ", folded.casefold()).split())


def tokens(value: str) -> tuple[str, ...]:
    normalized = normalize(value)
    return tuple(normalized.split()) if normalized else ()


def parse_query(raw: str) -> Query:
    hierarchy_parts = tuple(
        part for raw_part in raw.split("/") if (part := normalize(raw_part))
    ) if "/" in raw else ()
    return Query(
        raw=raw,
        terms=tokens(raw),
        phrase=normalize(raw),
        hierarchy_parts=hierarchy_parts,
    )


def _semantic_token_index(field_tokens: Sequence[str], token_index: int) -> int:
    """Treat organizational prefixes such as ``80-`` as neutral."""

    ignored = 0
    for token in field_tokens[:token_index]:
        if token.isdigit():
            ignored += 1
        else:
            break
    return token_index - ignored


def _subsequence_positions(term: str, candidate: str) -> tuple[int, ...] | None:
    positions: list[int] = []
    cursor = 0
    for character in term:
        index = candidate.find(character, cursor)
        if index < 0:
            return None
        positions.append(index)
        cursor = index + 1
    return tuple(positions)


def _longest_consecutive_run(positions: Sequence[int]) -> int:
    if not positions:
        return 0
    longest = current = 1
    for left, right in zip(positions, positions[1:]):
        current = current + 1 if right == left + 1 else 1
        longest = max(longest, current)
    return longest


def _field_match(
    term: str,
    raw_field: str,
    *,
    location_kind: int,
    location_detail: int,
    field_name: str,
) -> MatchEvidence | None:
    candidate = normalize(raw_field)
    if not candidate:
        return None
    field_tokens = tuple(candidate.split())

    if candidate == term:
        rank = AtomicRank(Specificity.EXACT_FIELD, location_kind, location_detail, (0, 0, 0, 0))
        return MatchEvidence(term, field_name, raw_field, rank)

    exact_token_indices = [index for index, token in enumerate(field_tokens) if token == term]
    if exact_token_indices:
        token_index = min(_semantic_token_index(field_tokens, index) for index in exact_token_indices)
        quality = (-token_index, -len(field_tokens), -len(candidate), 0)
        rank = AtomicRank(Specificity.EXACT_TOKEN, location_kind, location_detail, quality)
        return MatchEvidence(term, field_name, raw_field, rank)

    prefix_indices = [index for index, token in enumerate(field_tokens) if token.startswith(term)]
    if prefix_indices:
        token_index = min(prefix_indices, key=lambda index: _semantic_token_index(field_tokens, index))
        semantic_index = _semantic_token_index(field_tokens, token_index)
        remainder = len(field_tokens[token_index]) - len(term)
        quality = (-semantic_index, -remainder, -len(candidate), 0)
        rank = AtomicRank(Specificity.PREFIX, location_kind, location_detail, quality)
        return MatchEvidence(term, field_name, raw_field, rank)

    substring_index = candidate.find(term)
    if substring_index >= 0:
        quality = (-substring_index, -len(candidate), 0, 0)
        rank = AtomicRank(Specificity.SUBSTRING, location_kind, location_detail, quality)
        positions = tuple(range(substring_index, substring_index + len(term)))
        return MatchEvidence(term, field_name, raw_field, rank, positions)

    positions = _subsequence_positions(term, candidate)
    if positions is None:
        return None
    span = positions[-1] - positions[0] + 1
    gaps = span - len(positions)
    boundary_positions = {0}
    boundary_positions.update(index + 1 for index, char in enumerate(candidate) if char == " ")
    boundary_start = int(positions[0] in boundary_positions)
    quality = (
        boundary_start,
        _longest_consecutive_run(positions),
        -gaps,
        -span,
    )
    rank = AtomicRank(Specificity.FUZZY, location_kind, location_detail, quality)
    return MatchEvidence(term, field_name, raw_field, rank, positions)


def _all_fields(candidate: SearchCandidate) -> Iterable[tuple[str, str, int, int]]:
    leaf_index = len(candidate.items) - 1
    for index, value in enumerate(candidate.items):
        distance_from_leaf = leaf_index - index
        yield f"items[{index}]", value, 2, -distance_from_leaf

    for property_name in sorted(candidate.properties):
        priority = PROPERTY_PRIORITY.get(property_name, 0)
        for index, value in enumerate(candidate.properties[property_name]):
            yield f"properties.{property_name}[{index}]", value, 1, priority


def _best_term_match(term: str, candidate: SearchCandidate) -> MatchEvidence | None:
    matches = [
        match
        for field_name, value, location_kind, location_detail in _all_fields(candidate)
        if (
            match := _field_match(
                term,
                value,
                location_kind=location_kind,
                location_detail=location_detail,
                field_name=field_name,
            )
        )
        is not None
    ]
    if not matches:
        return None
    return max(matches, key=lambda match: match.rank)


def _ordered_item_assignment(query: Query, candidate: SearchCandidate) -> bool:
    """A slash query explicitly asks for path parts in root-to-leaf order."""

    if not query.hierarchy_parts:
        return True
    next_item = 0
    for part in query.hierarchy_parts:
        found = False
        for index in range(next_item, len(candidate.items)):
            match = _field_match(
                part,
                candidate.items[index],
                location_kind=2,
                location_detail=-(len(candidate.items) - 1 - index),
                field_name=f"items[{index}]",
            )
            if match is not None:
                next_item = index + 1
                found = True
                break
        if not found:
            return False
    return True


def _coherence(query: Query, candidate: SearchCandidate, matches: Sequence[MatchEvidence]) -> tuple[int, int, int]:
    if not query.terms:
        return (0, 0, 0)

    # A complete phrase in one field is stronger than independently scattered
    # terms, but only after the weakest per-term match has been compared.
    best_phrase_specificity = 0
    for field_name, value, location_kind, location_detail in _all_fields(candidate):
        phrase_match = _field_match(
            query.phrase,
            value,
            location_kind=location_kind,
            location_detail=location_detail,
            field_name=field_name,
        )
        if phrase_match is not None:
            best_phrase_specificity = max(best_phrase_specificity, int(phrase_match.rank.specificity))

    field_names = [match.field_name for match in matches]
    same_field = int(len(set(field_names)) == 1)

    item_indices: list[int] = []
    for name in field_names:
        match = re.fullmatch(r"items\[(\d+)]", name)
        if match is None:
            item_indices = []
            break
        item_indices.append(int(match.group(1)))
    ordered_items = int(bool(item_indices) and item_indices == sorted(item_indices))
    adjacent_items = int(
        ordered_items
        and all(right - left <= 1 for left, right in zip(item_indices, item_indices[1:]))
    )
    return (best_phrase_specificity, same_field + ordered_items, adjacent_items)


def rank_candidate(query: Query, candidate: SearchCandidate) -> RankedCandidate | None:
    if not query.terms:
        rank = CandidateRank((), (0, 0, 0), -candidate.fallback_rank)
        return RankedCandidate(candidate, rank, ())
    if not _ordered_item_assignment(query, candidate):
        return None

    matches: list[MatchEvidence] = []
    for term in query.terms:
        match = _best_term_match(term, candidate)
        if match is None:
            return None
        matches.append(match)

    # Leximin: compare the weakest term, then the next weakest, and so on.
    term_ranks = tuple(sorted(match.rank for match in matches))
    rank = CandidateRank(
        term_ranks=term_ranks,
        coherence=_coherence(query, candidate, matches),
        fallback=-candidate.fallback_rank,
    )
    return RankedCandidate(candidate, rank, tuple(matches))


def rank(query_text: str, candidates: Iterable[SearchCandidate]) -> list[RankedCandidate]:
    query = parse_query(query_text)
    ranked = [
        result
        for candidate in candidates
        if (result := rank_candidate(query, candidate)) is not None
    ]
    # Stable deterministic ties: label, then identifier.  Relevance is applied
    # in a second stable sort so it remains the primary ordering.
    ranked.sort(key=lambda result: (normalize(result.candidate.label), str(result.candidate.identifier)))
    ranked.sort(key=lambda result: result.rank, reverse=True)
    return ranked


def folder(identifier: str, path: str) -> SearchCandidate:
    parts = tuple(part for part in path.split("/") if part)
    return SearchCandidate(identifier=identifier, label=parts[-1] if parts else "Workspace Root", items=parts)


FOLDERS = (
    folder("sam", "10-Workspaces/00-Capture/00-Sam"),
    folder("article-data", "10-Workspaces/00-Capture/00-Sam/article-data"),
    folder("charts", "10-Workspaces/00-Capture/00-Sam/article-data/charts"),
    folder("instagram", "10-Workspaces/00-Capture/00-Sam/instagram-remote-handoff"),
    folder("market-reports", "10-Workspaces/00-Capture/00-Sam/market-reports"),
    folder("essay", "10-Workspaces/10-Workbench/30-Articles/10-Topics/topic-a/essay-one"),
    folder("drafts", "10-Workspaces/10-Workbench/30-Articles/10-Topics/topic-a/essay-one/drafts"),
    folder("research", "10-Workspaces/10-Workbench/30-Articles/10-Topics/topic-b/research"),
    folder("corporate-review", "10-Workspaces/10-Workbench/30-Articles/Corporate Review"),
    folder("alex", "10-Workspaces/10-Workbench/80-Alex"),
    folder("crv", "10-Workspaces/10-Workbench/80-Alex/CRV"),
    folder("manuals", "10-Workspaces/20-Reference/Manuals"),
    folder("storefront", "10-Workspaces/21-Storefront/storefront-outreach"),
)


FILES = (
    SearchCandidate(
        "crv-plan",
        "CRV.md",
        ("10-Workspaces", "10-Workbench", "80-Alex", "CRV.md"),
        {"extension": ("md",)},
    ),
    SearchCandidate(
        "crv-notes",
        "CRV Notes.md",
        ("10-Workspaces", "10-Workbench", "80-Alex", "CRV Notes.md"),
        {"extension": ("md",)},
    ),
    SearchCandidate(
        "weekly-review",
        "Weekly Review.md",
        ("10-Workspaces", "23-Market-Research", "Reports", "Weekly Review.md"),
        {"extension": ("md",)},
    ),
    SearchCandidate(
        "capture-review",
        "Capture Review.md",
        ("10-Workspaces", "00-Capture", "Capture Review.md"),
        {"extension": ("md",)},
    ),
)


ACTIONS = (
    SearchCandidate(
        "rename",
        "Rename",
        ("Rename",),
        {
            "aliases": ("rename", "move"),
            "category": ("File",),
            "tags": ("workspace", "document"),
            "method": ("workspace.document.rename",),
        },
        fallback_rank=12,
    ),
    SearchCandidate(
        "refile",
        "Refile to",
        ("Refile to",),
        {
            "aliases": ("move", "folder"),
            "category": ("File",),
            "tags": ("workspace", "note"),
            "method": ("workspace.note.refile",),
        },
        fallback_rank=10,
    ),
    SearchCandidate(
        "reload",
        "Reload Editor",
        ("Reload Editor",),
        {
            "category": ("Document",),
            "tags": ("reload", "web editor"),
            "method": ("workspace.document.reload",),
        },
        fallback_rank=200,
    ),
    SearchCandidate(
        "render",
        "Render Markdown",
        ("Render Markdown",),
        {
            "category": ("Document",),
            "tags": ("preview", "markdown"),
            "method": ("workspace.document.preview",),
        },
        fallback_rank=100,
    ),
    SearchCandidate(
        "open-recent",
        "Open Recent",
        ("Open Recent",),
        {
            "category": ("Open",),
            "tags": ("recent", "document"),
            "method": ("workspace.note.openRecent",),
        },
        fallback_rank=20,
    ),
)


DATASETS = {"folders": FOLDERS, "files": FILES, "actions": ACTIONS}


def _specificity_name(value: int) -> str:
    return Specificity(value).name.lower().replace("_", "-")


def print_ranking(dataset_name: str, query_text: str, *, limit: int = 12) -> None:
    print(f"\n{dataset_name}: {query_text!r}")
    results = rank(query_text, DATASETS[dataset_name])
    if not results:
        print("  no matches")
        return
    for index, result in enumerate(results[:limit], start=1):
        evidence = "; ".join(
            f"{match.term}={_specificity_name(match.rank.specificity)}@{match.field_name}:{match.field_value!r}"
            for match in result.matches
        )
        print(f"  {index:>2}. {result.candidate.label:<24} {evidence}")


class PaletteSearchPrototypeTests(unittest.TestCase):
    def labels(self, query_text: str, candidates: Iterable[SearchCandidate]) -> list[str]:
        return [result.candidate.label for result in rank(query_text, candidates)]

    def test_exact_folder_leaf_wins_over_cross_path_fuzzy_matches(self) -> None:
        labels = self.labels("CRV", FOLDERS)
        self.assertEqual(labels[0], "CRV")
        self.assertGreater(labels.index("Corporate Review"), labels.index("CRV"))
        self.assertNotIn("00-Sam", labels)

    def test_parent_query_prefers_parent_then_immediate_child(self) -> None:
        labels = self.labels("Alex", FOLDERS)
        self.assertEqual(labels[:2], ["80-Alex", "CRV"])

    def test_terms_can_match_ancestor_and_leaf(self) -> None:
        self.assertEqual(self.labels("alex crv", FOLDERS)[0], "CRV")

    def test_slash_query_requires_root_to_leaf_order(self) -> None:
        self.assertEqual(self.labels("workbench/alex/crv", FOLDERS)[0], "CRV")
        self.assertNotIn("CRV", self.labels("crv/alex", FOLDERS))

    def test_slash_part_can_contain_multiple_tokens(self) -> None:
        self.assertEqual(self.labels("80-Alex/CRV", FOLDERS)[0], "CRV")

    def test_fuzzy_match_cannot_cross_field_boundaries(self) -> None:
        candidate = SearchCandidate("split", "Capture / Sam", ("Capture", "Sam"))
        self.assertEqual(rank("crv", [candidate]), [])

    def test_exact_field_beats_exact_token_and_prefix(self) -> None:
        candidates = (
            SearchCandidate("exact", "Rename", ("Rename",)),
            SearchCandidate("token", "Rename Document", ("Rename Document",)),
            SearchCandidate("prefix", "Renameable", ("Renameable",)),
        )
        self.assertEqual(self.labels("rename", candidates), ["Rename", "Rename Document", "Renameable"])

    def test_leaf_match_beats_same_match_in_parent(self) -> None:
        parent = folder("child", "Workspace/Alex/CRV")
        leaf = folder("leaf", "Workspace/Alex")
        self.assertEqual(self.labels("alex", [parent, leaf]), ["Alex", "CRV"])

    def test_item_beats_property_at_equal_specificity(self) -> None:
        item = SearchCandidate("item", "Rename", ("Rename",))
        prop = SearchCandidate("prop", "Edit Name", ("Edit Name",), {"aliases": ("rename",)})
        self.assertEqual(self.labels("rename", [prop, item]), ["Rename", "Edit Name"])

    def test_exact_alias_beats_prefix_item(self) -> None:
        alias = SearchCandidate("alias", "Refile", ("Refile",), {"aliases": ("move",)})
        prefix = SearchCandidate("prefix", "Movement", ("Movement",))
        self.assertEqual(self.labels("move", [prefix, alias]), ["Refile", "Movement"])

    def test_rename_action_is_first_regardless_of_category(self) -> None:
        self.assertEqual(self.labels("Rename", ACTIONS)[0], "Rename")

    def test_curated_aliases_use_fallback_only_after_relevance_ties(self) -> None:
        self.assertEqual(self.labels("move", ACTIONS)[:2], ["Refile to", "Rename"])

    def test_exact_filename_beats_longer_filename_with_same_first_token(self) -> None:
        self.assertEqual(self.labels("crv", FILES)[:2], ["CRV.md", "CRV Notes.md"])

    def test_weakest_term_dominates_instead_of_being_averaged_away(self) -> None:
        balanced = SearchCandidate("balanced", "Alpha Omega", ("Alpha Prefix", "Omega Prefix"))
        lopsided = SearchCandidate("lopsided", "Exact Alpha, weak Omega", ("Alpha", "Only Mostly Matching Omega"))
        # "omg" is fuzzy in both, but the balanced candidate keeps both terms
        # in equally specific item fields instead of relying on one exact term.
        labels = self.labels("alp omg", [lopsided, balanced])
        self.assertEqual(labels[0], "Alpha Omega")

    def test_results_are_deterministic_when_ranks_tie(self) -> None:
        beta = SearchCandidate("b", "Beta", ("Shared",))
        alpha = SearchCandidate("a", "Alpha", ("Shared",))
        self.assertEqual(self.labels("shared", [beta, alpha]), ["Alpha", "Beta"])


def run_tests() -> bool:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PaletteSearchPrototypeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return result.wasSuccessful()


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true", help="run only the embedded tests")
    parser.add_argument("--dataset", choices=sorted(DATASETS), help="dataset to inspect")
    parser.add_argument("--query", help="query to rank; requires --dataset")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args(argv)
    if (args.dataset is None) != (args.query is None):
        parser.error("--dataset and --query must be supplied together")
    return args


def main(argv: Sequence[str] = ()) -> int:
    args = parse_args(argv)
    if args.test:
        return 0 if run_tests() else 1
    if args.dataset is not None:
        print_ranking(args.dataset, args.query, limit=args.limit)
        return 0

    if not run_tests():
        return 1
    for dataset_name, query_text in (
        ("folders", "CRV"),
        ("folders", "Alex"),
        ("folders", "alex crv"),
        ("actions", "Rename"),
        ("actions", "move"),
        ("files", "CRV"),
    ):
        print_ranking(dataset_name, query_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
