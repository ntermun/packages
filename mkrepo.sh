#!/usr/bin/env bash
#
# mkrepo.sh -- build a pacman repository database without repo-add/pacman.
#
# Scans <outdir> for *.pkg.tar.zst, reads each package's .PKGINFO and writes:
#
#   <repo>.db.tar.gz      binary database   (name-version/desc entries)
#   <repo>.files.tar.gz   file database     (name-version/files entries)
#   <repo>.db             symlink -> <repo>.db.tar.gz
#   <repo>.files          symlink -> <repo>.files.tar.gz
#
# "desc" uses the repo-add section format:
#   %FILENAME% %NAME% %VERSION% %DESC% %CSIZE% %ISIZE%
#   %MD5SUM% %SHA256SUM% %ARCH% %DEPENDS% ...
#
# If several versions of the same package are present, the highest version
# (version sort) wins and the older files are left untouched on disk.
#
set -euo pipefail
umask 022

PROG=${0##*/}
REPO_NAME=${REPO_NAME:-nterminal}

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: $PROG [outdir]

Create ${REPO_NAME}.db.tar.gz / ${REPO_NAME}.files.tar.gz next to the packages.

  [outdir]   directory with *.pkg.tar.zst (default: ./out next to this script)

Environment:
  REPO_NAME  repository name, default: $REPO_NAME
  SOURCE_DATE_EPOCH  timestamp for reproducible tarballs

Example:
  $PROG out
EOF
}

case ${1:-} in
	-h|--help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
outdir=${1:-$script_dir/out}

[[ -d $outdir ]] || die "no such directory: $outdir"
command -v zstd   >/dev/null || die "zstd is required"
command -v gzip   >/dev/null || die "gzip is required"
command -v tar    >/dev/null || die "tar is required"
command -v md5sum >/dev/null || die "md5sum is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

shopt -s nullglob
pkgs=("$outdir"/*.pkg.tar.zst)
shopt -u nullglob

[[ ${#pkgs[@]} -gt 0 ]] || die "no *.pkg.tar.zst packages in $outdir"

# Read a .PKGINFO field from a package (first match).
pkg_field() {
	local file=$1 key=$2
	zstd -dc -- "$file" | tar -xO -f - .PKGINFO 2>/dev/null |
		awk -F= -v key="$key" '
			{ k = $1; gsub(/[[:space:]]/, "", k) }
			k == key {
				v = substr($0, index($0, "=") + 1)
				sub(/^[[:space:]]+/, "", v)
				sub(/[[:space:]]+$/, "", v)
				print v
				exit
			}
		'
}

# Read all values of a repeated .PKGINFO field (e.g. depend).
pkg_field_all() {
	local file=$1 key=$2
	zstd -dc -- "$file" | tar -xO -f - .PKGINFO 2>/dev/null |
		awk -F= -v key="$key" '
			{ k = $1; gsub(/[[:space:]]/, "", k) }
			k == key {
				v = substr($0, index($0, "=") + 1)
				sub(/^[[:space:]]+/, "", v)
				sub(/[[:space:]]+$/, "", v)
				if (v != "") print v
			}
		'
}

# true if $1 is newer than $2 using version sort
ver_gt() {
	local newest
	newest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
	[[ $newest == "$1" && $1 != "$2" ]]
}

# Pick one package per name (highest version).
declare -A chosen_file=()
declare -A chosen_ver=()

for f in "${pkgs[@]}"; do
	name=$(pkg_field "$f" pkgname)
	ver=$(pkg_field "$f" pkgver)
	rel=$(pkg_field "$f" pkgrel)
	[[ -n $name ]] || die "cannot read pkgname from $(basename "$f")"
	[[ -n $ver  ]] || die "cannot read pkgver from $(basename "$f")"
	# .PKGINFO keeps the full version "ver-rel"; older/hand-made packages may
	# still carry a separate pkgrel key.
	if [[ -n $rel && $ver != *-"$rel" ]]; then
		version=$ver-$rel
	else
		version=$ver
	fi

	if [[ -n ${chosen_file[$name]:-} ]]; then
		if ver_gt "$version" "${chosen_ver[$name]}"; then
			warn "$name: $version supersedes ${chosen_ver[$name]} ($(basename "${chosen_file[$name]}"))"
			chosen_file[$name]=$f
			chosen_ver[$name]=$version
		elif [[ $version == "${chosen_ver[$name]}" ]]; then
			warn "$name: duplicate version $version, keeping $(basename "${chosen_file[$name]}")"
		else
			warn "$name: $version is older than ${chosen_ver[$name]}, skipping $(basename "$f")"
		fi
		continue
	fi
	chosen_file[$name]=$f
	chosen_ver[$name]=$version
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/mkrepo.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/db" "$tmpdir/files"

epoch=${SOURCE_DATE_EPOCH:-$(date +%s)}
printf -v mtime '@%s' "$epoch"

# Write name-version/{desc,files} for one package.
write_entry() {
	local f=$1 name=$2 version=$3
	local entry=$name-$version
	local dir=$tmpdir/db/$entry
	local fdir=$tmpdir/files/$entry

	local fname desc arch isize csize md5 sha256 deps
	fname=$(basename "$f")
	desc=$(pkg_field "$f" pkgdesc)
	[[ -n $desc ]] || desc=$(pkg_field "$f" desc)
	arch=$(pkg_field "$f" arch)
	isize=$(pkg_field "$f" size)
	# .PKGINFO uses "depend"; accept the plural spelling from hand-made trees.
	deps=$(
		{
			pkg_field_all "$f" depend
			pkg_field_all "$f" depends
		} | awk '!seen[$0]++'
	)

	csize=$(stat -c %s "$f")
	md5=$(md5sum "$f" | awk '{ print $1 }')
	sha256=$(sha256sum "$f" | awk '{ print $1 }')

	mkdir -p "$dir" "$fdir"

	{
		printf '%%FILENAME%%\n%s\n\n' "$fname"
		printf '%%NAME%%\n%s\n\n' "$name"
		printf '%%VERSION%%\n%s\n\n' "$version"
		printf '%%DESC%%\n%s\n\n' "$desc"
		printf '%%CSIZE%%\n%s\n\n' "$csize"
		printf '%%ISIZE%%\n%s\n\n' "${isize:-0}"
		printf '%%MD5SUM%%\n%s\n\n' "$md5"
		printf '%%SHA256SUM%%\n%s\n\n' "$sha256"
		printf '%%ARCH%%\n%s\n\n' "${arch:-aarch64}"
		printf '%%DEPENDS%%\n'
		[[ -n $deps ]] && printf '%s\n' "$deps"
		printf '\n'
	} > "$dir/desc"

	# Optional sections, only when present.
	local provides conflicts
	provides=$(pkg_field_all "$f" provides)
	conflicts=$(pkg_field_all "$f" conflicts)
	if [[ -n $provides ]]; then
		printf '%%PROVIDES%%\n%s\n\n' "$provides" >> "$dir/desc"
	fi
	if [[ -n $conflicts ]]; then
		printf '%%CONFLICTS%%\n%s\n\n' "$conflicts" >> "$dir/desc"
	fi

	# File list: dirs keep their trailing slash, metadata files are skipped.
	{
		printf '%%FILES%%\n'
		zstd -dc -- "$f" | tar -tf - |
			sed 's|^\./||' |
			awk 'NF && $0 !~ /^\.(PKGINFO|INSTALL|BUILDINFO|MTREE|CHANGELOG)$/'
		printf '\n'
	} > "$fdir/files"

	# repo-add keeps a desc copy in the files database too.
	cp "$dir/desc" "$fdir/desc"
}

for name in "${!chosen_file[@]}"; do
	write_entry "${chosen_file[$name]}" "$name" "${chosen_ver[$name]}"
done

# Build a gzip tarball from top-level entries (repo-add style, no ./ prefix).
make_tar() {
	local dir=$1 dest=$2
	local -a names=()
	local n
	while IFS= read -r -d '' n; do
		names+=("$n")
	done < <(cd "$dir" && find . -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)
	[[ ${#names[@]} -gt 0 ]] || die "nothing to put into $dest"
	(
		cd "$dir"
		printf '%s\0' "${names[@]}" |
			tar --null -T - --sort=name --format=gnu --mtime="$mtime" \
				--owner=0 --group=0 --numeric-owner -cf -
	) | gzip -9n > "$dest"
}

db=$outdir/$REPO_NAME.db.tar.gz
files_db=$outdir/$REPO_NAME.files.tar.gz

info "indexing ${#chosen_file[@]} package(s) into $outdir"
make_tar "$tmpdir/db" "$db"
make_tar "$tmpdir/files" "$files_db"

ln -sfn "$(basename "$db")" "$outdir/$REPO_NAME.db"
ln -sfn "$(basename "$files_db")" "$outdir/$REPO_NAME.files"

# Summary table.
printf '\n%-24s %-16s %12s\n' NAME VERSION CSIZE
printf '%-24s %-16s %12s\n' ------------------------ ---------------- ------------
for name in $(printf '%s\n' "${!chosen_ver[@]}" | LC_ALL=C sort); do
	f=${chosen_file[$name]}
	printf '%-24s %-16s %12s\n' "$name" "${chosen_ver[$name]}" "$(stat -c %s "$f")"
done

info "wrote $(basename "$db") ($(stat -c %s "$db") bytes)"
info "wrote $(basename "$files_db") ($(stat -c %s "$files_db") bytes)"
info "symlinks: $REPO_NAME.db -> $(basename "$db"), $REPO_NAME.files -> $(basename "$files_db")"
