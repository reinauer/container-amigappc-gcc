FROM ubuntu:22.04

ARG ADTOOLS_REPO_URL=https://github.com/sba1/adtools.git
ARG ADTOOLS_GCC_BRANCH=8
ARG ADTOOLS_BINUTILS_BRANCH=2.23.2
ARG SDK_VERSION=54.16
ARG SDK_URL
ARG CROSS_PREFIX=/opt/amiga-ppc

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get -y update && \
    apt-get -y install \
      apt-utils \
      autoconf \
      automake \
      bison \
      bzip2 \
      ca-certificates \
      curl \
      file \
      flex \
      g++ \
      gcc \
      gettext \
      git \
      libgmp-dev \
      libmpc-dev \
      libmpfr-dev \
      libtool \
      m4 \
      make \
      patch \
      perl \
      python3 \
      python3-mako \
      rsync \
      tar \
      texinfo \
      wget \
      xz-utils

# ADTools requires lha, not lhasa. Build the jca02266/lha port so the
# SDK extraction path matches upstream's documented dependency.
RUN cd /tmp && \
    git clone --depth 1 https://github.com/jca02266/lha.git && \
    cd lha && \
    autoreconf -vfi && \
    ./configure --prefix=/usr && \
    make -j "$(nproc)" && \
    make install && \
    rm -rf /tmp/lha

RUN git clone --depth 1 "${ADTOOLS_REPO_URL}" /root/adtools && \
    cd /root/adtools && \
    git config --global user.email builder@example.invalid && \
    git config --global user.name "Container Builder" && \
    git submodule update --init --recursive gild && \
    printf '%s\n' https://sourceware.org/git/binutils-gdb.git > binutils/repo.url && \
    export GIT_COMMITTER_NAME='ADTools Builder' GIT_COMMITTER_EMAIL='adtools-builder@localhost' && \
    gild/bin/gild-checkout binutils "${ADTOOLS_BINUTILS_BRANCH}" && \
    gild/bin/gild-checkout gcc "${ADTOOLS_GCC_BRANCH}" && \
    test "$(git -C binutils/repo rev-list --count "${ADTOOLS_BINUTILS_BRANCH}-base..HEAD")" -gt 0 && \
    test "$(git -C gcc/repo rev-list --count "${ADTOOLS_GCC_BRANCH}-base..HEAD")" -gt 0 && \
    grep -Fq 'targ_defvec=bfd_elf32_amigaos_vec' binutils/repo/bfd/config.bfd && \
    test -f gcc/repo/gcc/config/rs6000/amigaos.c && \
    cp /usr/share/misc/config.guess /usr/share/misc/config.sub binutils/repo/ && \
    cp /usr/share/misc/config.guess /usr/share/misc/config.sub gcc/repo/ && \
    python3 -c 'from pathlib import Path; p=Path("binutils-build/Makefile"); lines=p.read_text().splitlines(True); idx=next(i for i,l in enumerate(lines) if "--enable-plugins" in l); indent=lines[idx].split("--",1)[0]; wanted=[f"{indent}--disable-nls \\\n", f"{indent}--disable-werror \\\n"]; window="".join(lines[idx + 1:idx + 8]); lines[idx + 1:idx + 1]=[line for line in wanted if line.strip().split()[0] not in window]; p.write_text("".join(lines))' && \
    python3 -c 'from pathlib import Path; p=Path("gcc/repo/gcc/config.host"); text=p.read_text(); insert="  aarch64*-*-darwin* | arm*-*-darwin*)\n    out_host_hook_obj=\"${out_host_hook_obj} host-i386-darwin.o\"\n    host_xmake_file=\"${host_xmake_file} i386/x-darwin\"\n    ;;\n"; anchor="  i[34567]86-*-darwin* | x86_64-*-darwin*)\n    out_host_hook_obj=\"${out_host_hook_obj} host-i386-darwin.o\"\n    host_xmake_file=\"${host_xmake_file} i386/x-darwin\"\n    ;;\n"; p.write_text(text.replace(anchor, insert + anchor)) if insert not in text else None' && \
    python3 -c 'from pathlib import Path; p=Path("gcc/repo/gcc/config/host-darwin.c"); text=p.read_text(); old="static char pch_address_space[1024*1024*1024] __attribute__((aligned (4096)));"; new="static char pch_address_space[1024*1024*1024] __attribute__((aligned (16384)));"; p.write_text(text.replace(old, new)) if old in text else None' && \
    python3 -c 'from pathlib import Path; p=Path("gcc-build/Makefile"); lines=p.read_text().splitlines(True); idx=next(i for i,l in enumerate(lines) if "--prefix=$(PREFIX)" in l); indent=lines[idx].split("--",1)[0]; window="".join(lines[idx + 1:idx + 6]); lines.insert(idx + 1, f"{indent}--disable-nls \\\n") if "--disable-nls" not in window else None; p.write_text("".join(lines))'

RUN cd /root/adtools && \
    mkdir -p "${CROSS_PREFIX}" && \
    if [[ -n "${SDK_URL}" ]]; then \
      make -C native-build -j "$(nproc)" gcc-cross \
        CROSS_PREFIX="${CROSS_PREFIX}" \
        SDK_VERSION="${SDK_VERSION}" \
        SDK_URL="${SDK_URL}"; \
    else \
      make -C native-build -j "$(nproc)" gcc-cross \
        CROSS_PREFIX="${CROSS_PREFIX}" \
        SDK_VERSION="${SDK_VERSION}"; \
    fi

RUN test -x "${CROSS_PREFIX}/bin/ppc-amigaos-gcc" && \
    "${CROSS_PREFIX}/bin/ppc-amigaos-gcc" --version | head -n 1 && \
    rm -rf /root/adtools /var/lib/apt/lists/*

ENV ADTOOLS_PREFIX="${CROSS_PREFIX}"
ENV PATH="${CROSS_PREFIX}/bin:${PATH}"

WORKDIR /work

LABEL adtools.repo="${ADTOOLS_REPO_URL}"
LABEL adtools.gcc_branch="${ADTOOLS_GCC_BRANCH}"
LABEL adtools.binutils_branch="${ADTOOLS_BINUTILS_BRANCH}"
LABEL adtools.sdk_version="${SDK_VERSION}"
