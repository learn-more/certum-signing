# certum-signing

Authenticode signing for Windows binaries with a [Certum](https://www.certum.eu/) code signing certificate, as one
GitHub Action plus the PowerShell that does the work.

The certificate is not a file: it lives in Certum's cloud HSM and is reached through SimplySign Desktop, which
emulates a local smart card reader and registers the certificate into `Cert:\CurrentUser\My` once a session is
open. `signtool` then uses it by thumbprint like any other. Doing that unattended - installing SimplySign,
generating the TOTP code, logging in, waiting for the certificate, signing, and proving afterwards that the files
really came out signed - is about 700 lines of PowerShell that every repository would otherwise carry its own
drifting copy of.

**Signing is optional, everywhere.** A repository without the settings still builds a release; it just comes out
unsigned and says so. Nothing has to be configured for a fork, or a PR build, or a project that has no account
yet. See [SIGNING.md](SIGNING.md) for what to store and where to get it.

## GitHub Actions

```yaml
- uses: learn-more/certum-signing@v1
  with:
    path: |
      dist/MyApp-x86.exe
      dist/MyApp-x64.exe
    description: MyApp - does the thing
    notes-path: release-notes.md
    otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    username: ${{ secrets.CERTUM_USERNAME }}
    certificate-sha1: ${{ vars.CERTUM_CERTIFICATE_SHA1 }}
```

That one step installs SimplySign, opens the session, signs, and reports - the last part whether signing happened
or not. It leaves `SIGNING_STATUS` and `SIGNING_SUMMARY` in the environment for the steps that follow, so a
`SHA256SUMS.txt` header or a release body can quote them.

### Inputs

| Input | Required | Default |
| --- | --- | --- |
| `path` | except in `setup` | - |
| `embedded-path` | no | - |
| `description` | no | the binary's own `FileDescription` |
| `description-url` | no | this repository's URL |
| `notes-path` | no | no notes written |
| `require-signed` | no | `auto` |
| `stage` | no | `all` |
| `otp-uri` | to sign | - |
| `username` | to sign | - |
| `certificate-sha1` | to sign | - |
| `timestamp-server` | no | `http://time.certum.pl` |
| `intermediate-url` | no | `https://repository.certum.pl/ccsca2021.cer` |

`path` and `embedded-path` take a newline- or comma-separated list.

`require-signed: auto` means: fail if signing was configured and a file still came out unsigned, pass if it was
never configured. That is the guard that stops a release shipping while claiming to be signed.

### Outputs

| Output | |
| --- | --- |
| `signing` | `true` when all three settings were present, so signing was attempted |
| `status` | `signed`, `partial` or `unsigned`, read back off the files |
| `summary` | one-line human-readable version of the above |

### Stages

A build that signs at the end needs one call and `stage: all`, the default. Split it when something has to be
signed *before* the build that embeds it - sign an unsigned helper afterwards and the copy inside the download
stays unsigned:

```yaml
- uses: learn-more/certum-signing@v1        # log in once
  with: { stage: setup, otp-uri: ..., username: ..., certificate-sha1: ... }

- uses: learn-more/certum-signing@v1        # sign the helper
  with: { stage: sign, path: build/helper.exe, certificate-sha1: ..., otp-uri: ..., username: ... }

- run: msbuild ...                          # embeds the signed helper

- uses: learn-more/certum-signing@v1        # sign the download, then report on both
  with:
    stage: all
    path: dist/MyApp.exe
    embedded-path: extracted/helper.exe
    otp-uri: ...
```

An unsigned helper inside a signed download fails the run: it means that ordering broke.

One session covers all of it. Do not split the signing across two logins if it can be helped - a second
`/autologin` inside the same 30-second TOTP step reuses the code, and Certum may refuse it.

## AppVeyor

AppVeyor cannot consume a composite action, so add this repository as a submodule and call the wrapper, which
does the same sequence in one script:

```bash
git submodule add https://github.com/learn-more/certum-signing.git ci/signing
```

```yaml
install:
  - git submodule update --init --recursive

after_build:
  # Sign before zipping. No-op unless this is a tag build with the CERTUM_* variables set.
  - ps: .\ci\signing\scripts\appveyor-sign.ps1 -Path "bin\MyApp-x86.exe", "bin\MyApp-x64.exe"

deploy:
  - provider: GitHub
    auth_token: $(GITHUB_AUTH_TOKEN)
    description: $(SIGNING_NOTES)     # set by signing-status.ps1
    draft: true
    on:
      APPVEYOR_REPO_TAG: true
```

The credentials go in the AppVeyor project settings as padlocked environment variables, under the same
`CERTUM_*` names. Only tag builds sign: a run downloads a 260 MB installer and spends a one-time code, and branch
builds are never published. `-Force` overrides that for testing.

Note that AppVeyor leaves secure variables undecrypted on pull request builds, which is indistinguishable from
"not configured" and gets the same handling - build, do not sign, say so.

## The scripts

Callable on their own, and by the wrapper and the action above.

| Script | Does |
| --- | --- |
| [`scripts/install-simplysign.ps1`](scripts/install-simplysign.ps1) | Installs SimplySign Desktop, pinned by version and SHA-256. |
| [`scripts/configure-simplysign.ps1`](scripts/configure-simplysign.ps1) | Registry settings that keep the session usable unattended for the length of a build. |
| [`scripts/connect-simplysign.ps1`](scripts/connect-simplysign.ps1) | Generates the TOTP code, logs in with it, and waits for the certificate to appear in the store. `-SelfTest` checks the generator against RFC 6238 and exits. |
| [`scripts/sign-files.ps1`](scripts/sign-files.ps1) | `signtool sign` with SHA-256 and an RFC 3161 timestamp, then verifies the result. |
| [`scripts/signing-status.ps1`](scripts/signing-status.ps1) | Reports the outcome to the log, the job summary or Messages tab, the release notes, and the environment. |
| [`scripts/appveyor-sign.ps1`](scripts/appveyor-sign.ps1) | The four above in order, with AppVeyor's tag and credential checks in front. |

## Versioning

Tagged `v1.0.0`, with `v1` moved to the newest release on that major line. Consumers pin `@v1` and get fixes;
anything that changes what an existing caller has to pass moves to `v2`.

`main` is not a stable reference. `selftest.yml` runs the RFC 6238 vectors, PSScriptAnalyzer, and the action
itself against files with a known signature state on every push, but the login can only be exercised by a real
release in a real repository.

## Used by

[BadApp](https://github.com/learn-more/BadApp) ·
[DepCheck](https://github.com/learn-more/DepCheck) ·
[JobDebug](https://github.com/learn-more/JobDebug) ·
[MemView](https://github.com/learn-more/MemView) ·
[WindowsHookEx](https://github.com/learn-more/WindowsHookEx)
