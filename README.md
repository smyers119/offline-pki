# Offline PKI

This repository contains a simple (and opiniated) offline PKI system that can be
run from an ARM64 SBC, like the [Sweet Potato AML-S905X-CC-V2][potato].

[potato]: https://libre.computer/products/aml-s905x-cc-v2/

> [!CAUTION]
> This is a work in progress. Do not use yet!

## Installation

### With Nix

This repository can be used as a Flake.

- `nix shell`
- `nix run . -- --help`
- `nix run github:vincentbernat/offline-pki -- --help`

### Without Nix

Create a virtualenv and execute `pip install`:

```console
$ python -m venv .venv
$ source .venv/bin/active
$ pip install .
```

You may need `libpcsclite-dev` package.

### Image creation

To build the SD card image (targeted for the Sweet Potato):

```shell
nix build --system aarch64-linux .\#sdcard
```

To flash it:

```shell
zstdcat result/sd-image/nixos-sd-image-*-aarch64-linux.img.zst > /dev/sdc
```

You can get a serial console using the UART header. See [GPIO Pinout Header
Maps][] for Libre Computer boards. For the AML-S905X-CC-V2, 1 (at the edge) is
GND, 2 is TX and 3 is RX. When using a USB to TTL adapter, you need to swap RX
and TX.

The default speed is 115200. A good small serial tool is `tio`.

[gpio pinout header maps]: https://hub.libre.computer/t/gpio-pinout-header-maps-and-wiring-tool-for-libre-computer-boards/28

## Operations

### CA creation

You need three Yubikeys. Be sure to label them correctly.

 - Root 1
 - Root 2
 - Intermediate
 
For each Yubikey, run `offline-pki yubikey reset` to wipe them and configure PIN code,
PUK code, and management key. The same management key must be used for all root
keys. You may use more root keys as backups, as it is not possible to duplicate
a root key.

Then, execute `offline-pki certificate root` to initialize "Root 1" and "Root 2" (or
more of them). Then, use `offline-pki certificate intermediate` to initialize
"Intermediate".

For the root certificate, you can customize the subject name with the
`--subject-name` flag. The `offline-pki certificate intermediate` command also accepts a
subject-name (`CN=Intermediate CA` by default) and it will merge the missing
attributes from the root certificate. Therefore, by using the following
commands, the intermediate certificate will have `CN=Intermediate CA,O=Your
Organization,OU=Secret Unit,C=FR` as a subject name.

```console
$ offline-pki certificate root --subject-name "CN=Root CA,O=Your Organization,OU=Secret Unit,C=FR"
$ offline-pki certificate intermediate
```

You can check the result with `offline-pki yubikey info`.

You can do several intermediate CA, one per usage. There is no backup
intermediate as if it is destroyed or lost, you can just generate a new one
(clients have to trust the root certificate, not the intermediate ones).

### CSR signature

The last step is to sign some certificate request with the `offline-pki certificate
sign`. You can override the subject name with `--subject-name` and in this case,
the missing attributes are copied from the intermediate certificate. Otherwise,
the subject name from the CSR is used. Moreover, all extensions from the CSR are
copied over.

> [!CAUTION]
> As this tool does not display certificate content, it is important to check
> the content of the CSR before signing it:

```console
$ openssl req \
   -config /dev/null \
   -newkey ec:<(openssl ecparam -name secp384r1) -sha384 -nodes \
   -subj "/C=FR/O=Example SARL/OU=Network/CN=ipsec-gw1.example.com" \
   -addext "subjectAltName = DNS:ipsec-gw.example.com" \
   -addext "keyUsage = digitalSignature" \
   -keyform PEM -keyout server-key.pem -outform PEM -out server-csr.pem
$ openssl req -noout -text -in server-csr.pem
```

## Limitations

There are several limitations with this little PKI:

- not everything is configurable, notably the cryptography is hard-coded
- no CRL support (this is an offline PKI, while not impossible, this would be a pain)
- random serial numbers (no state is kept, except the certificates on the Yubikeys)

## Development

For development, one can either invoke a Nix shell with `nix develop` or spawn a
QEMU VM with `nix run .\#qemu`.

