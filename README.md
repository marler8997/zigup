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

## Directly on your host

Run `zig build` to build, `zig build test` to test and install with:
```
# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```

## Through Docker

```bash
# Build for the default target (x86_64-linux)
docker build -t zigup .
# Or specify a custom target through ZIGUP_TARGET
# docker build -t zigup --build-arg ZIGUP_TARGET=macos-x86_64 .

# Copy zigup from the Docker image to your host
container="$(docker container create zigup)"
docker container cp "$container":/zigup/zig-out/bin/zigup .
docker container rm "$container"

# Use zigup  
./zigup --help
```

# TODO

* set/remove compiler in current environment without overriding the system-wide vesrion.

# Dependencies

zigup depends on https://github.com/marler8997/ziget which in turn depends on other projects depending on which SSL backend is selected.  You can provide `-Dfetch` to `zig build` to automatically clone all repository dependencies, otherwise, the build will report a missing dependency error with an explanation of how to clone it.

The windows target depends on https://github.com/SuperAuguste/zarc to extract zip files.  This repo might point to my fork if there are needed changes pending the acceptance of a PR: https://github.com/marler8997/zarc.

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).
