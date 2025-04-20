# zigup

Download and manage zig compilers.

> NOTE: I no longer use zigup. I've switched to using [anyzig](https://github.com/marler8997/anyzig) instead and recommend others do the same (here's [why](#why-anyzig)). Zigup will continue to be supported for those that just love it so much!

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

zigup stores each compiler in a global "install directory" in a versioned subdirectory. Run `zigup get-install-dir` to see what this PATH is on your system. You can change this default with `zigup set-install-dir PATH`.

zigup makes the zig program available by creating an entry in a directory that occurs in the `PATH` environment variable.  On posix systems this entry is a symlink to one of the `zig` executables in the install directory.  On windows this is an executable that forwards invocations to one of the `zig` executables in the install directory.

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

# Why Anyzig?

Zigup helps you download/switch which version of zig is invoked when you run `zig`. In contrast, Anyzig is one universal `zig` executable that invokes the correct version of zig based on the current project. Anyzig came about from the realization that if you have `zig` installed system-wide, then it should work with any Zig project, not just those that happen to match the current version you've installed/enabled. Instead of manually switching versions yourself, it uses the `minimum_zig_version` field in `build.zig.zon`. An added benefit of anyzig is any project that uses it is guaranteed to have their zig version both documented and up-to-date. In practice, I've also found that anyzig frees some mental load because you no longer need to track which version of Zig each project is on, which version the system is on, and keeping the two in sync.
