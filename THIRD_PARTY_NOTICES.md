# Third-party notices

The app links dynamically to these libraries. The build script downloads their
source archives from the upstream projects and checks the published archive
hashes before building them.

| Library | Version | License | Source |
| --- | --- | --- | --- |
| libmtp | 1.1.23 | GNU LGPL 2.1 | <https://sourceforge.net/projects/libmtp/> |
| libusb | 1.0.30 | GNU LGPL 2.1 | <https://github.com/libusb/libusb> |

Their license texts are included in [`LICENSES/`](LICENSES/). The MIT license
in [`LICENSE`](LICENSE) applies to Kindle USB's original source and app icon;
it does not replace the licenses for these third-party libraries.

This repository publishes source code only. It does not publish a prebuilt app
or the dependency libraries. If app bundles are published later, include the
required library notices and make the corresponding library source available
under the LGPL terms.

Kindle USB modifies libmtp on 2026-10-02 to skip endpoint status probes after a
successful Amazon session close and bound their timeouts after a failed close.
The upstream forced-reset behavior is retained. The reproducible source patch is
`scripts/patches/libmtp-kindle-close-timeout.patch`; the dependency build script
applies it to the checksum-verified upstream source.
