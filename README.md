# zigup

Download and manage zig compilers.

# How to Install

Go to https://marler8997.github.io/zigup and select your OS/Arch to get a download link and/or instructions to install via the command-line.

Otherwise, you can manually find and download/extract the applicable archive from [Releases](https://github.com/marler8997/zigup/releases). It will contain a single static binary named `zigup`, unless you're on Windows in which case it's 2 files, `zigup.exe` and `zigup.pdb`.

# Usage

```sh
# fetch a compiler and set it as the default
zigup <version>
zigup master
zigup 0.6.0

# fetch a compiler only (do not set it as default)
zigup fetch <version>
zigup fetch master

# print the default compiler version
zigup default

# set the default compiler
zigup default <version>

# set the default compiler from a path
zigup default zig/build

# unset the default compiler (for using a global installation)
zigup undefine

# list the installed compiler versions
zigup list

# clean compilers that are not the default, not master, and not marked to keep. when a version is specified, it will clean that version
zigup clean [<version>]

# mark a compiler to keep
zigup keep <version>

# run a specific version of the compiler
zigup run <version> <args>...
```

# How the compilers are managed

`zigup` stores each compiler in `$ZIGUP_INSTALL_DIR`, in a versioned subdirectory. The default install directory is `$HOME/.zigup/cache`.

`zigup` makes the zig available by creating a symlink at `$ZIGUP_INSTALL_DIR/<version>` and `$ZIGUP_DIR/default` which points to the current active default compiler.

Configuration on done during the first use of zigup and the generated environment is installed at `$ZIGUP_DIR/env`.

# Building

Run `zig build` to build, `zig build test` to test and install with:
```
# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```

# Building Zigup

Zigup is currently built/tested using zig 0.13.0+.

# TODO

- [ ] Download to memory
- [ ] Use `std.tar` (Unix)

# Dependencies

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).
