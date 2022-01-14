# zigup

Download and manage zig compilers.

# Commands

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
```

# Configuration

Things that a user may want to configure

* Install Directory (where zig compilers get installed to)
* Zig Path Symlink
    - on posix, the symlink that lives in a `PATH` directory that points to the default compiler
    - on windows, the batch file that lives in a `PATH` directory that calls forwards calls to the default compiler executable

I may support one or more configuration files.  Possibly a file that lives alongside the executable, or in the user's home directory, possibly both.  I've added command-line options to configure the install directory and path symlink for testing, that may be good enough because one can just wrap zigup in a script and forward those options to it.

On Linux/Bsd/Mac (which I will call "Posix" systems) the default install location is `$HOME/zig`.  Not sure what default directory to use for windows yet, maybe `%APPDATA%\zig`.  This directory will contain a unique sub-directory for every version of the compiler that is installed on the system.  When a new compiler is installed, this tool will also add some scripts that will modify an environment to use that version of the zig compiler.

One compiler will be set as the "default" by creating a symlink (or a small exe wrapper on Windows) to one of the compiler executables that have been installed. On Posix systems this will be a symlink named `zig` in a `PATH` directory that points to one of the `zig` executables.  On windows this will be a small executable in a `PATH` directory that calls one of the `zig` executables.

# Operations

My breakdown of the operations I'd like.

* download latest compiler (`zigup fetch master`)
* download specific compiler (`zigup fetch <version>`)
* list all compilers (`zigup list`)
* set/get the default compiler (sets the link/script in PATH) (`zigup default` and `zigup default <version>`)
* set/clear the "keep" flag on a compiler.  Each keep flag can also have a note explaining why it's being kept.
* clean (cleans compilers without the "keep" flag and aren't the default)
* keep a compiler (in conjunction with clean)
* set/remove compiler in current environment. Probably require creating a bash/batch script that the user could source for each installed compiler.
* setup the environment for a specific version of the compiler?

* download zig index file (`zigup fetch-index`)

> NOTE: by default `zigup list` should display more information, like release date, its "keep" value, etc.  Maybe it should also sort them, probably by release date?

# Dependencies

zigup depends on https://github.com/marler8997/ziget which in turn depends on other projects depending on which SSL backend is selected.  You can provide `-Dfetch` to `zig build` to automatically clone all repository dependencies, otherwise, the build will report a missing dependency error with an explanation of how to clone it.

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).

# Building

```
zig build

# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```
