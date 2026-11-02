#!/usr/bin/env bash
#
# build-pkg.sh -- pack a prepared file tree into a pacman binary package.
#
# The input directory is the *install root* of the package:
#
#   pkgroot/
#     .PKGINFO              metadata (not installed)
#     usr/bin/foo           files that will land in /usr/bin/foo
#     usr/share/doc/foo/...
#
# Output: <outdir>/<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
#
# The script
#   * validates .PKGINFO and requires pkgname/pkgver/pkgrel,
#   * forces arch=aarch64 unless the metadata says otherwise,
#   * normalises permissions (dirs 0755, files in bin/sbin/libexec 0755),
#   * recomputes "size" (installed size) from the tree,
#   * writes a reproducible zstd-compressed tar (SOUCE_DATE_EPOCH aware).
#
set -euo pipefail
umask 022

PROG=${0##*/}

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: $PROG <pkgdir> [outdir]

Pack the prepared package tree <pkgdir> into a pacman .pkg.tar.zst.

  <pkgdir>   tree that contains .PKGINFO and the files to install
  [outdir]   where to write the package (default: ./out next to this script)

.PKGINFO keys: pkgname, pkgver, pkgrel, arch (default aarch64),
pkgdesc (alias: desc), depend. "size" is always recomputed.

Example:
  $PROG .build/bash/pkg out
EOF
}

case ${1:-} in
	-h|--help) usage; exit 0 ;;
	'') usage >&2; exit 2 ;;
esac

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
pkgdir=${1%/}
outdir=${2:-$script_dir/out}

[[ -d $pkgdir ]] || die "no such directory: $pkgdir"
pkgdir=$(cd -- "$pkgdir" && pwd)
pkginfo=$pkgdir/.PKGINFO
[[ -f $pkginfo ]] || die "missing metadata file: $pkginfo"

command -v zstd >/dev/null || die "zstd is required"
command -v tar  >/dev/null || die "tar is required"

# Read a single "key = value" from .PKGINFO (last value wins for duplicates).
pkginfo_field() {
	local key=$1 file=$2
	awk -F= -v key="$key" '
		{ k = $1; gsub(/[[:space:]]/, "", k) }
		k == key {
			v = substr($0, index($0, "=") + 1)
			sub(/^[[:space:]]+/, "", v)
			sub(/[[:space:]]+$/, "", v)
			print v
			exit
		}
	' "$file"
}

pkgname=$(pkginfo_field pkgname "$pkginfo")
pkgver=$(pkginfo_field pkgver  "$pkginfo")
pkgrel=$(pkginfo_field pkgrel  "$pkginfo")
arch=$(pkginfo_field arch      "$pkginfo")
pkgdesc=$(pkginfo_field pkgdesc "$pkginfo")
[[ -n $pkgdesc ]] || pkgdesc=$(pkginfo_field desc "$pkginfo")

[[ -n $pkgname ]] || die ".PKGINFO: missing pkgname"
[[ -n $pkgver  ]] || die ".PKGINFO: missing pkgver"
[[ $pkgname =~ ^[A-Za-z0-9@._+-]+$ ]] || die ".PKGINFO: invalid pkgname: $pkgname"
[[ $pkgver  =~ ^[A-Za-z0-9._+~-]+$  ]] || die ".PKGINFO: invalid pkgver: $pkgver"

# pacman stores the full version "ver-rel" in .PKGINFO's pkgver (there is no
# separate pkgrel key in a binary package).  Accept both spellings on input.
if [[ -z $pkgrel ]]; then
	if [[ $pkgver == *-* ]]; then
		pkgrel=${pkgver##*-}
		pkgver=${pkgver%-*}
	else
		pkgrel=1
	fi
fi
[[ $pkgrel =~ ^[A-Za-z0-9._+~-]+$ ]] || die ".PKGINFO: invalid pkgrel: $pkgrel"

if [[ $pkgver == *-"$pkgrel" ]]; then
	fullver=$pkgver
else
	fullver=$pkgver-$pkgrel
fi

# The repository only serves aarch64; keep packages honest.
if [[ -z $arch ]]; then
	arch=aarch64
elif [[ $arch != aarch64 ]]; then
	warn ".PKGINFO arch=$arch, forcing aarch64"
	arch=aarch64
fi

# --- permissions -----------------------------------------------------------
# Directories 0755, regular files 0644, executables 0755.  Files are made
# executable when they live in a bin/sbin/libexec directory.
find "$pkgdir" -type d -exec chmod 755 {} +
find "$pkgdir" -type f -exec chmod 644 {} +
find "$pkgdir" -type f \
	\( -path '*/bin/*' -o -path '*/sbin/*' -o -path '*/libexec/*' \) \
	-exec chmod 755 {} +

# --- installed size --------------------------------------------------------
# Everything except the package metadata itself.  .INSTALL/.CHANGELOG are not
# installed on the target system either.
size=$(find "$pkgdir" -type f \
	! -name .PKGINFO ! -name .INSTALL ! -name .BUILDINFO \
	! -name .MTREE ! -name .CHANGELOG \
	-exec stat -c %s {} + | awk '{ s += $1 } END { printf "%d", s + 0 }')

# --- rewrite .PKGINFO ------------------------------------------------------
# Normalise "desc" -> "pkgdesc", pack "ver-rel" into pkgver, inject the
# freshly computed size and arch.
PKG_SIZE=$size PKG_ARCH=$arch PKG_FULLVER=$fullver awk '
	BEGIN {
		size = ENVIRON["PKG_SIZE"]
		arch = ENVIRON["PKG_ARCH"]
		fullver = ENVIRON["PKG_FULLVER"]
		have_size = 0
		have_arch = 0
		have_desc = 0
		have_ver = 0
	}
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
	{
		line = $0
		key = line
		sub(/=.*/, "", key)
		gsub(/[[:space:]]/, "", key)
		if (key == "size") { print "size = " size; have_size = 1; next }
		if (key == "arch") { print "arch = " arch; have_arch = 1; next }
		if (key == "pkgver") { print "pkgver = " fullver; have_ver = 1; next }
		if (key == "pkgrel") { next }
		if (key == "desc") {
			if (have_desc) next
			v = line
			sub(/^[^=]*=[[:space:]]*/, "", v)
			print "pkgdesc = " v
			have_desc = 1
			next
		}
		if (key == "pkgdesc") {
			if (have_desc) next
			print line
			have_desc = 1
			next
		}
		print line
	}
	END {
		if (!have_size) print "size = " size
		if (!have_arch) print "arch = " arch
		if (!have_ver)  print "pkgver = " fullver
	}
' "$pkginfo" > "$pkginfo.tmp"
chmod 644 "$pkginfo.tmp"
mv -f "$pkginfo.tmp" "$pkginfo"

# --- archive ---------------------------------------------------------------
source_date_epoch=${SOURCE_DATE_EPOCH:-}
tar_args=(--null -T - --sort=name --format=gnu
	--owner=0 --group=0 --numeric-owner)
[[ -n $source_date_epoch ]] && tar_args+=(--mtime="@$source_date_epoch")

entries=()
while IFS= read -r -d '' entry; do
	entries+=("$entry")
done < <(cd "$pkgdir" && find . -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)

[[ ${#entries[@]} -gt 0 ]] || die "package tree is empty: $pkgdir"

mkdir -p "$outdir"
outdir=$(cd -- "$outdir" && pwd)
pkgfile=$outdir/$pkgname-$fullver-$arch.pkg.tar.zst
tmpfile=$pkgfile.$$.tmp
trap 'rm -f "$tmpfile"' EXIT

info "packing $pkgname $fullver ($arch), ${size} bytes installed"
(
	cd "$pkgdir"
	printf '%s\0' "${entries[@]}" |
		tar "${tar_args[@]}" -cf - |
		zstd -q -19 -T0 -o "$tmpfile"
)
mv -f "$tmpfile" "$pkgfile"
trap - EXIT

sha256=$(sha256sum "$pkgfile" | awk '{ print $1 }')
csize=$(stat -c %s "$pkgfile")

info "wrote $pkgfile"
printf '    size:   %s bytes\n' "$csize"
printf '    sha256: %s\n' "$sha256"
