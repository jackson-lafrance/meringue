#!/bin/sh
# Meringue installer.
#
# This clones Meringue, installs its dependencies, and adds a shim so the
# command afterwards is `meringue`.
#
#   curl -fsSL https://raw.githubusercontent.com/jackson-lafrance/meringue/main/install.sh | sh
#
# It only ever writes inside MERINGUE_HOME (default ~/.meringue) and BIN_DIR
# (default ~/.local/bin). Re-running it updates an existing checkout in place.
# Config and state live beside the source in MERINGUE_HOME and are never touched.

set -eu

REPO_URL="${MERINGUE_REPO_URL:-https://github.com/jackson-lafrance/meringue.git}"
MERINGUE_HOME="${MERINGUE_HOME:-$HOME/.meringue}"
SRC_DIR="$MERINGUE_HOME/src"
BIN_DIR="${MERINGUE_BIN_DIR:-$HOME/.local/bin}"
SHIM="$BIN_DIR/meringue"
BRANCH="${MERINGUE_BRANCH:-main}"

die() {
  printf '\nmeringue: %s\n' "$1" >&2
  exit 1
}

note() { printf '  %s\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH. $2"
}

printf '\nInstalling Meringue\n\n'

need git "Install git and run this again."
need ruby "Install Ruby 3.1 or newer and run this again."

# Meringue requires Ruby >= 3.1, and the failure without this check is an
# obscure syntax error from inside a library rather than a version message.
if ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1") ? 0 : 1)'; then
  die "Ruby $(ruby -e 'print RUBY_VERSION') is too old; Meringue needs 3.1 or newer."
fi
note "ruby $(ruby -e 'print RUBY_VERSION')"

if ! command -v bundle >/dev/null 2>&1; then
  note "installing bundler"
  gem install --user-install --no-document bundler >/dev/null 2>&1 ||
    die "could not install bundler. Install it yourself with: gem install --user-install bundler"
  PATH="$(ruby -r rubygems -e 'print Gem.user_dir')/bin:$PATH"
  export PATH
fi
command -v bundle >/dev/null 2>&1 ||
  die "bundler is installed but not on PATH. Add \$(ruby -r rubygems -e 'print Gem.user_dir')/bin to your PATH."

if [ -d "$SRC_DIR/.git" ]; then
  note "updating $SRC_DIR"
  git -C "$SRC_DIR" fetch --quiet origin "$BRANCH"
  # A checkout someone has been editing is theirs; overwriting it would discard
  # work the installer knows nothing about.
  if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
    die "$SRC_DIR has local changes. Commit or stash them, then run this again."
  fi
  git -C "$SRC_DIR" checkout --quiet "$BRANCH"
  git -C "$SRC_DIR" merge --quiet --ff-only "origin/$BRANCH"
else
  note "cloning into $SRC_DIR"
  mkdir -p "$MERINGUE_HOME"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

# The Gemfile also writes a shim on `bundle install` for clone-based setup. This
# script wants it in BIN_DIR specifically, so it takes that job itself rather
# than letting the two disagree about where the command should go.
note "installing dependencies"
( cd "$SRC_DIR" && MERINGUE_NO_SHIM=1 bundle install --quiet ) || die "bundle install failed in $SRC_DIR."

MERINGUE_BIN_DIR="$BIN_DIR" ruby -r"$SRC_DIR/lib/meringue/shim" \
  -e 'result = Meringue::Shim.install!(source_dir: ARGV[0]); abort(result.fetch("message")) if result.fetch("status") == Meringue::Shim::FAILED' \
  "$SRC_DIR" || die "could not write $SHIM."
note "installed $SHIM"

printf '\nDone.\n\n'

case ":$PATH:" in
  *":$BIN_DIR:"*)
    printf '  Run  meringue         to start.\n'
    printf '  Run  meringue doctor  if anything looks wrong.\n\n'
    ;;
  *)
    printf '  %s is not on your PATH yet. Add this to your shell startup file:\n\n' "$BIN_DIR"
    printf '    export PATH="%s:$PATH"\n\n' "$BIN_DIR"
    printf '  Then run  meringue  to start, or  %s  right now.\n\n' "$SHIM"
    ;;
esac
