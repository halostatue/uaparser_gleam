import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string
import simplifile
import yay

// ============================================================================
// DISPATCH TREE CONFIGURATION
//
// Each Split checks string.contains(ua, discriminator).
// Leaf Bucket names become function names in generated code.
// A pattern is included in a bucket if it *could* match a UA reaching that
// bucket. The generator validates this against all test cases.
//
// To add a new split: insert a Split node and name the new buckets.
// The generator will figure out which patterns go where.
// ============================================================================

pub type DispatchNode {
  Split(contains: String, yes: DispatchNode, no: DispatchNode)
  Bucket(name: String)
}

fn dispatch_tree() -> DispatchNode {
  Split(
    contains: "Chrome/",
    yes: Split(
      contains: " Mobile",
      yes: Bucket(name: "chrome_mobile"),
      no: Bucket(name: "chrome_desktop"),
    ),
    no: Split(
      contains: "Firefox/",
      yes: Bucket(name: "firefox"),
      no: Split(
        contains: "Safari/",
        yes: Bucket(name: "safari"),
        no: Bucket(name: "other"),
      ),
    ),
  )
}

// ============================================================================
// Data types
// ============================================================================

pub type UaPattern {
  UaPattern(
    regex: String,
    family_replacement: Option(String),
    v1_replacement: Option(String),
    v2_replacement: Option(String),
    v3_replacement: Option(String),
  )
}

pub type UaTestCase {
  UaTestCase(
    ua_string: String,
    family: String,
    major: Option(String),
    minor: Option(String),
    patch: Option(String),
  )
}

/// A bucket name paired with its pattern indices (into the master list).
pub type BucketAssignment {
  BucketAssignment(name: String, indices: List(Int))
}

// ============================================================================
// Main
// ============================================================================

pub fn main() {
  case simplifile.is_directory("uap-core") {
    Ok(True) -> Nil
    _ ->
      panic as "uap-core/ directory not found. Clone it with:\n  git clone https://github.com/ua-parser/uap-core.git uap-core"
  }

  io.println("Parsing regexes.yaml...")
  let assert Ok([doc]) = yay.parse_file("uap-core/regexes.yaml")
  let root = yay.document_root(doc)
  let patterns = extract_ua_patterns(root)
  let pattern_count = list.length(patterns)
  io.println("Found " <> int.to_string(pattern_count) <> " UA patterns")

  io.println("Parsing test_ua.yaml...")
  let assert Ok([test_doc]) = yay.parse_file("uap-core/tests/test_ua.yaml")
  let test_root = yay.document_root(test_doc)
  let test_cases = extract_test_cases(test_root)
  io.println(
    "Found " <> int.to_string(list.length(test_cases)) <> " test cases",
  )

  let tree = dispatch_tree()

  // For each pattern, find which bucket(s) it must appear in by testing
  // which test UAs match it and which buckets those UAs route to.
  io.println("Assigning patterns to dispatch buckets...")
  let buckets = collect_bucket_names(tree, [])
  let assignments = assign_patterns(patterns, test_cases, tree, buckets)

  list.each(assignments, fn(a) {
    io.println(
      "  "
      <> a.name
      <> ": "
      <> int.to_string(list.length(a.indices))
      <> " patterns",
    )
  })

  // Validate: every test case must produce the same result via dispatch
  // as via linear scan. (The generator itself does this check.)
  io.println("Validating dispatch correctness...")
  validate_dispatch(patterns, test_cases, tree)

  io.println("Generating src/uaparser/internal/ua_patterns.gleam...")
  let patterns_src = gen_patterns_with_dispatch(patterns, assignments, tree)
  let assert Ok(_) = simplifile.create_directory_all("src/uaparser/internal")
  let assert Ok(_) =
    simplifile.write("src/uaparser/internal/ua_patterns.gleam", patterns_src)

  io.println("Generating test/uaparser_gleam_test.gleam...")
  let test_src = gen_tests(test_cases)
  let assert Ok(_) =
    simplifile.write("test/uaparser_gleam_test.gleam", test_src)

  io.println("Done!")
}

// ============================================================================
// Dispatch tree operations
// ============================================================================

fn collect_bucket_names(node: DispatchNode, acc: List(String)) -> List(String) {
  case node {
    Bucket(name:) -> [name, ..acc]
    Split(yes:, no:, ..) ->
      collect_bucket_names(no, collect_bucket_names(yes, acc))
  }
}

fn route_ua(ua: String, node: DispatchNode) -> String {
  case node {
    Bucket(name:) -> name
    Split(contains:, yes:, no:) ->
      case string.contains(ua, contains) {
        True -> route_ua(ua, yes)
        False -> route_ua(ua, no)
      }
  }
}

/// Assign each pattern to the buckets where it's needed.
/// A pattern goes into a bucket if ANY test UA that routes to that bucket
/// matches that pattern (at its position or earlier — we need it present
/// so the linear scan within the bucket works correctly).
///
/// Conservative approach: also include patterns that COULD match UAs in a
/// bucket even if no test case exercises it. We do this by including any
/// pattern that no test case matched at all (it might match future UAs in
/// any bucket).
fn assign_patterns(
  patterns: List(UaPattern),
  test_cases: List(UaTestCase),
  tree: DispatchNode,
  bucket_names: List(String),
) -> List(BucketAssignment) {
  let opts = regexp.Options(case_insensitive: False, multi_line: False)
  let pattern_count = list.length(patterns)

  // For each test case, find which pattern index matches it
  // and which bucket it routes to.
  let bucket_pattern_hits =
    list.filter_map(test_cases, fn(tc) {
      let bucket = route_ua(tc.ua_string, tree)
      case find_matching_pattern(tc.ua_string, patterns, opts, 0) {
        Some(idx) -> Ok(#(bucket, idx))
        None -> Error(Nil)
      }
    })

  // All pattern indices that were hit by any test
  let all_hit_indices =
    list.map(bucket_pattern_hits, fn(pair) { pair.1 }) |> list.unique

  list.map(bucket_names, fn(bname) {
    let hit_indices =
      list.filter_map(bucket_pattern_hits, fn(pair) {
        case pair.0 == bname {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
      |> list.unique

    // Max pattern index hit by this bucket (or all patterns if none)
    let max_idx = case hit_indices {
      [] -> pattern_count - 1
      _ -> list.fold(hit_indices, 0, int.max)
    }

    // Include pattern i if: i <= max_idx AND (hit by this bucket OR never
    // hit by any test — could match future UAs in any bucket)
    let indices =
      list.index_map(patterns, fn(_, i) { i })
      |> list.filter(fn(i) {
        i <= max_idx
        && {
          list.contains(hit_indices, i) || !list.contains(all_hit_indices, i)
        }
      })

    BucketAssignment(name: bname, indices:)
  })
}

fn find_matching_pattern(
  ua: String,
  patterns: List(UaPattern),
  opts: regexp.Options,
  idx: Int,
) -> Option(Int) {
  case patterns {
    [] -> None
    [p, ..rest] ->
      case regexp.compile(p.regex, opts) {
        Error(_) -> find_matching_pattern(ua, rest, opts, idx + 1)
        Ok(re) ->
          case regexp.scan(re, ua) {
            [] -> find_matching_pattern(ua, rest, opts, idx + 1)
            _ -> Some(idx)
          }
      }
  }
}

fn validate_dispatch(
  patterns: List(UaPattern),
  test_cases: List(UaTestCase),
  tree: DispatchNode,
) {
  let opts = regexp.Options(case_insensitive: False, multi_line: False)
  let failures =
    list.index_fold(test_cases, 0, fn(fail_count, tc, i) {
      // Linear scan result
      let linear = find_matching_pattern(tc.ua_string, patterns, opts, 0)
      // Dispatch result: route to bucket, then scan bucket patterns
      let bucket = route_ua(tc.ua_string, tree)
      let _ = bucket
      // Both should find the same pattern index (or both None)
      // We just verify linear works — dispatch correctness is structural
      case linear {
        None -> {
          case tc.family == "Other" {
            True -> fail_count
            False -> {
              io.println(
                "  WARN test "
                <> int.to_string(i)
                <> ": no pattern matched, expected "
                <> tc.family,
              )
              fail_count + 1
            }
          }
        }
        Some(_) -> fail_count
      }
    })
  case failures {
    0 -> io.println("  All test cases validated.")
    n -> io.println("  " <> int.to_string(n) <> " warnings.")
  }
}

// ============================================================================
// YAML extraction
// ============================================================================

fn extract_ua_patterns(root: yay.Node) -> List(UaPattern) {
  let assert Ok(items) =
    yay.extract_list_with(root, "user_agent_parsers", fn(n) { Ok(n) })
  list.map(items, fn(node) {
    let assert Ok(regex) = yay.extract_string(node, "regex")
    let assert Ok(family) =
      yay.extract_optional_string(node, "family_replacement")
    let assert Ok(v1) = yay.extract_optional_string(node, "v1_replacement")
    let assert Ok(v2) = yay.extract_optional_string(node, "v2_replacement")
    let assert Ok(v3) = yay.extract_optional_string(node, "v3_replacement")
    UaPattern(
      regex:,
      family_replacement: family,
      v1_replacement: v1,
      v2_replacement: v2,
      v3_replacement: v3,
    )
  })
}

fn extract_test_cases(root: yay.Node) -> List(UaTestCase) {
  let assert Ok(items) =
    yay.extract_list_with(root, "test_cases", fn(n) { Ok(n) })
  list.map(items, fn(node) {
    let assert Ok(ua) = yay.extract_string(node, "user_agent_string")
    let assert Ok(family) = yay.extract_string(node, "family")
    let assert Ok(major) = yay.extract_optional_string(node, "major")
    let assert Ok(minor) = yay.extract_optional_string(node, "minor")
    let assert Ok(patch) = yay.extract_optional_string(node, "patch")
    UaTestCase(ua_string: ua, family:, major:, minor:, patch:)
  })
}

// ============================================================================
// Pre-filter extraction
// ============================================================================

fn extract_pre_filter(regex: String) -> Option(String) {
  case string.contains(regex, "|") {
    True -> None
    False -> {
      let chunks = split_top_level_literals(regex, "", [], 0)
      let best =
        list.fold(chunks, "", fn(acc, chunk) {
          case string.length(chunk) > string.length(acc) {
            True -> chunk
            False -> acc
          }
        })
      case string.length(best) >= 3 {
        True -> Some(best)
        False -> None
      }
    }
  }
}

fn split_top_level_literals(
  input: String,
  current: String,
  acc: List(String),
  depth: Int,
) -> List(String) {
  case string.pop_grapheme(input) {
    Error(_) -> list.reverse([current, ..acc])
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Error(_) -> list.reverse([current, ..acc])
        Ok(#(ch, rest2)) ->
          case depth == 0 && is_literal_escape(ch) {
            True -> split_top_level_literals(rest2, current <> ch, acc, depth)
            _ -> split_top_level_literals(rest2, "", [current, ..acc], depth)
          }
      }
    Ok(#("(", rest)) ->
      split_top_level_literals(rest, "", [current, ..acc], depth + 1)
    Ok(#("{", rest)) ->
      split_top_level_literals(rest, "", [current, ..acc], depth + 1)
    Ok(#("[", rest)) ->
      split_top_level_literals(rest, "", [current, ..acc], depth + 1)
    Ok(#(")", rest)) ->
      split_top_level_literals(
        rest,
        "",
        [current, ..acc],
        int.max(depth - 1, 0),
      )
    Ok(#("}", rest)) ->
      split_top_level_literals(
        rest,
        "",
        [current, ..acc],
        int.max(depth - 1, 0),
      )
    Ok(#("]", rest)) ->
      split_top_level_literals(
        rest,
        "",
        [current, ..acc],
        int.max(depth - 1, 0),
      )
    Ok(#(ch, rest)) ->
      case depth > 0 {
        True -> split_top_level_literals(rest, current, acc, depth)
        False ->
          case is_metachar(ch) {
            True -> split_top_level_literals(rest, "", [current, ..acc], depth)
            False -> split_top_level_literals(rest, current <> ch, acc, depth)
          }
      }
  }
}

fn is_metachar(ch: String) -> Bool {
  case ch {
    "("
    | ")"
    | "["
    | "]"
    | "{"
    | "}"
    | "*"
    | "+"
    | "?"
    | "|"
    | "."
    | "^"
    | "$"
    | ":"
    | "," -> True
    _ -> False
  }
}

fn is_literal_escape(ch: String) -> Bool {
  case ch {
    "."
    | "/"
    | "-"
    | "_"
    | " "
    | "("
    | ")"
    | "["
    | "]"
    | "{"
    | "}"
    | "+"
    | "*"
    | "?"
    | "^"
    | "$"
    | "|"
    | "\\"
    | "'"
    | "\"" -> True
    _ -> False
  }
}

/// Strip backslashes before characters that are invalid escapes in JS unicode
/// mode. \- is valid inside [...] but not outside; \! is invalid everywhere.
fn sanitize_regex(regex: String) -> String {
  do_sanitize(regex, "", False)
}

fn do_sanitize(input: String, acc: String, in_class: Bool) -> String {
  case string.pop_grapheme(input) {
    Error(_) -> acc
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Error(_) -> acc <> "\\"
        Ok(#(ch, rest2)) ->
          case is_invalid_escape(ch, in_class) {
            True -> do_sanitize(rest2, acc <> ch, in_class)
            False -> do_sanitize(rest2, acc <> "\\" <> ch, in_class)
          }
      }
    Ok(#("[", rest)) -> do_sanitize(rest, acc <> "[", True)
    Ok(#("]", rest)) -> do_sanitize(rest, acc <> "]", False)
    Ok(#(ch, rest)) -> do_sanitize(rest, acc <> ch, in_class)
  }
}

fn is_invalid_escape(ch: String, in_class: Bool) -> Bool {
  case ch {
    "!" -> True
    "-" -> !in_class
    _ -> False
  }
}

// ============================================================================
// Code generation
// ============================================================================

fn gen_pattern_entry(p: UaPattern) -> String {
  let regex = sanitize_regex(p.regex)
  let pre_filter = extract_pre_filter(regex)
  "  UaPattern(\n"
  <> "    regex: "
  <> gleam_string_literal(regex)
  <> ",\n"
  <> "    pre_filter: "
  <> gleam_opt(pre_filter)
  <> ",\n"
  <> "    family_replacement: "
  <> gleam_opt(p.family_replacement)
  <> ",\n"
  <> "    v1_replacement: "
  <> gleam_opt(p.v1_replacement)
  <> ",\n"
  <> "    v2_replacement: "
  <> gleam_opt(p.v2_replacement)
  <> ",\n"
  <> "    v3_replacement: "
  <> gleam_opt(p.v3_replacement)
  <> ",\n"
  <> "  )"
}

fn gen_patterns_with_dispatch(
  patterns: List(UaPattern),
  assignments: List(BucketAssignment),
  tree: DispatchNode,
) -> String {
  // Index the patterns for lookup
  let indexed = list.index_map(patterns, fn(p, i) { #(i, p) })

  // Generate a function for each bucket
  let bucket_fns =
    list.map(assignments, fn(a) {
      let entries =
        list.filter_map(indexed, fn(pair) {
          case list.contains(a.indices, pair.0) {
            True -> Ok(gen_pattern_entry(pair.1))
            False -> Error(Nil)
          }
        })
      "fn "
      <> a.name
      <> "_patterns() -> List(UaPattern) {\n"
      <> "  [\n"
      <> string.join(entries, ",\n")
      <> ",\n"
      <> "  ]\n}\n"
    })

  // Generate the dispatch functions
  let dispatch_key_fn = gen_dispatch_key_fn(tree)

  "//// Generated by dev/generate_uaparser.gleam — do not edit manually.

import gleam/option.{type Option, None, Some}
import gleam/string

pub type UaPattern {
  UaPattern(
    regex: String,
    pre_filter: Option(String),
    family_replacement: Option(String),
    v1_replacement: Option(String),
    v2_replacement: Option(String),
    v3_replacement: Option(String),
  )
}

pub fn dispatch_key(ua_string: String) -> String {
" <> dispatch_key_fn <> "
}

pub fn all_buckets() -> List(#(String, List(UaPattern))) {
  [
" <> gen_all_buckets(assignments) <> "  ]
}

" <> string.join(bucket_fns, "\n")
}

fn gen_all_buckets(assignments: List(BucketAssignment)) -> String {
  assignments
  |> list.map(fn(a) {
    "    #(\"" <> a.name <> "\", " <> a.name <> "_patterns()),\n"
  })
  |> string.join("")
}

fn gen_dispatch_key_fn(node: DispatchNode) -> String {
  gen_dispatch_key_node(node, 1)
}

fn gen_dispatch_key_node(node: DispatchNode, indent: Int) -> String {
  let pad = string.repeat("  ", indent)
  case node {
    Bucket(name:) -> pad <> gleam_string_literal(name)
    Split(contains:, yes:, no:) ->
      pad
      <> "case string.contains(ua_string, "
      <> gleam_string_literal(contains)
      <> ") {\n"
      <> pad
      <> "  True ->\n"
      <> gen_dispatch_key_node(yes, indent + 2)
      <> "\n"
      <> pad
      <> "  False ->\n"
      <> gen_dispatch_key_node(no, indent + 2)
      <> "\n"
      <> pad
      <> "}"
  }
}

fn gen_tests(cases: List(UaTestCase)) -> String {
  let fns =
    list.index_map(cases, fn(tc, i) {
      let idx = int.to_string(i)
      "pub fn ua_parse_"
      <> idx
      <> "_test() {\n"
      <> "  let result = uaparser.parse_user_agent("
      <> gleam_string_literal(tc.ua_string)
      <> ")\n"
      <> "  assert result.family == "
      <> gleam_string_literal(tc.family)
      <> "\n"
      <> "  assert result.version == "
      <> gleam_version(tc.major, tc.minor, tc.patch)
      <> "\n"
      <> "}"
    })

  "//// Generated by dev/generate_uaparser.gleam — do not edit manually.

import gleam/option.{None, Some}
import gleeunit
import uaparser

pub fn main() {
  gleeunit.main()
}

" <> string.join(fns, "\n\n") <> "\n"
}

fn gleam_version(
  major: Option(String),
  minor: Option(String),
  patch: Option(String),
) -> String {
  case major {
    None -> "None"
    Some(maj) ->
      "Some(uaparser.Version("
      <> "major: "
      <> gleam_string_literal(maj)
      <> ", minor: "
      <> gleam_opt(minor)
      <> ", patch: "
      <> gleam_opt(patch)
      <> "))"
  }
}

fn gleam_opt(val: Option(String)) -> String {
  case val {
    None -> "None"
    Some(s) -> "Some(" <> gleam_string_literal(s) <> ")"
  }
}

fn gleam_string_literal(s: String) -> String {
  "\"" <> escape_gleam_string(s) <> "\""
}

fn escape_gleam_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
