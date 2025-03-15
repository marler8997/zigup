# zigup

Download and manage zig compilers.

# Zigup Transition to Anyzig

I personally no longer use zigup and now use "anyzig" instead (see https://github.com/marler8997/anyzig). The difference between them is that zigup helps the user manage multiple zig versions themselves whereas anyzig relies on each individual project to declare which version of zig it requires. Anyzig provides a single universal zig executable meant to be installed system-wide that works with any version of zig.

Zigup will continue to be supported, however, new feature efforts will focus on anyzig instead. If you have a use case that zigup supports that anyzig doesn't please open an issue there.

# How to Install

Go to https://marler8997.github.io/zigup and select your OS/Arch to get a download link and/or instructions to install via the command-line.

Otherwise, you can manually find and download/extract the applicable archive from [Releases](https://github.com/marler8997/zigup/releases). It will contain a single static binary named `zigup`, unless you're on Windows in which case it's `zigup.exe`.

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

zigup stores each compiler in a global "install directory" in a versioned subdirectory.  On posix systems the "install directory" is `$HOME/.local/share/zigup` (or `$XDG_DATA_HOME/zigup`; see below) and on windows the install directory will be a directory named "zig" in the same directory as the "zigup.exe".

zigup makes the zig program available by creating an entry in a directory that occurs in the `PATH` environment variable.  On posix systems this entry is a symlink to one of the `zig` executables in the install directory.  On windows this is an executable that forwards invocations to one of the `zig` executables in the install directory.

Both the "install directory" and "path link" are configurable through command-line options `--install-dir` and `--path-link` respectively.  On posix systems the default "install directory" follows the [XDG basedir spec](https://specifications.freedesktop.org/basedir-spec/latest/#variables), ie. `$XDG_DATA_HOME/zigup` or `$HOME/.local/share/zigup` if `XDG_DATA_HOME` environment variable is empty or undefined.
# Building

Run `zig build` to build, `zig build test` to test and install with:
```
# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```

# TODO

* set/remove compiler in current environment without overriding the system-wide version.

# Dependencies

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).
