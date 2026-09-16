# Pinned tool hashes

Each `.sha256` file here holds the SHA256 of a third-party build tool. The build scripts refuse to
run a tool that doesn't match its pin, so a swapped or updated binary can't silently change what
gets compiled into the exe.

| Pin file | Tool | Checked by |
| --- | --- | --- |
| `gdre_tools.sha256` | `tools\gdre\gdre_tools.exe` (GDRE Tools v2.6.4) | `tools\build.ps1` |

`csc.exe` and `git.exe` aren't pinned. `build_installer.ps1` checks that Windows reports a valid
Microsoft signature on `csc.exe`, and every build records the signer of the `git.exe` it used.

## Creating or updating a pin

1. Download the tool yourself from its official release page, not from a mirror or a copy someone sent you.
2. Run `tools\build.ps1` once. It stops and prints the tool's current SHA256.
3. If that's the file you meant to trust, write the hash into the pin file:

   ```powershell
   Set-Content -Encoding ASCII -LiteralPath tools\pins\gdre_tools.sha256 -Value <hash>
   ```

4. Commit the pin file, so everyone building from this repo uses the same binary.
