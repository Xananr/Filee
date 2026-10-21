# Building a local macOS app bundle

`build/build-portable.ps1` is the official packager. It needs PowerShell 7 and
downloads the pinned engines. If you only want a Filee.app you can double-click
on your own Mac - and you do not have an Apple Developer account - use
`build/build-macos-local.sh` instead.

It performs the same bundle assembly as the PowerShell script (publish, Info.plist,
icns, localisations, engines, per-file signing) with the tools that ship with
macOS, then signs the result with a self-signed certificate that your own Mac
trusts.

```bash
./build/build-macos-local.sh --install
```

Options:

| Flag | Effect |
| --- | --- |
| `--install` | copy the result to `~/Applications/Filee.app` (a previous copy is moved to the Trash) |
| `--engines DIR` | copy the `engines` folder from an existing `Filee.app/Contents/MacOS/engines` |
| `--identity NAME` | sign with another Keychain identity; `-` produces an ad-hoc signature |

The build is staged under `build/.cache/local/`, which is git-ignored.

`pandoc`, `calibre` and `libreoffice` are not bundled by either script; the app
downloads them on demand. Only `7zip` and `rhwp` have to be present, which is why
the script can reuse them from an existing installation.

## One-time: create the signing certificate

A self-signed certificate keeps the code identity stable across rebuilds. Without
one, every build is ad-hoc signed with a different CDHash, and macOS treats each
build as a brand new application - which means re-granting Accessibility every
time.

Use `/usr/bin/openssl` (LibreSSL). OpenSSL 3 from Homebrew or MacPorts exports
PKCS#12 with a MAC algorithm the macOS Security framework rejects
(`security import` fails with `MAC verification failed`).

```bash
mkdir -p ~/.filee-signing && cd ~/.filee-signing
chmod 700 .

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=Filee Local Signing" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
chmod 600 key.pem cert.pem

/usr/bin/openssl pkcs12 -export -out filee.p12 -inkey key.pem -in cert.pem \
  -passout pass:fileepass

security import filee.p12 -k ~/Library/Keychains/login.keychain-db -P fileepass \
  -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db cert.pem

security find-identity -v -p codesigning    # expect: "Filee Local Signing"
```

`security add-trusted-cert` asks for your login password once. So does the first
`codesign` call: choose **Always Allow** in the Keychain prompt, otherwise every
one of the ~380 nested files prompts again.

## Why the build needs extra steps

Two failures are not obvious from the PowerShell script:

* **Executable bits on managed assemblies.** `dotnet publish` marks a few
  `.dll` files executable. `codesign` then treats them as nested code and refuses
  to sign the main executable with `In subcomponent: .../System.Net.Security.dll`.
  The script clears the bit on every file that is not a Mach-O binary.
* **`--timestamp`.** The official script adds `--timestamp --options runtime`
  for Developer ID identities. A self-signed certificate has no Apple timestamp
  chain, so the local script signs without them.

## Gatekeeper and Accessibility

`spctl -a -t exec ~/Applications/Filee.app` reports `rejected` for any
self-signed bundle - Gatekeeper only accepts Apple-issued Developer IDs. That is
not a build failure: the assessment only runs when the bundle carries
`com.apple.quarantine`, which the script removes after installing. Double-clicking
works normally.

The quarantine attribute comes back if you re-download the app, receive it over
AirDrop, or unpack it from an archive. Clear it again with:

```bash
xattr -dr com.apple.quarantine ~/Applications/Filee.app
```

Accessibility and Input Monitoring permissions are bound to the code identity
(`CDHash`), not to the bundle path or the bundle identifier. Changing the signing
identity - for example building once with `--identity -` and once with the
certificate - leaves a stale checkbox in System Settings that looks granted while
`AXIsProcessTrusted()` still returns false, and the Option-key gesture never
fires. Reset the stale records and grant again:

```bash
tccutil reset Accessibility com.filee.app
tccutil reset ListenEvent com.filee.app
```

Stick to one identity for all local builds and this only happens once.
