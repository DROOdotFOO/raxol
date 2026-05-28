# Performance Targets

Current performance measurements and goals for Raxol.

## Measured Results

| Metric             | Target    | Measured        | Status   |
| ------------------ | --------- | --------------- | -------- |
| Parser throughput  | < 5 us/op | 0.17-1.25 us/op | Exceeded |
| Render frame time  | < 1ms     | 265-283 us      | Exceeded |
| Memory per session | < 3MB     | ~2.8MB          | Met      |
| Startup time       | < 10ms    | < 10ms          | Met      |
| Response latency   | < 2ms P99 | < 2ms           | Met      |
| Frame rate         | 60 FPS    | 60+ FPS         | Met      |
| Plugin load time   | < 15ms    | ~10ms           | Met      |

## Details

**Parser**: 0.17-1.25 us per operation, which translates to 800K-5.8M ops/sec depending on input complexity.

**Rendering**: 265-283 us per frame. That's ~3,500 FPS of headroom, well within the 60 FPS budget (16.67ms).

**Memory**: ~2.8MB per session. Roughly 350 concurrent sessions per GB of RAM.

**Startup**: Under 10ms cold start. Hot reload for component updates is under 1ms.

**Response**: Sub-2ms for all operations. Input handling is under 1ms, screen refresh under 2ms.

**Plugins**: ~10ms average load time. Message passing adds < 100us overhead. Hot reload works without downtime.

## Running Benchmarks

```bash
mix raxol.bench              # Full benchmark suite
mix raxol.bench.memory       # Memory benchmarks
```

## Optimizations Applied

**Compile-time**: static content inlining, dead code elimination, constant folding, template precompilation.

**Runtime**: buffer pooling, lazy evaluation, incremental rendering, efficient diff algorithms.

**Memory**: string interning, buffer reuse, minimal allocations, GC-friendly data structures.

## Verification

Verified through property-based tests and manual benchmarking.
