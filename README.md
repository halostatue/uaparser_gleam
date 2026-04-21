# `uaparser_gleam`

[![Hex.pm][shield-hex]][hexpm] [![Hex Docs][shield-docs]][docs]
[![Apache 2.0][shield-licence]][licence] ![Erlang Compatible][shield-erl]
![JavaScript Compatible][shield-js]

- code :: <https://github.com/halostatue/uaparser_gleam>
- issues :: <https://github.com/halostatue/uaparser_gleam/issues>

`uaparser` is a User Agent parser implementation generated from the
[BrowserScope][browserscope] collection of [core regular expressions][uap-core].
This is _primarily_ generated code from the regular expressions, including unit
tests.

## Installation

```sh
gleam add uaparser_gleam@1
```

```gleam
import uaparser

pub fn main() {
  let ua = uaparser.parse_user_agent(
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  )
  // ua.family == "Chrome"
  // ua.version == Some(Version(major: "120", minor: Some("0"), patch: Some("0")))
}
```

Further documentation can be found at <https://hexdocs.pm/uaparser_gleam>.

## Development

The parser code is generated from [ua-parser/uap-core][uap-core] regular
expressions. The `uap-core` repository must be cloned locally before running the
generator.

A [Justfile](https://just.systems/) is provided for common tasks:

```sh
just generate  # Clone uap-core (if needed) and regenerate parser + tests
just test      # Generate and run tests on both Erlang and JavaScript targets
just bench     # Run benchmarks
```

Or manually:

```sh
git clone https://github.com/ua-parser/uap-core.git uap-core
gleam run -m generate_uaparser  # Generate uaparser from ua-parser/uap-core
gleam test                      # Run the tests
```

## Optimizations

There are two optimizations implemented in `uaparser` to improve performance of
User Agent parsing.

The first is to compile and cache all of the regular expressions (there are 431
regular expressions in `uap-core` in April 2026). This shows a 2.2–2.4x
improvement on a weighted benchmark[^1] over ten User Agent strings. On
individual User Agent patterns benchmarks[^2], it shows as much as 3x
improvement.

The second is to use predictive dispatching to reduce the number of regular
expressions that must be matched for resolution in the typical cases. With at
most three string containment tests, the number of regular expressions that must
be tested for a match is reduced by a significant fraction, as shown by the
pseudo-Typescript below.

```typescript
function find_ua(ua: string) {
  if (ua.includes("Chrome/")) {
    if (ua.includes(" Mobile")) {
      return chrome_mobile.find(ua); // 88 patterns
    }

    return chrome_desktop.find(ua); // 127 patterns
  }

  if (ua.includes("Firefox/")) {
    return firefox.find(ua); // 120 patterns
  }

  if (ua.includes("Safari/")) {
    return safari.find(ua); // 155 patterns
  }

  return other.find(ua); // 290 patterns
}
```

The total above is larger than 431 because some patterns are in both buckets as
backstop patterns.

| 10 Mixed UAs      | Naive    | Dispatch   |
| ----------------- | -------- | ---------- |
| Erlang (uncached) | ~95 IPS  | ~170 IPS   |
| Erlang (cached)   | ~205 IPS | ~305 IPS   |
| Node (uncached)   | ~360 IPS | ~915 IPS   |
| Node (cached)     | ~860 IPS | ~2,215 IPS |

| UA Type         | Runtime           | Naive       | Dispatch    |
| --------------- | ----------------- | ----------- | ----------- |
| Chrome Desktop  | Erlang (uncached) | ~905 IPS    | ~1,575 IPS  |
|                 | Erlang (cached)   | ~1,955 IPS  | ~2,830 IPS  |
|                 | Node (uncached)   | ~3,270 IPS  | ~8,915 IPS  |
|                 | Node (cached)     | ~9,385 IPS  | ~16,575 IPS |
| Chrome Mobile   | Erlang (uncached) | ~1,120 IPS  | ~2150 IPS   |
|                 | Erlang (cached)   | ~2,170 IPS  | ~3,594 IPS  |
|                 | Node (uncached)   | ~4,800 IPS  | ~13,015 IPS |
|                 | Node (cached)     | ~12,590 IPS | ~30,510 IPS |
| Safari Desktop  | Erlang (uncached) | ~705 IPS    | ~1,330 IPS  |
|                 | Erlang (cached)   | ~1,650 IPS  | ~2,390 IPS  |
|                 | Node (uncached)   | ~2,815 IPS  | ~7,390 IPS  |
|                 | Node (cached)     | ~6,525 IPS  | ~16,430 IPS |
| Mobile Safari   | Erlang (uncached) | ~695 IPS    | ~1,275 IPS  |
|                 | Erlang (cached)   | ~1,410 IPS  | ~2,070 IPS  |
|                 | Node (uncached)   | ~2,950 IPS  | ~7,940 IPS  |
|                 | Node (cached)     | ~6,950 IPS  | ~17,770 IPS |
| Firefox Desktop | Erlang (uncached) | ~830 IPS    | ~2,130 IPS  |
|                 | Erlang (cached)   | ~2,405 IPS  | ~4,190 IPS  |
|                 | Node (uncached)   | ~2,840 IPS  | ~11,285 IPS |
|                 | Node (cached)     | ~6,940 IPS  | ~27,010 IPS |
| Unknown/Other   | Erlang (uncached) | ~860 IPS    | ~1,205 IPS  |
|                 | Erlang (cached)   | ~3,285 IPS  | ~3,850 IPS  |
|                 | Node (uncached)   | ~2,820 IPS  | ~4,820 IPS  |
|                 | Node (cached)     | ~7,190 IPS  | ~11,310 IPS |
| Google bot      | Erlang (uncached) | ~3,235 IPS  | ~3,406 IPS  |
|                 | Erlang (cached)   | ~7,305 IPS  | ~7,184 IPS  |
|                 | Node (uncached)   | ~9,970 IPS  | ~12,210 IPS |
|                 | Node (cached)     | ~50,585 IPS | ~58,365 IPS |

## Regular Expression Sanitization

The `uap-core` regular expression patterns are written for PCRE (Perl Compatible
Regular Expressions), which is permissive about unnecessary escape sequences.
For example, `\!` is treated as a literal `!` and `\-` outside a character class
is treated as a literal `-`.

Gleam's `gleam_regexp` package compiles regular expressions on JavaScript with
the ECMAScript `u` (Unicode) flag. In Unicode mode, the JavaScript regex engine
rejects unrecognized escape sequences as syntax errors rather than silently
treating them as literals.

The regular expression compile failures caused by this resulted in 49 of the
generated unit tests failing under every JavaScript engine supported by Gleam.

### What We Change

The generator (`dev/generate_uaparser.gleam`) applies a regular expression
sanitization function (`sanitize_regex`) to every pattern before emitting it in
the generated code. This function strips unnecessary backslash characters from
escape sequences resulting in invalid JavaScript regular expressions in Unicode
mode:

- `\!` → `!` (everywhere)
- `\-` → `-` (only outside `[...]` character classes; `\-` inside a character
  class is valid and preserved)

### Semantic Impact

In PCRE and in JavaScript non-Unicode mode, `\!` and `!` are identical — the
backslash is a no-op. The sanitization does not change what any pattern matches.
However, the emitted regex strings differ from the upstream `uap-core` source,
so a visual or byte comparison of the generated patterns against `regexes.yaml`
will show differences in these 4 patterns:

| Pattern # | Original                               | Sanitized                             |
| --------- | -------------------------------------- | ------------------------------------- |
| 61        | `[A-Za-z0-9 \-_\!\[\]:]{0,50}`         | `[A-Za-z0-9 \-_!\[\]:]{0,50}`         |
| 256       | `\b(Dolphin)(?: \|HDCN/\|/INT\-)(...)` | `\b(Dolphin)(?: \|HDCN/\|/INT-)(...)` |
| 336       | `(Obigo)\-Browser`                     | `(Obigo)-Browser`                     |
| 387       | `(SEMC\-Browser)/(...)`                | `(SEMC-Browser)/(...)`                |

### Maintenance

If `uap-core` introduces patterns with other unnecessary escapes, the
`is_invalid_escape` function in the generator must be updated. The full set of
characters whose escapes are invalid in JavaScript's Unicode mode:

```
! @ # % & = : < > { } ~ ` , ;
```

The `-` character is a special case: `\-` is valid inside `[...]` but invalid
outside.

[^1]: Found in `dev/benchmark_weighted.gleam`.

[^2]: Found in `dev/benchmark.gleam`.

[^3]: The naive implementation and the uncached implementation have been removed
    to prevent unnecessary code from shipping. The implementations were restored
    after having implemented both the caching and the dispatch mechanism.

[browserscope]: http://www.browserscope.org/
[docs]: https://hexdocs.pm/uaparser_gleam
[hexpm]: https://hex.pm/package/uaparser_gleam
[licence]: https://github.com/halostatue/uaparser_gleam/blob/main/LICENCE.md
[semver]: https://semver.org/
[shield-docs]: https://img.shields.io/badge/hex-docs-lightgreen.svg?style=for-the-badge "Hex Docs"
[shield-erl]: https://img.shields.io/badge/target-erlang-f3e155?style=for-the-badge "Erlang Compatible"
[shield-hex]: https://img.shields.io/hexpm/v/uaparser_gleam?style=for-the-badge "Hex Version"
[shield-js]: https://img.shields.io/badge/target-javascript-f3e155?style=for-the-badge "JavaScript Compatible"
[shield-licence]: https://img.shields.io/hexpm/l/uaparser_gleam?style=for-the-badge&label=licence "Apache 2.0"
[uap-core]: https://github.com/ua-parser/uap-core
