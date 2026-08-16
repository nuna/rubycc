# Corpus candidate source-error replay

Status: complete (2026-08-16)

The 14-day replay (2026-08-02 through 2026-08-16 UTC) used scanner revision
`5f6fc6d40a68aca89fc37ad1c530eeaeb41a7c48`. Each day was executed as an
independent one-day window. The raw Actions artifacts remain under the ignored
`artifacts/` work prefix; the reproducible inputs and compact output are
`source-errors-replay-manifest.json`, `source-errors-replay-runs.json`, and
`source-errors-replay-metrics.json`.

## Replay result

| Measure | Result | Target/interpretation |
| --- | ---: | --- |
| Completed windows | 14 / 14 | No window was missing from the replay denominator |
| Window failure rate | 0.0000 | Target was below 5% |
| Timeout windows | 0 | Target was 0 |
| Wall-time p95 | 129.751 s | Target was 900 s |
| Unique gem occurrences | 4,494 | Same 14-day source volume as the original pilot |

## Error separation

| Classification | Count | Rate of all records |
| --- | ---: | ---: |
| Source error: `v2_metadata_404` | 575 | 12.7948% |
| Source errors: other four statuses | 0 | 0.0000% |
| Record-processing `error` | 134 | 2.9818% |
| Total failed records | 709 | 15.7766% |

The original pilot reported all 709 failed records as `error`. The replay
shows that the same total is now split into 575 source errors and 134
record-processing errors; source failures no longer inflate the candidate,
`no_ext`, or processing-error categories. The source-error rate is calculated
over records in successful windows, while window failures use the 14-window
denominator.

All 575 source errors were `v2_metadata_404`. The daily distribution was
stable at 0–11 errors for 13 days, followed by 501 errors on 2026-08-15. This
spike is evidence of an upstream metadata-availability event and should be
monitored separately from scanner correctness.

## Corpus-expansion signal

After the fixed corpus and popular-gem controls were applied, the replay
produced 251 eligible candidate occurrences from 200 unique gem names (51
cross-window duplicates). The fixed static-selection rule selected three
records for inspection:

- `rbtrace` 0.5.5
- `graphql-c_parser` 1.1.4
- `roaring` 0.4.1

All three are outside the current corpus and the fixed popular control. This
demonstrates that the source-error-aware pipeline still produces a usable
candidate pool; it does not by itself approve adding these gems. The local
`inspect-corpus-candidate` skill and the manual upstream-recipe validation
remain the acceptance boundary for corpus changes.

The attempted two-day-window experiment was excluded because the existing
workflow is intentionally one-day based and the issue is evaluated using
independent daily windows. Canceled bulk-dispatch runs and the failed input
validation run are also excluded; none is present in the replay registry or
denominator.
