# Review context

The implementation agent was Codex. Claude Sonnet provided external review passes. The statement about the builder and reviewer sharing a model family in `review-third.json` is incorrect; the raw report is preserved unchanged. The roles are also shown in `../recovery-evidence.html`.

The isolation calculation is retained in `analyze.py --isolation`. It validates identical native binary hashes and compares matching 5–35 second windows. The initial matched observation has 90 samples per window and a 14.6% p95 increase. It is a single-pair point estimate, with no statistical guarantee.

The original five-minute high-rate runs failed the memory target. The controlled variants, heap summary and failed profiling run are retained alongside the corrected main-build evidence. Heap instrumentation results are diagnostic evidence, not uninstrumented acceptance measurements.

Native GUI startup, cleanup, keyboard and geometry changes have static review and compilation evidence. They remain unexecuted until GUI opt-in is granted. No review report constitutes native GUI or production acceptance.
