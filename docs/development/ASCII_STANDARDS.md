# ASCII Icon Standards

Bracketed ASCII tags replace emojis throughout the codebase. Keeps output professional and grep-friendly.

## Patterns

### Status
- `[OK]`: success, completed
- `[WARN]`: warning
- `[ERROR]`: error
- `[CRIT]`: critical
- `[INFO]`: informational

### Actions
- `[EDIT]`: edit
- `[DEL]`: delete
- `[SAVE]`: save
- `[LOAD]`: load
- `[COPY]`: copy

### System
- `[SYS]`: system
- `[CPU]`: CPU
- `[MEM]`: memory
- `[DISK]`: disk
- `[NET]`: network

### UI Components
- `[BTN]`: button
- `[FORM]`: form
- `[TEXT]`: text
- `[DATA]`: data display
- `[CHART]`: chart/graph
- `[NAV]`: navigation

### Development
- `[TEST]`: testing
- `[BENCH]`: benchmarking
- `[PERF]`: performance
- `[BUILD]`: build process

### Workflow
- `[ANALYSIS]`: analysis
- `[REPORT]`: report generation
- `[REGR]`: regression
- `[IMPR]`: improvement

## Rules

1. Uppercase inside brackets.
2. Keep tags short: 3-6 characters.
3. Descriptive but concise.
4. Consistent across the codebase.
5. Functional, not decorative.

## Example

Before:
```
[rocket] Running benchmarks...
[check] Tests passed
[warning] Warning: Memory usage high
[fire] Performance critical
```

After:
```
[BENCH] Running benchmarks...
[OK] Tests passed
[WARN] Memory usage high
[CRIT] Performance critical
```
