# Offline PKI

This repository contains a simple (and opiniated) offline PKI system that can be
run from an ARM64 SBC, like the [Sweet Potato AML-S905X-CC-V2][potato].

[potato]: https://libre.computer/products/aml-s905x-cc-v2/

> [!CAUTION]
> This is a work in progress. Do not use yet!

## Operations

### CA creation

You need three Yubikeys. Be sure to label them correctly.

 - Root 1
 - Root 2
 - Intermediate
 
For each Yubikey, run `pki yubikey reset` to wipe them and configure PIN code,
PUK code, and management key. The same management key must be used for "Root 1"
and "Root 2".

Then, execute `pki certificate root` to initialize "Root 1" and "Root 2" (or
more of them). Then, use `pki certificate intermediate` to initialize
"Intermediate".

### CSR signature

## Image creation

To build the SD card image:

```shell
nix build --system aarch64-linux .\#sdcard
```

To flash it:

```shell
zstdcat result/sd-image/nixos-sd-image-*-aarch64-linux.img.zst > /dev/sdc
```

## Development

For development, one can either invoke a Nix shell with `nix develop` or spawn a
QEMU VM with `nix run .\#qemu`.
