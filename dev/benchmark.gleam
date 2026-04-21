import gleam/io
import gleamy/bench
import uaparser

pub fn main() {
  bench.run(
    [
      bench.Input(
        "Chrome Desktop",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      ),
      bench.Input(
        "Chrome Mobile",
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
      ),
      bench.Input(
        "Safari Desktop",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
      ),
      bench.Input(
        "Mobile Safari",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
      ),
      bench.Input(
        "Firefox Desktop",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
      ),
      bench.Input("Unknown/Other", "SomethingWeNeverKnewExisted"),
      bench.Input(
        "Googlebot",
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      ),
    ],
    [
      bench.Function("parse", fn(ua) {
        let _ = uaparser.parse_user_agent(ua)
        Nil
      }),
    ],
    [bench.Duration(2000), bench.Warmup(500)],
  )
  |> bench.table([bench.IPS, bench.Min, bench.P(50), bench.P(99)])
  |> io.println()
}
