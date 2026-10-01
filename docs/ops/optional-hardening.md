# Optional Hardening — LUKS & Overlayroot

These are NOT installed by Plan 1. They are documented for operators who want to opt in later.

## LUKS — Encrypted SD Card
Pros: stolen SD can't be read elsewhere. Cons: needs serial-console passphrase entry or dropbear-initramfs for remote unlock; ~5-15% I/O slowdown.

## Overlayroot — Read-Only Root
Pros: runtime tamper-proof, less SD wear. Cons: updates require disabling overlayroot temporarily.

## Recommendation
Skip both for now. Revisit after Plan 12 ships.
