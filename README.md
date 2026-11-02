# ntermun packages

Инфраструктура собственного pacman-репозитория для aarch64 Android/Linux:
статические бинари GNU userland, собранные кросс-компилятором
`aarch64-linux-musl`, упакованные в `.pkg.tar.zst` и проиндексированные
без `repo-add`/`pacman`.

## Репозитории

| Репозиторий | Что лежит |
|---|---|
| [`ntermun/ntermun`](https://github.com/ntermun/ntermun) | приложение (терминал/Android). Только читается, отсюда ничего не публикуется. |
| [`ntermun/packages`](https://github.com/ntermun/packages) | **этот репозиторий**: скрипты сборки, PKGBUILD-шаблоны, `pacman.conf`, CI. |
| [`ntermun/main-repo`](https://github.com/ntermun/main-repo) | готовые пакеты и база `nterminal.db.tar.gz`, ветка `gh-pages`, каталог `aarch64/`. Отдаётся GitHub Pages. |

Публичный URL репозитория:

```
https://ntermun.github.io/main-repo/aarch64
```

## Состав

```
build-pkg.sh              упаковка готового дерева файлов в .pkg.tar.zst
ci-build.sh               mini-makepkg: скачивает исходники, собирает, пакует
mkrepo.sh                 аналог repo-add: nterminal.db / nterminal.files
pacman.conf               конфиг клиента ([nterminal], Architecture = aarch64)
packages/<name>/PKGBUILD  12 шаблонов сборки
.github/workflows/repo.yml  CI: сборка -> mkrepo.sh -> push в main-repo
```

Пакеты: `bash`, `coreutils`, `grep`, `sed`, `gawk`, `tar`, `gzip`,
`findutils`, `diffutils`, `make`, `openssl`, `openssh`.

## Формат пакета

Обычный pacman-пакет (tar + zstd), внутри корень установки и метаданные:

```
.PKGINFO
usr/bin/bash
usr/share/man/man1/bash.1.gz
```

`.PKGINFO` (ключи в формате `key = value`):

```
pkgname = bash
pkgver = 5.2.37-1        # полная версия "ver-rel", как требует libalpm
pkgdesc = GNU Bourne-Again SHell (static, musl)
url = https://www.gnu.org/software/bash/
builddate = 1762000000
packager = nterminal <d0m_1k@mail.ru>
size = 1234567          # пересчитывается build-pkg.sh
arch = aarch64
license = GPL-3.0-or-later
depend = ...
```

В `PKGBUILD` версия задаётся раздельно (`pkgver` + `pkgrel`), а
`build-pkg.sh` сам склеивает их в `.PKGINFO` (`pkgver = ver-rel`):
отдельного ключа `pkgrel` в бинарном пакете нет, иначе pacman считает
пакет битым (`invalid package version`). На входе `build-pkg.sh`
принимает и `pkgver`+`pkgrel`, и сразу `pkgver = 1.0-2`.

`build-pkg.sh` сам выставляет права (каталоги `0755`, файлы в
`bin/`, `sbin/`, `libexec/` — `0755`, остальные `0644`), пересчитывает
`size` и пишет `<pkgname>-<pkgver>-<pkgrel>-aarch64.pkg.tar.zst`.

## Сборка

Нужны: `bash`, `curl`, `tar`, `zstd`, `gzip`, `sha256sum`, `md5sum`,
`make`/`gcc` для хоста (OpenSSL собирается через perl) и кросс-тулчейн
[musl.cc](https://musl.cc/aarch64-linux-musl-cross.tgz).

```sh
# 1. тулчейн (Linux x86_64/aarch64 хост)
curl -fLO https://musl.cc/aarch64-linux-musl-cross.tgz
tar -xzf aarch64-linux-musl-cross.tgz -C "$HOME/.local/share"
export TC="$HOME/.local/share/aarch64-linux-musl-cross"
export PATH="$TC/bin:$PATH"

# 2. все пакеты -> ./out
./ci-build.sh

# 3. только некоторые
./ci-build.sh bash grep

# 4. база репозитория
./mkrepo.sh out
```

Результат:

```
out/bash-5.2.37-1-aarch64.pkg.tar.zst
...
out/nterminal.db.tar.gz
out/nterminal.files.tar.gz
out/nterminal.db -> nterminal.db.tar.gz
out/nterminal.files -> nterminal.files.tar.gz
```

`ci-build.sh` кладёт собранное в общий staging-префикс `.build/stage`,
поэтому `openssl` должен собираться раньше `openssh` — порядок по
умолчанию это учитывает, `openssh` ищет OpenSSL через `$OPENSSL_STAGE`.

### Упаковать дерево вручную

```sh
mkdir -p pkgroot/usr/bin
cp mytool pkgroot/usr/bin/
chmod 755 pkgroot/usr/bin/mytool
cat > pkgroot/.PKGINFO <<'EOF'
pkgname = mytool
pkgver = 1.0
pkgrel = 1
pkgdesc = Example tool
arch = aarch64
depend = bash
EOF
./build-pkg.sh pkgroot out
./mkrepo.sh out
```
### Формат базы

`nterminal.db.tar.gz` содержит каталоги `<name>-<pkgver>-<pkgrel>/desc`:

```
%FILENAME%
bash-5.2.37-1-aarch64.pkg.tar.zst

%NAME%
bash

%VERSION%
5.2.37-1

%DESC%
GNU Bourne-Again SHell (static, musl)

%CSIZE%
1234567

%ISIZE%
4567890

%MD5SUM%
...

%SHA256SUM%
...

%ARCH%
aarch64

%DEPENDS%

```

Если в `out/` лежит несколько версий одного пакета, `mkrepo.sh`
оставляет в базе старшую (version sort) и предупреждает об остальных.
`nterminal.files.tar.gz` содержит `<name>-<ver>/files` со списком путей
(каталоги — со слешем), этого достаточно для `pacman -F`.

## Публикация (CI)

Workflow `.github/workflows/repo.yml`:

1. кэширует и распаковывает `musl.cc/aarch64-linux-musl-cross.tgz`;
2. запускает `./ci-build.sh` (все 12 пакетов);
3. запускает `./mkrepo.sh out`;
4. публикует `out/` в `ntermun/main-repo`, ветка `gh-pages`, каталог `aarch64/`
   (`rsync -a --delete`, остальное содержимое ветки не трогается).

Нужен секрет **`MAIN_REPO_TOKEN`** в настройках `ntermun/packages`
(Settings → Secrets and variables → Actions → New repository secret).
`GITHUB_TOKEN` workflow не подходит: он не имеет прав на другой репозиторий.

Как выпустить токен:

1. GitHub → Settings → Developer settings → Fine-grained personal access tokens.
2. Repository access: только `ntermun/main-repo`.
3. Permissions: **Contents: Read and write** (больше ничего не нужно).
4. Скопировать токен в секрет `MAIN_REPO_TOKEN`.
5. (Опционально) classic PAT со scope `repo` тоже работает.

GitHub Pages включается один раз вручную:
`ntermun/main-repo` → Settings → Pages → Source: *Deploy from a branch* →
Branch: `gh-pages`, folder `/ (root)`. После первого запуска workflow
проверить `https://ntermun.github.io/main-repo/aarch64/nterminal.db.tar.gz`.

Первый запуск можно сделать вручную: Actions → `repo` → Run workflow.

## Подключение

`pacman.conf` (он же лежит в репозитории):

```ini
[options]
Architecture = aarch64
SigLevel = Never

[nterminal]
Server = https://ntermun.github.io/main-repo/aarch64
```

### Отдельный root (Termux/proot, без прав root)

```sh
root="$HOME/nterm-root"
mkdir -p "$root/var/lib/pacman" "$root/var/cache/pacman/pkg"

pacman --config ./pacman.conf --root "$root" \
       --dbpath "$root/var/lib/pacman" \
       --cachedir "$root/var/cache/pacman/pkg" -Sy

pacman --config ./pacman.conf --root "$root" \
       --dbpath "$root/var/lib/pacman" \
       --cachedir "$root/var/cache/pacman/pkg" -S bash coreutils

"$root/usr/bin/bash" --version
```

### Системная установка (rootfs/proot с pacman)

```sh
install -Dm644 pacman.conf /etc/pacman.conf
pacman -Sy
pacman -S bash coreutils grep sed gawk tar gzip findutils diffutils make openssl openssh
```

Пакеты ставятся в `/usr`, конфликтуют с системными GNU-утилитами того же
имени — для Android/Termux лучше отдельный root или `proot`.

## Обновление пакета

1. Поднять `pkgver`/`pkgrel` в `packages/<name>/PKGBUILD`
   (при смене исходника — обновить `source`; `sha256sums` можно оставить
   `SKIP`, CI тогда доверяет HTTPS-загрузке).
2. `./ci-build.sh <name> && ./mkrepo.sh out` локально для проверки.
3. Закоммитить и запушить в `main` — CI пересоберёт и опубликует.

## Ограничения

* **`SigLevel = Never`** — пакеты не подписаны (нет `pacman-key`, нет
  `.sig`-файлов). Доверие держится на HTTPS GitHub Pages и на том, что
  артефакты собирает CI. Для продакшена нужен отдельный ключ и
  `repo-add --sign`.
* **musl static** — бинари не используют glibc/bionic и не зависят от
  системных `.so`. Плюс: работают в Termux, proot, chroot и на старых
  Android. Минус: нет NSS/dlopen-модулей, `getpwnam`/DNS работают через
  musl, а не через Android-сервисы; размер бинарей больше.
* `depends` у большинства пакетов пустой (всё статически слинковано);
  `openssh` зависит от `openssl` только на уровне репозитория.
* Нет `.MTREE`, `.BUILDINFO`, `.INSTALL`, нет split-пакетов и debug-пакетов.
* `sha256sums=('SKIP')` в шаблонах: контрольные суммы не фиксируются,
  исходники берутся по HTTPS с ftp.gnu.org / openssl.org / openssh.com / zlib.net.
* Пакеты `bash`/`coreutils`/... конфликтуют по именам с системными —
  ставьте в отдельный root.
* Pages отдаёт статику: диапазонные запросы и `Last-Modified` есть, но
  rate limit GitHub Pages может мешать большим `-Syu`.

## Проверка

```sh
# содержимое пакета и метаданные
tar -tf out/bash-5.2.37-1-aarch64.pkg.tar.zst
tar -xOf out/bash-5.2.37-1-aarch64.pkg.tar.zst .PKGINFO

# база и запись о пакете
tar -tzf out/nterminal.db.tar.gz
tar -xOzf out/nterminal.db.tar.gz bash-5.2.37-1/desc

# файловая база
tar -xOzf out/nterminal.files.tar.gz bash-5.2.37-1/files

# совпадение контрольных сумм
sha256sum out/bash-5.2.37-1-aarch64.pkg.tar.zst
```
