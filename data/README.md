# data/ — repository-attached reference data

## verified_gems.json

The build-verified gem database `rubycc doctor` consults as its **primary
reference** before attempting any on-the-fly build. JSON carries no comments, so
the schema is documented here.

Top level is an object keyed by **gem name**. Each value is an object:

| key           | type            | meaning |
|---------------|-----------------|---------|
| `versions`    | array of string | Verified version strings (e.g. `"2.21.1"`) or version ranges (e.g. `">= 1.8, < 2"`). A gem at one of these versions is reported as **verified** without a build. |
| `verified_at` | string `YYYY-MM-DD` | Date the verification was recorded. |
| `environment` | string          | The environment the verification held in, e.g. `"glibc x86_64 / ruby 3.4.5"`. |
| `evidence`    | string          | How it was confirmed — which rubycc step/test proved it (e.g. the gem's own test suite passing). |
| `notes`       | string          | Known caveats (flags needed, platforms not yet covered, etc.). Empty string if none. |

### Version matching

`versions` entries are matched against a gem's resolved version with RubyGems'
own requirement grammar (`Gem::Requirement`): an exact string like `"2.21.1"`
matches only that version, and a range like `">= 1.8, < 2"` matches any version
inside it. A gem is **verified** when its version satisfies at least one entry.

### What may be added here

Only versions that were **actually built and exercised in this repository** — the
initial data is `json 2.21.1` and `msgpack 1.8.3`, both of which built with
rubycc and passed their own upstream test suites (Step 54, re-confirmed via the
in-process rmake build in Step 61 and the hermetic gem install in Step 64). The
intended long-term flow is to generate/extend this file from the corpus CI
results (ROADMAP H3) rather than hand-editing it.
