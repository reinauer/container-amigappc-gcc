# Containerfile for ADTools ppc-amigaos-gcc

This builds a PowerPC AmigaOS cross compiler from
[sba1/adtools](https://github.com/sba1/adtools). It follows the upstream
cross-only path: checkout ADTools binutils and GCC patches with `gild`, then
run `make -C native-build gcc-cross`.

Defaults:

- ADTools GCC branch: `8`
- ADTools binutils branch: `2.23.2`
- AmigaOS SDK version: `54.16`
- Install prefix: `/opt/amiga-ppc`
- Target compiler: `ppc-amigaos-gcc`

## Container Build

```sh
docker build -t amigappc-gcc .
```

To override ADTools or SDK inputs:

```sh
docker build \
  --build-arg ADTOOLS_GCC_BRANCH=8 \
  --build-arg ADTOOLS_BINUTILS_BRANCH=2.23.2 \
  --build-arg SDK_VERSION=54.16 \
  --build-arg SDK_URL="https://example.invalid/SDK_54.16.lha" \
  --build-arg CROSS_PREFIX=/opt/amiga-ppc \
  -t amigappc-gcc .
```

Then compile from the image:

```sh
docker run --rm -v "$PWD:/work" -w /work amigappc-gcc \
  ppc-amigaos-gcc test/hello.c -o hello
```

## macOS Build

```sh
./build_mac.sh
```

The macOS script installs Homebrew dependencies, builds `lha` from source, and
installs the ADTools cross compiler into `/opt/adtools` by default.

Useful options:

```sh
./build_mac.sh --prefix "$HOME/opt/adtools"
./build_mac.sh --sdk-version 54.16
./build_mac.sh --sdk-url "https://example.invalid/SDK_54.16.lha"
./build_mac.sh --sdk-archive "$HOME/Downloads/SDK_54.16.lha"
./build_mac.sh --gcc-branch 8 --binutils-branch 2.23.2
```

`--sdk-archive` is useful when you already have a local AmigaOS SDK archive.
The archive is staged into the ADTools build tree and reused by the patched
download rule.
