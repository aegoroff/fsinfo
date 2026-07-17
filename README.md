# fsinfo

A non-interactive file system information tool implemented in Zig.

## Description

`fsinfo` analyzes a given directory path and provides statistics about the file system:
- Total number of files
- Total number of directories
- Total size of all files (sum of sizes per directory entry; hard-linked names are counted separately)
- Time taken for the analysis
- Optional file-size histogram (`--histogram`)

The tool automatically excludes system directories like `/proc`, `/dev`, and `/sys` during scanning, as well as any `tmpfs` mounts on Linux (typically `/run`, `/tmp`, `/dev/shm`), and provides progress updates during the analysis. Directory symlinks are not followed. If `PATH` itself is one of those directories (or lies inside them), `fsinfo` refuses to scan and exits with an error.

## Requirements

- [Zig](https://ziglang.org/) **0.16.0** and [just](https://github.com/casey/just) (both pinned in [`mise.toml`](mise.toml); use [mise](https://mise.jdx.dev/) or install them manually)

## Building

### Standard Build

```bash
zig build
```

The executable will be placed in `zig-out/bin/fsinfo`.

### Cross-Platform Build

Use [just](https://github.com/casey/just) (pinned in [`mise.toml`](mise.toml)):

```bash
# Local ReleaseFast build / tests (x86_64-linux-musl)
just build
just test

# One release target (build + archive; tests on x86_64-linux)
just arch=x86_64 os=linux abi=musl ver=0.3.0 cpu=core2 release

# All CI release targets
just ver=0.3.0 build-all
```

### Build Options

- `--version`: Specify the version of the app (default: `0.3.0-dev`)
- `--optimize`: Optimization level (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)

Example:
```bash
zig build -Dversion=0.3.0 -Doptimize=ReleaseSafe
```

### Running Tests

```bash
zig build test
```

### Creating Archive

```bash
zig build archive
```

This creates a tar.gz archive in the output directory.

## Usage

```bash
fsinfo [OPTIONS] <PATH>
```

| Option | Description |
|--------|-------------|
| `-j`, `--jobs N` | Parallel directory-walk workers. Default: half the logical CPU count (at least 1). Must be between 1 and 128 (or the CPU count if higher). Use `-j 1` for single-threaded. |
| `-v`, `--verbose` | Log skipped entries to stderr (`std.log.warn`): permission errors, failed `openDir`/`statFile`, allocation failures, and similar silent skips. Off by default. |
| `--histogram` | Print a file-size histogram (10 size ranges with count, bytes, and percentages). Off by default. |
| `-h`, `--help` | Print help and exit. |

### Examples

```bash
# Analyze current directory (default: half the CPU count)
fsinfo .

# Force single-threaded scan
fsinfo --jobs 1 .

# Show why entries were skipped during the walk
fsinfo -v /

# File-size histogram plus summary totals
fsinfo --histogram .

# Analyze root filesystem (excluding /proc, /dev, /sys, and tmpfs mounts)
fsinfo /

# These fail: PATH itself is under a default exclusion
# fsinfo /proc
# fsinfo /sys
# fsinfo /run   # tmpfs on typical systemd hosts
```

### Output Format

By default the tool prints a summary:
- Total files and directories (with thousands separators for large counts, e.g. `1,234,567`)
- Total files size (human-readable and raw bytes)
- Time taken for the analysis

Example summary:
```
Total files:        12,345
Total directories:  567
Total files size:   1.23GiB (1320701952 bytes)
Time taken:         2.5s
```

With `--histogram`, a size-range table is printed before the summary:

```
File size histogram:
╭────┬──────────────────┬───────┬─────────┬──────────┬─────────╮
│  # │ File size        │ Count │       % │     Size │       % │
├────┼──────────────────┼───────┼─────────┼──────────┼─────────┤
│  1 │ 0 B - 100 KiB    │ 7,890 │  63.91% │  45.2MiB │   3.50% │
│  2 │ 100 KiB - 1 MiB  │ 2,100 │  17.01% │ 812.0MiB │  62.80% │
│  … │ …                │     … │       … │        … │       … │
│ 10 │ 10 TiB+          │     0 │   0.00% │       0B │   0.00% │
╰────┴──────────────────┴───────┴─────────┴──────────┴─────────╯

Total files:        12,345
…
```

## Features

- Fast file system traversal with optional parallel directory walk (`--jobs`)
- Optional file-size histogram (`--histogram`)
- Optional verbose logging of skipped entries (`--verbose`)
- Progress indicators for files and directories
- Automatic exclusion of system directories (`/proc`, `/dev`, `/sys`) and Linux `tmpfs` mounts
- Does not follow directory symlinks; does not cross into excluded system trees
- Total size is a per-entry sum (not unique inode bytes)
- Human-readable sizes and thousands-separated counts
- Cross-platform support (Linux, macOS, Windows)

## License

MIT License - see [LICENSE](LICENSE.txt) file for details.

## Copyright

Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
