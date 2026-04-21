import gleam/io
import gleam/list
import gleamy/bench
import uaparser

const uas = [
  // 40% Chrome Desktop
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
  // 20% Chrome Mobile
  "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36",
  // 15% Safari Desktop
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
  // 10% Mobile Safari
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
  // 10% Firefox
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
  // 5% Other
  "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
]

pub fn main() {
  bench.run(
    [bench.Input("weighted mix (10 UAs)", uas)],
    [
      bench.Function("parse", fn(uas) {
        list.each(uas, uaparser.parse_user_agent)
        Nil
      }),
    ],
    [bench.Duration(2000), bench.Warmup(500)],
  )
  |> bench.table([bench.IPS, bench.Min, bench.P(50), bench.P(99)])
  |> io.println()
}
