#!/usr/bin/env bash
#
# build-macos-local.sh - build a double-clickable Filee.app on macOS without an
# Apple Developer account.
#
# build/build-portable.ps1 is the official portable packager, but it requires
# PowerShell 7 and downloads the external engines. This script performs the same
# app-bundle work using only the tools that ship with macOS, then signs the
# result with a locally trusted certificate so Gatekeeper stops rejecting it.
#
# Usage:
#   ./build/build-macos-local.sh                  # build only, into build/.cache/local
#   ./build/build-macos-local.sh --install        # build, then install to ~/Applications
#   ./build/build-macos-local.sh --engines DIR    # reuse engines from an existing Filee.app
#   ./build/build-macos-local.sh --identity NAME  # use another signing identity ("-" = ad-hoc)
#
# See docs/BUILD-MACOS-LOCAL.md for the one-time certificate setup.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=0
ENGINES_SRC=""
IDENTITY="${IDENTITY:-Filee Local Signing}"

while [ $# -gt 0 ]; do
    case "$1" in
        --install)  INSTALL=1 ;;
        --engines)  ENGINES_SRC="${2:-}"; shift ;;
        --identity) IDENTITY="${2:-}"; shift ;;
        -h|--help)  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---

for tool in dotnet sips iconutil codesign plutil xattr ditto; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

case "$(uname -m)" in
    arm64)  RUNTIME="osx-arm64" ;;
    x86_64) RUNTIME="osx-x64" ;;
    *)      die "unsupported architecture: $(uname -m)" ;;
esac

VERSION="$(sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$ROOT/Directory.Build.props" | head -1)"
[ -n "$VERSION" ] || die "cannot read <Version> from Directory.Build.props"
VERSION="${VERSION#v}"
BUNDLE_VERSION="${VERSION%%-*}"

if [ "$IDENTITY" != "-" ]; then
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY" \
        || die "signing identity '$IDENTITY' not found. Run the certificate setup in docs/BUILD-MACOS-LOCAL.md, or pass --identity - for an ad-hoc signature."
fi

ENTITLEMENTS="$ROOT/installer/macos/entitlements.plist"
STAGE="$ROOT/build/.cache/local/Filee-$VERSION-$RUNTIME"
APP="$STAGE/Filee.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
PUBLISH="$CONTENTS/MacOS"

rm -rf "$STAGE" 2>/dev/null || true
mkdir -p "$PUBLISH" "$RESOURCES"

echo "Filee $VERSION  runtime=$RUNTIME  identity=$IDENTITY"
echo "stage: $STAGE"

# ------------------------------------------------------------------ publish ---

for project in Filee.App Filee.Cli; do
    step "publish $project"
    dotnet publish "$ROOT/src/$project/$project.csproj" \
        -c Release -r "$RUNTIME" --self-contained true \
        -p:Version="$VERSION" -p:FileeRelease=true -p:PublishReadyToRun=false \
        -o "$PUBLISH"
done

for exe in Filee filee-cli; do
    [ -f "$PUBLISH/$exe" ] || die "publish did not produce $exe"
    chmod +x "$PUBLISH/$exe"
done

# .NET ships some managed assemblies with the executable bit set. codesign then
# treats them as nested code and refuses to sign the main executable
# ("In subcomponent: .../System.Net.Security.dll"). Only real Mach-O files keep
# the bit; everything else is plain data.
step "normalise executable bits"
is_macho() {
    local magic
    magic="$(xxd -p -l 4 "$1" 2>/dev/null || true)"
    case "$magic" in
        cffaedfe|cefaedfe|cafebabe|bebafeca|feedface|feedfacf) return 0 ;;
        *) return 1 ;;
    esac
}
stripped=0
while IFS= read -r file; do
    if ! is_macho "$file"; then
        chmod a-x "$file"
        stripped=$((stripped + 1))
    fi
done < <(find "$PUBLISH" -type f -perm -u+x)
echo "cleared the executable bit on $stripped non-Mach-O file(s)"

# -------------------------------------------------------------- app bundle ---

step "assemble app bundle"
sed -e "s/__VERSION__/$BUNDLE_VERSION/g" \
    -e "s/__BUNDLE_VERSION__/$BUNDLE_VERSION/g" \
    "$ROOT/installer/macos/Info.plist" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

ICONSET="$STAGE/filee.iconset"
mkdir -p "$ICONSET"
SOURCE_ICON="$ROOT/src/Filee.App/Assets/Icons/filee.png"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        [ "$scale" = "2" ] && suffix="@2x"
        sips -z "$pixels" "$pixels" "$SOURCE_ICON" \
            --out "$ICONSET/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/filee.icns"
echo "icon: $(du -h "$RESOURCES/filee.icns" | awk '{print $1}')"

for lproj in "$ROOT/installer/macos/"*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$RESOURCES/"
done
echo "localisations: $(find "$RESOURCES" -maxdepth 1 -name '*.lproj' | wc -l | tr -d ' ')"

for notice in LICENSE THIRD-PARTY-NOTICES.md; do
    [ -f "$ROOT/$notice" ] && cp "$ROOT/$notice" "$STAGE/"
done

# ---------------------------------------------------------------- engines ----

# pandoc / calibre / libreoffice are downloaded on demand at runtime; only the
# bundled 7zip and rhwp are required (build/fetch-portable-engines.ps1 normally
# fetches them, which needs PowerShell). Reuse them from an existing install
# when one is available.
step "external engines"
if [ -z "$ENGINES_SRC" ]; then
    for candidate in "$HOME/Applications/Filee.app/Contents/MacOS/engines" \
                     "/Applications/Filee.app/Contents/MacOS/engines"; do
        if [ -d "$candidate" ]; then ENGINES_SRC="$candidate"; break; fi
    done
fi
if [ -n "$ENGINES_SRC" ] && [ -d "$ENGINES_SRC" ]; then
    ditto "$ENGINES_SRC" "$PUBLISH/engines"
    [ -f "$PUBLISH/engines/rhwp/rhwp" ] && chmod +x "$PUBLISH/engines/rhwp/rhwp"
    echo "copied $(find "$PUBLISH/engines" -type f | wc -l | tr -d ' ') file(s) from $ENGINES_SRC"
else
    echo "warning: no engines found." >&2
    echo "         pass --engines <path-to-existing-Filee.app/Contents/MacOS/engines>" >&2
    echo "         or run build/fetch-portable-engines.ps1 from PowerShell 7." >&2
fi

# ------------------------------------------------------------------- sign ----

# Contents/MacOS is all code as far as codesign is concerned, managed assemblies
# included (their signature lives in extended attributes). Sign deepest paths
# first and the main executable last, exactly like build-portable.ps1. A
# self-signed identity must not use --timestamp (there is no Apple TSA chain).
step "sign"
SIGN_OPTS=(--force --sign "$IDENTITY")
while IFS= read -r file; do
    [ "$file" = "$PUBLISH/Filee" ] && continue
    codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$file" >/dev/null 2>&1 \
        || die "codesign failed on ${file#"$PUBLISH"/}"
done < <(find "$PUBLISH" -type f -print | awk '{print length($0) "\t" $0}' | sort -rn | cut -f2-)
echo "signed $(find "$PUBLISH" -type f | wc -l | tr -d ' ') nested file(s)"

codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$PUBLISH/Filee" >/dev/null
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
echo "signature verified"

# ---------------------------------------------------------------- install ----

if [ "$INSTALL" = "1" ]; then
    step "install"
    DEST="$HOME/Applications/Filee.app"
    mkdir -p "$HOME/Applications"
    if [ -e "$DEST" ]; then
        STAMP="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$HOME/.Trash"
        mv "$DEST" "$HOME/.Trash/Filee-$STAMP.app"
        echo "previous install moved to ~/.Trash/Filee-$STAMP.app"
    fi
    ditto "$APP" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    codesign --verify --deep --strict "$DEST"
    echo "installed: $DEST ($(du -sh "$DEST" | awk '{print $1}'))"
    echo
    echo "note: a self-signed bundle is always 'rejected' by 'spctl -a -t exec'"
    echo "      (Gatekeeper only trusts Apple-issued Developer IDs). Without the"
    echo "      com.apple.quarantine attribute it is never consulted, so the app"
    echo "      launches normally."
fi

step "done"
echo "app:    $APP"
echo "bundle: $(du -sh "$APP" | awk '{print $1}')"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|CDHash)' || true
