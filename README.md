# GNU MCU Eclipse RISC-V Embedded GCC build

These are the additional files required by the [GNU MCU Eclipse RISC-V Embedded GCC](https://github.com/gnu-mcu-eclipse/riscv-gcc) build procedures.

This release closely follows the official [RISC-V distribution](https://github.com/riscv/riscv-gcc) maintained by [SiFive](https://www.sifive.com).

The current version is based on project [riscv/riscv-gnu-toolchain](https://github.com/riscv/riscv-gnu-toolchain), tag v20170612 (commit [f5fae1c](https://github.com/riscv/riscv-gnu-toolchain/tree/f5fae1c27b2365da773816ddcd92f533867f28ec)) from June 12th, which depends on the following:

- the [riscv/riscv-gcc](https://github.com/riscv/riscv-gcc) project, commit [16210e6](https://github.com/riscv/riscv-gcc/commit/16210e6270e200cd4892a90ecef608906be3a130) from from May 15th, 2017
- the [riscv/riscv-binutils-gdb](https://github.com/riscv/riscv-binutils-gdb) project, commit [3f21b5c](https://github.com/riscv/riscv-binutils-gdb/commit/3f21b5c9675db61ef5462442b6a068d4a3da8aaf) from May 5th, 2017
- the [riscv/riscv-newlib](https://github.com/riscv/riscv-newlib) project, commit [ccd8a0a](https://github.com/riscv/riscv-newlib/commit/ccd8a0a4ffbbc00400892334eaf64a1616302b35) from May 2nd, 2017

## Changes

Compared to the original RISC-V version, there are no functional changes; the **same architecture and API** options are supported, and the same combinations of libraries (derived from newlib) are provided.

## newlib-nano

The only notable addition is support for **newlib-nano**, using the `--specs=nano.specs` option. For better results, this option must be added to both compile and link time (the next release of the GNU MCU Eclipse plug-ins will add support for this).

If no syscalls are needed, `--specs=nosys.specs` can be used at link time to provide empty implementations for the POSIX system calls.

The _nano_ versions of the libraries are compiled with `-Os -mcmodel=medlow`, while the regular versions are compiled with `-O2 -mcmodel=medany`.

## Documentation

Another addition compared to the SiFive distribution is the presence of the documentation, including the PDF manuals for all tools.

## How to build

```bash
$ git clone https://github.com/gnu-mcu-eclipse/riscv-none-gcc-build.git ~/Downloads/riscv-none-gcc-build.git
$ bash ~/Downloads/riscv-none-gcc-build.git/scripts/build.sh --all
```

Warning: with 5 separate distributions, this will take many hours, even on a fast machine.

## Folders

For consistency with other projects, all files are grouped under `gnu-mcu-eclipse`.

* `gnu-mcu-eclipse/info` - informative files copied to the distributed `info` folder;
* `gnu-mcu-eclipse/nsis` - files required by [NSIS (Nullsoft Scriptable Install System)](http://nsis.sourceforge.net/Main_Page);
* `scripts/build.sh` - the build script.

## Files

* `VERSION` - the stable build version file. Its content looks like `7.1.1-2`, where `7.1.1` is the official GCC version, and `2` is the GNU MCU Eclipse RISC-V GCC release number.
* `VERSION-dev` - the development build version file.