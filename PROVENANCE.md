# Release provenance

JYNERATION ships a checksum manifest at `SHA256SUMS.txt`. It proves that the
files in a checkout match the published build, while `CREDITS.json` and
`NOTICE.md` carry the author and license attribution with the source.

Copyright (c) 2026 saj.

The beta workspace is intentionally marked `unsigned-local-build` because no
private signing key is stored in the repository. For an official release,
sign the manifest outside the repository and publish the detached signature
alongside it:

```text
openssl dgst -sha256 -sign release-private-key.pem -out SHA256SUMS.txt.sig SHA256SUMS.txt
openssl dgst -sha256 -verify release-public-key.pem -signature SHA256SUMS.txt.sig SHA256SUMS.txt
```

Never commit a private key. Update the `signature_status` and
`signature_file` fields in `CREDITS.json` only in the release package after
the detached signature has been produced.

This is provenance and attribution, not a hidden tracker. Anyone can modify a
copy, but preserving `LICENSE`, `NOTICE.md`, and the signed manifest makes the
official source and author clear and verifiable.
