# ntermun packages

Собственный pacman-репозиторий для Android-приложения **nnn.ntermun**.
Пакеты — **статические aarch64/musl** бинарники, которые ставятся в
`<files>/usr` и запускаются прямо из data-dir (exec разрешён на targetSdk 28).

Публикуется через GitHub Pages из репозитория `ntermun/main-repo`
(ветка `gh-pages`, каталог `aarch64/`):

```
https://ntermun.github.io/main-repo/aarch64/ntermun.db
https://ntermun.github.io/main-repo/aarch64/ntermun.files
```

Исходники приложения — <https://github.com/ntermun/ntermun>.

## Состав

| файл | назначение |
|---|---|
| `build-pkg.sh` | упаковка готового дерева файлов в `<name>-<ver>-<rel>-aarch64.pkg.tar.zst`; пишет `.PKGINFO`, выставляет `root:root` и права |
| `mkrepo.sh` | замена `repo-add`: `ntermun.db.tar.gz` + `ntermun.files.tar.gz` и симлинки `ntermun.db` / `ntermun.files` |
| `makepkg.sh` | мини-драйвер PKGBUILD: скачивание/проверка исходников, локальные патчи, `build()`, `package()`, strip, staging, вызов `build-pkg.sh` |
| `musl-env.sh` | общий env кросс-сборки (`aarch64-linux-musl-*`, `-static`) |
| `packages/<name>/PKGBUILD` | рецепты пакетов (см. таблицу ниже) |
| `pacman.conf` | конфиг для устройства |
| `out/aarch64/` | результат сборки (в git не попадает) |
| `work/` | исходники, staging, кэш (в git не попадает) |

### Пакеты

| пакет | что внутри | зависит от |
|---|---|---|
| `zlib` | libz.a + заголовки | — |
| `bzip2` | bzip2/bunzip2/bzcat + libbz2.a | — |
| `xz` | xz/unxz/lzma + liblzma.a | — |
| `zstd` | zstd/unzstd + libzstd.a | — |
| `openssl` | `openssl` CLI, libcrypto.a/libssl.a, `/etc/ssl/openssl.cnf` | — |
| `sqlite` | `sqlite3` + libsqlite3.a (база libalpm) | — |
| `ncurses` | libncursesw.a, terminfo, tic/infocmp | — |
| `libarchive` | libarchive.a (tar.zst/xz/gz/bz2) | zlib, bzip2, xz, zstd |
| `curl` | `curl` + libcurl.a (https, openssl, zlib) | openssl, zlib |
| `pacman` | `pacman`, `repo-add`, `makepkg`, `/etc/pacman.conf` | bash, libarchive, curl, openssl, ncurses |
| `bash` | `bash`, `/usr/bin/sh` | — |
| `coreutils` | один бинарь + 100 симлинков | — |
| `grep` `sed` `gawk` `diffutils` `findutils` `make` | GNU-утилиты | — |
| `tar` | GNU tar | gzip, xz, zstd |
| `gzip` | gzip/gunzip/zcat (патч под musl) | — |
| `openssh` | ssh, scp, sftp, ssh-keygen, ssh-agent | openssl, zlib |
| `openssh-server` | sshd + `sshd-session`/`sshd-sftp`, `/etc/ssh/sshd_config` | openssl, zlib |

## Требования к сборочной машине

* Linux x86_64/aarch64, bash, GNU tar, gzip, zstd, curl, coreutils.
* `meson`, `ninja`, `pkg-config` (нужны для pacman).
* Кросс-тулчейн:

  ```sh
  curl -fL -o /tmp/aarch64-linux-musl-cross.tgz \
    https://musl.cc/aarch64-linux-musl-cross.tgz
  tar -xzf /tmp/aarch64-linux-musl-cross.tgz -C "$HOME"
  export MUSL_CROSS="$HOME/aarch64-linux-musl-cross"   # если путь другой
  ```

* `fakeroot` не нужен: владелец задаётся в заголовках tar
  (`--owner=0 --group=0 --numeric-owner`), поэтому пакеты получаются
  `root:root` даже при сборке обычным пользователем.

## Сборка

Один пакет:

```sh
./makepkg.sh bash
```

Все пакеты в правильном порядке:

```sh
./makepkg.sh
```

Порядок важен: `curl`/`libarchive`/`pacman` собираются после `openssl`,
`zlib`, `xz`, `bzip2`, `zstd`, а `openssh*` — после `openssl` и `zlib`.
Промежуточные заголовки и `.a` складываются в `work/stage`, оттуда их
берут зависимые пакеты.

Пересобрать принудительно:

```sh
./makepkg.sh -f pacman
```

Результат: `out/aarch64/pacman-7.1.0-1-aarch64.pkg.tar.zst`.
Уже собранные пакеты пропускаются, поэтому CI может переиспользовать кэш.

`makepkg.sh` — не полный makepkg: нет split-пакетов, разрешения зависимостей,
подписи и `.SRCINFO`. Он намеренно простой, чтобы репозиторий собирался без
pacman.

### Версии и контрольные суммы

Версии в `PKGBUILD` — актуальные на момент создания шаблонов. При обновлении
меняйте `pkgver` и **обязательно** подставляйте реальные `sha256sums`
(сейчас стоит `SKIP`, чтобы шаблоны не ломались на первом запуске):

```sh
curl -fLO https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz
sha256sum bash-5.3.tar.gz
```

### Патчи

Локальный файл в `source=(...)` берётся рядом с `PKGBUILD` (скачивать не
надо) и применяется к распакованному дереву через `patch -p1`. Так собирается
`gzip` (`packages/gzip/gzip-1.15-musl-head-macro.patch`: musl объявляет
`struct _aarch64_ctx head;` в `<bits/signal.h>`, а gzip определяет макрос
`head`).

## Упаковка вручную

Если бинарник уже собран, достаточно подготовить дерево и вызвать упаковщик:

```sh
mkdir -p /tmp/pkg/usr/bin
cp ./hello /tmp/pkg/usr/bin/hello
chmod 0755 /tmp/pkg/usr/bin/hello

./build-pkg.sh \
  -n hello -v 1.0 -r 1 -a aarch64 \
  -d "Test static musl binary" \
  -C /tmp/pkg -o out/aarch64
```

`build-pkg.sh` сам нормализует права: каталоги `0755`, исполняемые файлы
`0755`, остальные `0644`. `.MTREE` не создаётся — для pacman он
необязателен.

## Обновление репозитория

После добавления/пересборки пакетов:

```sh
./mkrepo.sh                 # сканирует out/aarch64
./mkrepo.sh -o /path/to/dir # или явный каталог
```

`mkrepo.sh` для каждого пакета создаёт запись `<name>-<version>/desc`
(`FILENAME`, `NAME`, `BASE`, `VERSION`, `DESC`, `CSIZE`, `ISIZE`, `MD5SUM`,
`SHA256SUM`, `ARCH`, `DEPENDS`, …) и `<name>-<version>/files` со списком
файлов для `pacman -F`. База пересоздаётся целиком, поэтому удалённые из
каталога пакеты исчезают из индекса.

## Публикация

CI `.github/workflows/repo.yml`:

1. кэширует тулчейн musl.cc;
2. кэширует `work/src-cache` и `out` по хэшу `packages/**/PKGBUILD`;
3. собирает пакеты, вызывает `mkrepo.sh`;
4. пушит `out/aarch64/` в `ntermun/main-repo`, ветка `gh-pages`.

Для шага публикации нужен секрет **`MAIN_REPO_TOKEN`** (токен с правом
записи в `ntermun/main-repo`). После первого запуска включите Pages:
**Settings → Pages → Source: Deploy from a branch → `gh-pages` / `/`**
в репозитории `main-repo`.

Локальная публикация вручную:

```sh
./mkrepo.sh
git clone --branch gh-pages https://github.com/ntermun/main-repo.git pages
rsync -a --delete out/aarch64/ pages/aarch64/
cd pages && git add -A && git commit -m "repo: rebuild" && git push
```

## Подключение на устройстве

`pacman.conf` кладётся в `<files>/etc/pacman.conf` (он же приходит в
пакете `pacman`):

```ini
[options]
Architecture = aarch64
SigLevel = Never

[ntermun]
Server = https://ntermun.github.io/main-repo/aarch64
```

Корень pacman — каталог приложения, пакеты ставятся в `/usr` внутри него:

```sh
PREFIX=/data/data/nnn.ntermun/files
$PREFIX/usr/bin/pacman --root "$PREFIX" -Sy
$PREFIX/usr/bin/pacman --root "$PREFIX" -S bash coreutils pacman
$PREFIX/usr/bin/pacman --root "$PREFIX" -Q
```

`-Sy` скачивает `ntermun.db`; `-S <pkg>` — пакет и его `DEPENDS`.
`pacman -Fy`/`-F` работают по `ntermun.files`.

## Ограничения

* **Только musl, только статика.** Все бинарники собраны
  `aarch64-linux-musl-gcc` с `-static`. glibc/Arch-пакеты не подходят:
  на устройстве нет glibc и нет динамического линковщика musl.
* **Нет подписи.** `SigLevel = Never`; база и пакеты не подписаны. Это
  осознанно: CI собирает всё из исходников, но целостность проверяется
  только по `SHA256SUM` из базы.
* **Нет .MTREE.** Pacman принимает такие пакеты, но `pacman -Qkk` не сможет
  проверить mtree-метаданные.
* **Версии/хэши в шаблонах** требуют проверки при обновлении; `sha256sums`
  сейчас `SKIP`.
* **Staging, а не sysroot.** `makepkg.sh` копирует результат каждого пакета
  в `work/stage`, поэтому зависимые пакеты видят заголовки и `.a`, но
  произвольные системные библиотеки в stage не попадают.
* **pacman без gpgme и seccomp**: подпись пакетов и file-seccomp отключены
  при сборке (`-Dgpgme=disabled -Dfile-seccomp=disabled`).
