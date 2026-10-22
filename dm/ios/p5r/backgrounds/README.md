# Local menu backgrounds

Put the user-provided artwork in this directory as `MenuBackground-iPhone.png`
and `MenuBackground-iPad.png`. Both files must be present together. PNGs are
ignored by Git and must stay local.

`build_shell.py` copies the pair into the app when available and records their
SHA-256 hashes separately from the executable source fingerprint. Public CI
uses the plain fallback background without these files. When assembling a local
IPA from a public CI shell, also copy the pair into `Payload/P5RMobile.app/`
before signing.

The launcher chooses by device family, centers and scales the image to fill the
whole screen without stretching, and shades the text and bottom control areas.
