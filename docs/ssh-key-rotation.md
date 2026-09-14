# SSH key rotation

The Bitwarden item and GitHub identity setup are defined in
[bootstrap](../BOOTSTRAP.md#bitwarden-ssh-key-item). To replace that identity:

1. Generate a replacement Ed25519 key on a trusted machine.
2. Update the Bitwarden item notes with the replacement private key and the
   `public_key` custom field with its matching public key.
3. Register the replacement in GitHub as both an Authentication Key and a
   Signing Key.
4. Unlock Bitwarden and run `chezmoi apply` on each workstation.
5. Perform the [key-pair and SSH checks](../BOOTSTRAP.md#lightweight-verification).
6. Remove the old GitHub Authentication Key and Signing Key only after every
   workstation has the replacement.

Keep private keys out of documentation, shell history, and repository files.
