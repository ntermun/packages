#!/usr/bin/env bash
# mkrepo.sh - minimal repo-add replacement for the ntermun repository.
#
# Scans a directory of *.pkg.tar.zst files and produces the two pacman
# databases used by "pacman -Sy":
#
#   ntermun.db.tar.gz      (symlink: ntermun.db)
#   ntermun.files.tar.gz   (symlink: ntermun.files)
#
# Each package gets an entry directory <name>-<version>/ with "desc" and
# "files" members, exactly like repo-add.  There is no signature handling:
# pacman.conf for the device uses SigLevel = Never.
#
# Usage:
#   mkrepo.sh [-n DBNAME] [-o OUTDIR] [PACKAGE...]
#
# Without PACKAGE arguments every *.pkg.tar.zst in OUTDIR is indexed.
set -euo pipefail

PROG=${0##*/}
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $PROG [-n DBNAME] [-o OUTDIR] [PACKAGE...]

  -n NAME   database name, default: ntermun
  -o DIR    directory containing packages, default: <repo>/out/aarch64
  -h        this help
EOF
}

dbname=ntermun
script_dir=$(cd "$(dirname "$0")" && pwd -P)
outdir=$script_dir/out/aarch64

while getopts ":n:o:h" opt; do
	case $opt in
		n) dbname=$OPTARG ;;
		o) outdir=$OPTARG ;;
		h) usage; exit 0 ;;
		:) die "option -$OPTARG requires an argument" ;;
		\?) die "unknown option -$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

[[ -d $outdir ]] || die "no such directory: $outdir"
outdir=$(cd "$outdir" && pwd -P)

if (($#)); then
	pkgs=("$@")
else
	shopt -s nullglob
	pkgs=("$outdir"/*.pkg.tar.zst "$outdir"/*.pkg.tar.xz "$outdir"/*.pkg.tar.gz)
	shopt -u nullglob
fi
((${#pkgs[@]})) || die "no packages found in $outdir"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mkrepo.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- archive helpers -------------------------------------------------------
# GNU tar auto-detects zstd when reading on modern systems; fall back to an
# explicit zstd pipe for older/busybox tars.
pkg_extract() { # <pkg> <member>
	local pkg=$1 member=$2
	if tar -xOf "$pkg" "$member" 2>/dev/null; then
		return 0
	fi
	zstd -dcq "$pkg" | tar -xO "$member"
}

pkg_list() { # <pkg>
	local pkg=$1
	if tar -tf "$pkg" 2>/dev/null; then
		return 0
	fi
	zstd -dcq "$pkg" | tar -t
}

pkg_meta() { # <pkg> <key>
	pkg_extract "$1" .PKGINFO | sed -n "s/^$2 = //p"
}

human_sum() {
	awk '{s += $1} END {printf "%d\n", s}'
}

# --- collect entries -------------------------------------------------------
entries=()
index=0
for pkg in "${pkgs[@]}"; do
	[[ -f $pkg ]] || die "no such package: $pkg"
	filename=${pkg##*/}
	case $filename in
		*.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz) ;;
		*) die "not a pacman package: $filename" ;;
	esac

	info=$(pkg_extract "$pkg" .PKGINFO) || die "cannot read .PKGINFO from $filename"
	[[ -n $info ]] || die "$filename has no .PKGINFO"

	name=$(printf '%s\n' "$info" | sed -n 's/^pkgname = //p' | head -n1)
	version=$(printf '%s\n' "$info" | sed -n 's/^pkgver = //p' | head -n1)
	desc=$(printf '%s\n' "$info" | sed -n 's/^pkgdesc = //p' | head -n1)
	arch=$(printf '%s\n' "$info" | sed -n 's/^arch = //p' | head -n1)
	base=$(printf '%s\n' "$info" | sed -n 's/^pkgbase = //p' | head -n1)
	builddate=$(printf '%s\n' "$info" | sed -n 's/^builddate = //p' | head -n1)
	packager=$(printf '%s\n' "$info" | sed -n 's/^packager = //p' | head -n1)
	url=$(printf '%s\n' "$info" | sed -n 's/^url = //p' | head -n1)
	mapfile -t depends < <(printf '%s\n' "$info" | sed -n 's/^depend = //p')
	mapfile -t provides < <(printf '%s\n' "$info" | sed -n 's/^provides = //p')
	mapfile -t conflicts < <(printf '%s\n' "$info" | sed -n 's/^conflict = //p')
	mapfile -t replaces < <(printf '%s\n' "$info" | sed -n 's/^replaces = //p')

	[[ -n $name && -n $version ]] || die "$filename: .PKGINFO lacks pkgname/pkgver"
	[[ $arch == aarch64 ]] || printf '%s: warning: arch is %s, expected aarch64\n' "$PROG" "$arch" >&2

	csize=$(wc -c <"$pkg" | tr -d ' ')
	isize=$(printf '%s\n' "$info" | sed -n 's/^size = //p' | head -n1)
	[[ -n $isize ]] || isize=0
	# Faithful checksums; this is what pacman verifies after download.
	md5=$(md5sum "$pkg" | cut -d' ' -f1)
	sha256=$(sha256sum "$pkg" | cut -d' ' -f1)

	entry="$tmp/$name-$version"
	[[ -e $entry ]] && die "duplicate package entry: $name-$version"
	entries+=("$name-$version")

	{
		printf '%%FILENAME%%\n%s\n\n' "$filename"
		printf '%%NAME%%\n%s\n\n' "$name"
		printf '%%BASE%%\n%s\n\n' "${base:-$name}"
		printf '%%VERSION%%\n%s\n\n' "$version"
		printf '%%DESC%%\n%s\n\n' "$desc"
		printf '%%CSIZE%%\n%s\n\n' "$csize"
		printf '%%ISIZE%%\n%s\n\n' "$isize"
		printf '%%MD5SUM%%\n%s\n\n' "$md5"
		printf '%%SHA256SUM%%\n%s\n\n' "$sha256"
		[[ -n $url ]] && printf '%%URL%%\n%s\n\n' "$url"
		printf '%%ARCH%%\n%s\n\n' "$arch"
		[[ -n $builddate ]] && printf '%%BUILDDATE%%\n%s\n\n' "$builddate"
		[[ -n $packager ]] && printf '%%PACKAGER%%\n%s\n\n' "$packager"
		if ((${#replaces[@]})); then
			printf '%%REPLACES%%\n'
			printf '%s\n' "${replaces[@]}"
			printf '\n'
		fi
		if ((${#conflicts[@]})); then
			printf '%%CONFLICTS%%\n'
			printf '%s\n' "${conflicts[@]}"
			printf '\n'
		fi
		if ((${#provides[@]})); then
			printf '%%PROVIDES%%\n'
			printf '%s\n' "${provides[@]}"
			printf '\n'
		fi
		if ((${#depends[@]})); then
			printf '%%DEPENDS%%\n'
			printf '%s\n' "${depends[@]}"
			printf '\n'
		fi
	} >"$entry/desc"

	# Package file list for "pacman -F".  Strip the leading ./ introduced by
	# tar -C dir ., drop metadata members and normalise directory suffixes.
	{
		printf '%%FILES%%\n'
		pkg_list "$pkg" |
			sed -e 's|^\./||' -e 's|^/$||' |
			sed -e '/^$/d' \
				-e '/^\.PKGINFO$/d' -e '/^\.MTREE$/d' \
				-e '/^\.INSTALL$/d' -e '/^\.BUILDINFO$/d'
		printf '\n'
	} >"$entry/files"

	printf '  + %s-%s (%s bytes)\n' "$name" "$version" "$csize"
	index=$((index + 1))
done

# --- write databases -------------------------------------------------------
# Entry order is deterministic: sort by entry name.
mapfile -t entries < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)

dbfile=$outdir/$dbname.db.tar.gz
filesfile=$outdir/$dbname.files.tar.gz

( cd "$tmp" && tar --create --gzip --owner=0 --group=0 --numeric-owner \
	--file "$dbfile.tmp.$$" "${entries[@]}" )
mv -f "$dbfile.tmp.$$" "$dbfile"

( cd "$tmp" && tar --create --gzip --owner=0 --group=0 --numeric-owner \
	--file "$filesfile.tmp.$$" "${entries[@]}" )
mv -f "$filesfile.tmp.$$" "$filesfile"

ln -sfn "$dbname.db.tar.gz" "$outdir/$dbname.db"
ln -sfn "$dbname.files.tar.gz" "$outdir/$dbname.files"

printf 'repo: %s\n' "$outdir"
printf '  %s (%s packages, %s bytes)\n' "$dbname.db" "${#entries[@]}" "$(wc -c <"$dbfile" | tr -d ' ')"
printf '  %s\n' "$dbname.files"
