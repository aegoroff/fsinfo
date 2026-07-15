# fsinfo

A non-interactive file system information tool implemented in Zig.

## Description

`fsinfo` analyzes a given directory path and provides statistics about the file system:
- Total number of files
- Total number of directories
- Total size of all files (sum of sizes per directory entry; hard-linked names are counted separately)
- Time taken for the analysis

The tool automatically excludes system directories like `/proc`, `/dev`, and `/sys` during scanning and provides progress updates during the analysis. Directory symlinks are not followed.

## Requirements

- [Zig](https://ziglang.org/) **0.16.0** (pinned in [`mise.toml`](mise.toml); use [mise](https://mise.jdx.dev/) or install that version manually)

## Building

### Standard Build

```bash
zig build
```

The executable will be placed in `zig-out/bin/fsinfo`.

### Cross-Platform Build

The project includes build scripts for multiple platforms:

```bash
# Build for all platforms
./build_all_zig.sh

# Build for Linux only
./linux_build_zig.sh
```

### Build Options

- `--version`: Specify the version of the app (default: `0.2.0-dev`)
- `--optimize`: Optimization level (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)

Example:
```bash
zig build -Dversion=0.2.0 -Doptimize=ReleaseSafe
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
| `-j`, `--jobs N` | Parallel directory-walk workers. Default: half the logical CPU count (at least 1). Use `-j 1` for single-threaded. |

### Examples

```bash
# Analyze current directory (default: half the CPU count)
fsinfo .

# Force single-threaded scan
fsinfo --jobs 1 .

# Analyze root filesystem (excluding /proc, /dev, /sys)
fsinfo /
```

### Output Format

The tool outputs:
- Total files count
- Total directories count
- Total files size (in human-readable format and bytes)
- Time taken for the analysis

Example output:
```
Total files:        12345
Total directories: 567
Total files size:   1.23 GiB (1320701952 bytes)
Time taken:         2.5s
```

## Features

- Fast file system traversal with optional parallel directory walk (`--jobs`)
- Progress indicators for files and directories
- Automatic exclusion of system directories (`/proc`, `/dev`, `/sys`)
- Does not follow directory symlinks; does not cross into excluded system trees
- Total size is a per-entry sum (not unique inode bytes)
- Human-readable file size formatting
- Cross-platform support (Linux, macOS, Windows)

## License

MIT License - see [LICENSE](LICENSE.txt) file for details.

## Copyright

Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
