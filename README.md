# fsinfo

A non-interactive file system information tool implemented in Zig.

## Description

`fsinfo` analyzes a given directory path and provides statistics about the file system:
- Total number of files
- Total number of directories
- Total size of all files
- Time taken for the analysis

The tool automatically excludes system directories like `/proc`, `/dev`, and `/sys` during scanning and provides progress updates during the analysis.

## Requirements

- [Zig](https://ziglang.org/) compiler (latest stable version)

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

- `--version`: Specify the version of the app (default: `0.1.0-dev`)
- `--optimize`: Optimization level (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)

Example:
```bash
zig build -Dversion=0.1.0 -Doptimize=ReleaseSafe
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
fsinfo <PATH>
```

### Examples

```bash
# Analyze current directory
fsinfo .

# Analyze a specific directory
fsinfo /home/user/documents

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

- Fast file system traversal
- Progress indicators for files and directories
- Automatic exclusion of system directories (`/proc`, `/dev`, `/sys`)
- Human-readable file size formatting
- Cross-platform support (Linux, macOS, Windows)

## License

MIT License - see [LICENSE](LICENSE.txt) file for details.

## Copyright

Copyright (C) 2025 Alexander Egorov. All rights reserved.
