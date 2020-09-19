# zigup

Download and manage zig compilers.

# Commands

```
# fetch compiler and set it as the default
zigup latest
zigup <version>

# fetch compiler
zigup fetch latest
zigup fetch <version>

# get the default compiler version
zigup default

# set the default compiler
zigup default <version>

# list the installed compiler versions
zigup list
```

# Configuration

Things that a user may want to configure

* Install Directory (where zig compilers get installed to)
* Zig Path Symlink
    - on posix, the symlink that lives in a `PATH` directory that points to the default compiler
    - on windows, the batch file that lives in a `PATH` directory that calls forwards calls to the default compiler executable

I may support one or more configuration files.  Possibly a file that lives alongside the executable, or in the user's home directory, possibly both.

On Linux/Bsd/Mac (which I will call "Posix" systems) the default install location is `$HOME/zig`.  Not sure what default directory to use for windows yet, maybe `%APPDATA%\zig`.  This directory will contain a unique sub-directory for every version of the compiler that is installed on the system.  When a new compiler is installed, this tool will also add some scripts that will modify an environment to use that version of the zig compiler.

One compiler will be set as the "default" by linking a symlink or batch file to one of the compiler executables that have been installed. On Posix systems this will be a symlink named `zig` in a `PATH` directory that points to one of the `zig` executables.  On windows this will be a batch file named `zig.bat` in a `PATH` directoty that calls one of the `zig` executables.

# Operations

My breakdown of the operations I'd like.

* download latest compiler (`zigup fetch latest`)
* download specific compiler (`zigup fetch <version>`)
* list all compilers (`zigup list`)
* set/get the default compiler (sets the link/script in PATH) (`zigup default` and `zigup default <version>`)
* set/clear the "keep" flag on a compiler.  Each keep flag can also have a note explaining why it's being kept.
* clean (cleans compilers without the "keep" flag and aren't the default)
* set/remove compiler in current environment. Probably require creating a bash/batch script that the user could source for each installed compiler.

* download zig index file (`zigup fetch-index`)

I think to manage compilers, users can mark them as "keep".  The tool will "keep" all compilers marked as "keep" and also the default compiler. I could probably just create an empty file called "keep" to make that mark.

> NOTE: by default `zigup list` should display more information, like release date, its "keep" value, etc.  Maybe it should also sort them, probably by release date?

# Building

* Depends on https://github.com/marler8997/ziget.  `build.zig` assumes it exists alongside this repository.
* Currently depends on openssl.  On linux make sure your environment is able to find openssl.  On windows, see https://github.com/marler8997/ziget#openssl-on-windows
* On linux, uses `tar` to extract archives

```
zig build

# install to a bin directory with
cp zig-cache/bin/zigup BIN_PATH
```
