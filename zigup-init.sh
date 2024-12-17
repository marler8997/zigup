#!/bin/sh

ZIGUP_UPDATE_ROOT="https://github.com/marler8997/zigup/releases/latest/download"
ZIGUP_DIR="${HOME}/.zigup"

main() {
    downloader --check
    need_cmd uname
    need_cmd unzip
    need_cmd wget
    need_cmd mkdir
    get_architecture || return 1
    local _arch="$RETVAL"
    local _artifact="zigup.${_arch}.zip"
    local _url="${ZIGUP_UPDATE_ROOT}/${_artifact}"

    say "downloading installer"

    ensure mkdir -p $ZIGUP_DIR/bin
    ensure downloader $_url $ZIGUP_DIR/$_artifact
    ensure unzip -q -u $ZIGUP_DIR/$_artifact -d $ZIGUP_DIR/bin
    ensure chmod u+x $ZIGUP_DIR/bin/zigup
    ensure rm $ZIGUP_DIR/$_artifact

    setup_env
    post_install_info
}

post_install_info() {
    printf '%s' "
Welcome to Zig!

Zigup will be installed into the Zigup home directory located at:

  ${HOME}/.zigup/bin

To specify install directory for the compilers

  alias zigup=\"zigup --install-dir ${HOME}/.zigup/compilers\"

This path will be added to your PATH environment variable and
this alias will be invoked by modifying the following files

  ${HOME}/.profile"

    if check_cmd zsh; then
        printf '%s' "
  ${HOME}/.zshenv
"
    fi
}

setup_env() {
    local _envurl="https://raw.githubusercontent.com/FabricatorZayac/zigup-init/main/env"
    local _envstr='. "$HOME/.zigup/env"'

    ensure downloader $_envurl $ZIGUP_DIR/env

    if ! grep -Fxq "$_envstr" $HOME/.profile; then
        printf '%s\n' "$_envstr" >> $HOME/.profile
    fi
    if check_cmd zsh; then
        if ! grep -Fxq "$_envstr" $HOME/.zshenv; then
            printf '%s\n' "$_envstr" >> $HOME/.zshenv
        fi
    fi
}

downloader() {
    local _dld
    local _status
    local _err
    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget' # to be used in error message of need_cmd
    fi

    if [ "$1" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        _err=$(curl $_retry --proto '=https' --silent --show-error --fail --location "$1" --output "$2" 2>&1)
        _status=$?

        if [ -n "$_err" ]; then
            echo "$_err" >&2
            if echo "$_err" | grep -q 404$; then
                err "installer not found"
            fi
        fi
        return $_status
    elif [ "$_dld" = wget ]; then
        _err=$(wget --https-only --secure-protocol=TLSv1_2 "$1" -O "$2" 2>&1)
        _status=$?
        if [ -n "$_err" ]; then
            echo "$_err" >&2
            if echo "$_err" | grep -q ' 404 Not Found$'; then
                err "installer not found"
            fi
        fi
        return $_status
    fi
}

say() {
    printf 'zigup: %s\n' "$1"
}

err() {
    say "$1" >&2
    exit 1
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

get_architecture() {
    local _ostype _cputype _bitness _arch
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"

    if [ "$_ostype" = Darwin ] && [ "$_cputype" = i386 ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype=x86_64
        fi
    fi

    case "$_ostype" in

        Linux)
            _ostype=ubuntu
            ;;

        Darwin)
            _ostype=macos
            ;;

        *)
            err "unrecognized OS type: $_ostype"
            ;;

    esac

    case "$_cputype" in

        aarch64 | arm64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        *)
            err "unknown CPU type: $_cputype"

    esac

    _arch="${_ostype}-latest-${_cputype}"

    RETVAL="$_arch"
}

main "$@" || exit 1
