# Performance and resource checks

Run `./script/benchmark.sh` from a macOS 14+ checkout with Command Line Tools installed. It builds the `FarPerformance` release executable, then prints a JSON report to standard output. Build messages go to standard error. Save a report with `./script/benchmark.sh > benchmark.json`.

`./script/benchmark.sh --smoke` uses 1,000 files and a 4 MiB copy for CI. The full run uses 12,000 real directory entries, natural listing and deterministically permuted sorting, literal content search across the directory (6,000 matches), byte-verified 16 and 64 MiB copies through `TransferEngine`, and an exact 1 MiB editor document with 65,536 replacements and verified save. These are production core APIs, not simulated algorithms. Correctness checks fail the executable independently of timing.

Fixtures are created in a uniquely named private temporary directory and removed on success or error. Setup and copy byte verification are excluded from individual timings. Peak RSS covers the complete process, including setup and verification; it is not isolated to an individual workload. Darwin `getrusage` reports the peak in bytes, converted to MiB. No user documents or network endpoints are accessed. Abrupt termination such as SIGKILL can leave the uniquely named `far-benchmark-*` fixture directory in the system temporary folder.

Default guardrails are 60 seconds per measured workload and 1,024 MiB process peak RSS. A breached guardrail exits nonzero. Override with `FAR_BENCH_MAX_SECONDS=10 FAR_BENCH_MAX_RSS_MIB=512 ./script/benchmark.sh`. These deliberately broad machine-dependent bounds catch gross regressions; they are not a UI latency promise. Establish tighter bounds on a fixed CI host after several runs. Compare medians of at least five runs on the same machine, OS, build mode and filesystem; include the first run separately because filesystem caches affect results. A configured time budget is checked after a workload returns, not a hard timeout.

The harness does not launch windows, exercise NSTextView layout, measure frame latency, or prove responsiveness during background activity. The panel performs additional filtering and sorting. Keep manual large-directory navigation and editor typing checks in the acceptance run. Copy results depend on filesystem, cache state and storage; source fixtures contain nonzero bytes, but OS caching and cloning optimizations are not disabled.

Production limits relevant to these tests: editor files are capped at 8 MiB; editor replacement operations permit up to 100,000 matches; search accepts at most 10,000 results and a default 16 MiB content file. Search reports oversized or unreadable content rather than silently treating it as a match.

## Recorded baseline

Measured on 2026-11-04, arm64 macOS 27.0.1 (26A434), 12 logical processors, release optimization with debug information disabled. This is one indicative run, not a multi-run median. All correctness checks and default guardrails passed. Peak process RSS: **200.48 MiB**.

| Workload | Seconds |
| --- | ---: |
| list-12000 | 0.6846 |
| sort-12000 | 0.0686 |
| content-search-12000 | 1.1797 |
| copy-16MiB | 0.0095 |
| copy-64MiB | 0.0325 |
| editor-load-1MiB | 0.0212 |
| editor-replace-65536 | 0.0164 |
| editor-save-1MiB | 0.0710 |

The Codex restricted execution environment rejected macOS coordinated editor saves; the recorded run was executed with approved access to the coordination service. The same benchmark should run directly from a normal Terminal session. No sleep, wake or removable-volume behavior was measured by this harness.
