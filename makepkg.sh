#!/usr/bin/env bash
# makepkg.sh - tiny Arch-style driver for repo/packages/*/PKGBUILD.
#
# It sources a PKGBUILD, downloads and verifies sources, calls build() and
# package(), strips ELF files, stages the result (so later packages can link
# against earlier ones) and finally calls build-pkg.sh.
#
# This is deliberately not a full makepkg: no split packages, no .SRCINFO,
# no signing, no dependency resolution.  It exists so the repository can be
# rebuilt reproducibly on a machine without pacman.
#
# Usage:
#   makepkg.sh [-f] [-o OUTDIR] [-w WORKDIR] [PKG...]
#
# Without PKG arguments all packages in repo/packages/ are built in the order
# below (openssl first because openssh links against it).
set -euo pipefail

PROG=${0##*/}
script_dir=$(cd "$(dirname "$0")" && pwd -P)
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $PROG [-f] [-o OUTDIR] [-w WORKDIR] [PKG...]

  -f         rebuild even if the package already exists in OUTDIR
  -o DIR     output directory (default: <repo>/out/aarch64)
  -w DIR     work directory (default: <repo>/work)
  -h         this help

Packages: bash coreutils grep sed gawk tar gzip findutils diffutils make
          openssh openssl
EOF
}

force=0
outdir=
workdir=
while getopts ":fo:w:h" opt; do
	case $opt in
		f) force=1 ;;
		o) outdir=$OPTARG ;;
		w) workdir=$OPTARG ;;
		h) usage; exit 0 ;;
		:) die "option -$OPTARG requires an argument" ;;
		\?) die "unknown option -$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

# shellcheck source=musl-env.sh
. "$script_dir/musl-env.sh"

outdir=${outdir:-$script_dir/out/aarch64}
workdir=${workdir:-$script_dir/work}
mkdir -p "$outdir" "$workdir"
outdir=$(cd "$outdir" && pwd -P)
workdir=$(cd "$workdir" && pwd -P)

SRCDEST=${SRCDEST:-$workdir/src-cache}
STAGE=${STAGE:-$workdir/stage}
mkdir -p "$SRCDEST" "$STAGE"

DEFAULT_ORDER=(zlib openssl xz bzip2 zstd sqlite ncurses libarchive curl pacman \
	bash coreutils grep sed gawk tar gzip findutils diffutils make \
	openssh openssh-server)

if (($#)); then
	order=("$@")
else
	order=("${DEFAULT_ORDER[@]}")
fi

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

strip_tree() {
	local f magic
	while IFS= read -r -d '' f; do
		magic=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
		if [[ $magic == 7f454c46 ]]; then
			"$STRIP" --strip-unneeded "$f" 2>/dev/null || true
		fi
	done < <(find "$1" -type f -print0)
}

build_one() {
	local pkg=$1 pkgbuild=$script_dir/packages/$1/PKGBUILD
	[[ -f $pkgbuild ]] || die "no PKGBUILD for $pkg"

	(
		# Reset all metadata so a previous PKGBUILD cannot leak values.
		pkgname= pkgver= pkgrel=1 pkgdesc= url= arch=(aarch64)
		source=() sha256sums=() depends=() provides=() conflicts=() replaces=()
		build() { :; }
		package() { :; }

		# shellcheck disable=SC1090
		. "$pkgbuild"

		[[ -n $pkgname && -n $pkgver ]] || die "$pkgbuild: pkgname/pkgver missing"
		[[ $pkgname == "$pkg" ]] || die "$pkgbuild: pkgname=$pkgname, expected $pkg"

		local fullver=$pkgver-$pkgrel
		local pkgarch=${arch[0]:-aarch64}
		local outfile=$outdir/$pkgname-$fullver-$pkgarch.pkg.tar.zst

		if [[ $force -eq 0 && -f $outfile ]]; then
			printf '==> %s: up to date (%s)\n' "$pkgname" "${outfile##*/}"
			return 0
		fi

		local srcdir=$workdir/src/$pkgname
		local pkgdir=$workdir/pkg/$pkgname
		rm -rf "$srcdir" "$pkgdir"
		mkdir -p "$srcdir" "$pkgdir"

		printf '==> %s %s: sources\n' "$pkgname" "$fullver"
		local i url entry fname dest sum
		for i in "${!source[@]}"; do
			entry=${source[$i]}
			if [[ $entry == *::* ]]; then
				fname=${entry%%::*}
				url=${entry#*::}
			else
				url=$entry
				fname=${url##*/}
			fi
			dest=$SRCDEST/$fname
			# A bare file name that exists next to the PKGBUILD is a local
			# source (patch, config, ...): no download needed.
			if [[ $url != *://* && -f $startdir/$url ]]; then
				cp -f "$startdir/$url" "$dest"
			elif [[ ! -f $dest ]]; then
				printf '    downloading %s\n' "$url"
				curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" ||
					die "download failed: $url"
				mv -f "$dest.part" "$dest"
			fi

			sum=${sha256sums[$i]:-SKIP}
			if [[ $sum == SKIP ]]; then
				printf '    warning: sha256sums[%s] is SKIP\n' "$i" >&2
			else
				[[ $(sha256_file "$dest") == "$sum" ]] ||
					die "sha256 mismatch: $fname"
			fi

			case $fname in
				*.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar.zst|*.tar)
					tar -xf "$dest" -C "$srcdir" ||
						die "cannot extract $fname"
					;;
				*)
					cp -f "$dest" "$srcdir/$fname"
					;;
			esac
		done

		# Local patches listed in source are applied to the extracted tree,
		# Arch style (paths in the patch carry the usual a/ b/ prefix).
		local patchroot=$srcdir patchdir
		patchdir=$(find "$srcdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
		if [[ -n $patchdir && $(find "$srcdir" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]]; then
			patchroot=$patchdir
		fi
		for i in "${!source[@]}"; do
			fname=${source[$i]%%::*}
			fname=${fname##*/}
			case $fname in
				*.patch|*.diff)
					printf '    applying %s\n' "$fname"
					( cd "$patchroot" && patch -p1 --batch --forward -i "$srcdir/$fname" ) ||
						die "patch failed: $fname"
					;;
			esac
		done

		# Later packages can find headers/libs from earlier ones.
		export CPPFLAGS="-I$STAGE/usr/include ${CPPFLAGS:-}"
		export LDFLAGS="-static -no-pie -L$STAGE/usr/lib"
		export PKG_CONFIG_PATH="$STAGE/usr/lib/pkgconfig:$STAGE/usr/share/pkgconfig"
		export PKG_CONFIG_SYSROOT_DIR="$STAGE"
		export startdir=$script_dir/packages/$pkg
		export JOBS

		printf '==> %s %s: build\n' "$pkgname" "$fullver"
		( cd "$srcdir" && build )

		printf '==> %s %s: package\n' "$pkgname" "$fullver"
		( cd "$srcdir" && package )

		[[ -n $(find "$pkgdir" -mindepth 1 -print -quit) ]] ||
			die "package() produced an empty tree for $pkgname"

		strip_tree "$pkgdir"

		# Stage headers/static libs/binaries for dependent packages.
		if [[ ${NOSTAGE:-0} != 1 ]]; then
			cp -a "$pkgdir/." "$STAGE/"
		fi

		local dep_csv=
		if ((${#depends[@]})); then
			dep_csv=$(printf '%s\n' "${depends[@]}" | paste -sd, -)
		fi

		local -a args=(-n "$pkgname" -v "$pkgver" -r "$pkgrel" -a "$pkgarch")
		[[ -n $pkgdesc ]] && args+=(-d "$pkgdesc")
		[[ -n $url ]] && args+=(-u "$url")
		[[ -n $dep_csv ]] && args+=(-D "$dep_csv")

		"$script_dir/build-pkg.sh" "${args[@]}" -C "$pkgdir" -o "$outdir"
	)
}

for p in "${order[@]}"; do
	build_one "$p"
done

printf '\nAll requested packages are in %s\n' "$outdir"
