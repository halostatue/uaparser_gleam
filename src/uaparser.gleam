//// A User Agent parser for Gleam, generated from the [ua-parser/uap-core](https://github.com/ua-parser/uap-core)
//// regular expressions. Works on both Erlang and JavaScript targets.
////
//// ```gleam
//// let ua = uaparser.parse_user_agent(
////   "Mozilla/5.0 ... Chrome/120.0.0.0 Safari/537.36",
//// )
//// ua.family  // "Chrome"
//// ua.version // Some(Version(major: "120", minor: Some("0"), patch: Some("0")))
//// ```

import capuchin_crypt
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp}
import gleam/result
import gleam/string
import uaparser/internal/ua_patterns.{type UaPattern}

/// A parsed version with major, minor, and patch components.
pub type Version {
  Version(major: String, minor: Option(String), patch: Option(String))
}

/// The result of parsing a user agent string.
///
/// The `family` field contains the browser name (e.g., `"Chrome"`, `"Firefox"`,
/// `"Safari"`). If no pattern matches, the family is `"Other"`.
///
/// The `version` field is `Some(Version(...))` when version information was
/// extracted, or `None` when no version could be determined.
pub type UserAgent {
  UserAgent(family: String, version: Option(Version))
}

type CompiledPattern {
  CompiledPattern(re: Regexp, pattern: UaPattern)
}

const cache_key = "uaparser:compiled"

/// Parse a user agent string into a `UserAgent` result.
///
/// Regular expressions are compiled once on first call and cached for
/// subsequent calls. Predictive dispatching reduces the number of patterns
/// tested based on the content of the user agent string.
///
/// ```gleam
/// let ua = uaparser.parse_user_agent(
///   "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
/// )
/// ua.family  // "Chrome"
/// ```
pub fn parse_user_agent(ua_string: String) -> UserAgent {
  let compiled = get_compiled()
  let key = ua_patterns.dispatch_key(ua_string)
  let patterns = dict.get(compiled, key) |> result.unwrap([])

  do_parse(ua_string, patterns)
}

fn get_compiled() -> Dict(String, List(CompiledPattern)) {
  capuchin_crypt.get(cache_key)
  |> result.lazy_unwrap(fn() {
    let compiled = init_compiled()
    capuchin_crypt.put(cache_key, compiled)
  })
}

fn init_compiled() -> Dict(String, List(CompiledPattern)) {
  ua_patterns.all_buckets()
  |> list.fold(dict.new(), fn(d, bucket) {
    let #(key, patterns) = bucket
    dict.insert(d, key, compile_patterns(patterns))
  })
}

fn compile_patterns(patterns: List(UaPattern)) -> List(CompiledPattern) {
  let opts = regexp.Options(case_insensitive: False, multi_line: False)
  list.filter_map(patterns, fn(p) {
    case regexp.compile(p.regex, opts) {
      Ok(re) -> Ok(CompiledPattern(re:, pattern: p))
      Error(_) -> Error(Nil)
    }
  })
}

fn do_parse(ua_string: String, patterns: List(CompiledPattern)) -> UserAgent {
  case patterns {
    [] -> UserAgent(family: "Other", version: None)
    [cp, ..rest] ->
      case passes_pre_filter(ua_string, cp.pattern.pre_filter) {
        False -> do_parse(ua_string, rest)
        True ->
          case regexp.scan(cp.re, ua_string) {
            [] -> do_parse(ua_string, rest)
            [m, ..] -> build_ua(m.submatches, cp.pattern)
          }
      }
  }
}

fn passes_pre_filter(ua_string: String, filter: Option(String)) -> Bool {
  case filter {
    None -> True
    Some(literal) -> string.contains(ua_string, literal)
  }
}

fn build_ua(subs: List(Option(String)), p: UaPattern) -> UserAgent {
  let family = resolve_family(p.family_replacement, sub(subs, 0))
  let major = resolve_replace(p.v1_replacement, sub(subs, 1), subs)
  let minor = resolve_replace(p.v2_replacement, sub(subs, 2), subs)
  let patch = resolve_replace(p.v3_replacement, sub(subs, 3), subs)

  let version = case major {
    None -> None
    Some(maj) -> Some(Version(major: maj, minor:, patch:))
  }

  UserAgent(family:, version:)
}

fn sub(subs: List(Option(String)), idx: Int) -> Option(String) {
  case subs, idx {
    [Some(s), ..], 0 if s != "" -> Some(s)
    [_, ..rest], n if n > 0 -> sub(rest, n - 1)
    _, _ -> None
  }
}

fn resolve_family(replacement: Option(String), g1: Option(String)) -> String {
  case replacement {
    None -> option.unwrap(g1, "Other")
    Some(r) ->
      case string.contains(r, "$1") {
        True -> string.replace(r, "$1", option.unwrap(g1, "")) |> string.trim
        False -> r
      }
  }
}

fn resolve_replace(
  replacement: Option(String),
  default: Option(String),
  subs: List(Option(String)),
) -> Option(String) {
  case replacement {
    None -> default
    Some(r) -> interpolate_group(r, subs)
  }
}

fn interpolate_group(r: String, subs: List(Option(String))) -> Option(String) {
  case r {
    "$1" -> sub(subs, 0)
    "$2" -> sub(subs, 1)
    "$3" -> sub(subs, 2)
    "$4" -> sub(subs, 3)
    _ -> Some(r)
  }
}
