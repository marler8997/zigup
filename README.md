# zigup

Download and manage zig compilers.

# Usage

```
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

zigup stores each compiler in a global "install directory" in a versioned subdirectory.  On posix systems the "install directory" is `$HOME/zig` and on windows the install directory will be a directory named "zig" in the same directory as the "zigup.exe".

zigup makes the zig program available by creating an entry in a directory that occurs in the `PATH` environment variable.  On posix systems this entry is a symlink to one of the `zig` executables in the install directory.  On windows this is an executable that forwards invocations to one of the `zig` executables in the install directory.

Both the "install directory" and "path link" are configurable through command-line options `--install-dir` and `--path-link` respectively.
# Building

Run `zig build` to build, `zig build test` to test and install with:
```
# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```

# TODO

* set/remove compiler in current environment without overriding the system-wide version.

# Dependencies

The windows target depends on https://github.com/SuperAuguste/zarc to extract zip files.  This repo might point to my fork if there are needed changes pending the acceptance of a PR: https://github.com/marler8997/zarc.

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).
