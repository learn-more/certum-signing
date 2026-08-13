# Code signing

Release binaries are Authenticode signed with a Certum code signing certificate. The certificate is not a file:
it lives in Certum's cloud HSM, reached through SimplySign Desktop, which emulates a local smart card reader and
registers the certificate into `Cert:\CurrentUser\My` once a session is open. `signtool` then uses it by
thumbprint like any other certificate.

**Signing is optional.** A repository without the settings below still builds a release - it just comes out
unsigned, and says so (see [Where the status shows up](#where-the-status-shows-up)). Nothing has to be configured
to cut a release; configure it when there is an account to configure it with.

Only the release workflow should sign. A CI or pull request workflow should not: builds from forks cannot see
secrets anyway, and every signature costs a login to a certificate that is meant for artifacts people actually
download.

## What to store

**Settings → Secrets and variables → Actions → Secrets** (repository secrets). Both are credentials for the
SimplySign account, and neither is recoverable once stored.

| Secret | What it is |
| --- | --- |
| `CERTUM_USERNAME` | The SimplySign account name - the e-mail address used to log into SimplySign Desktop. |
| `CERTUM_OTP_URI` | The **whole** `otpauth://totp/...` URI from SimplySign enrolment, including `?secret=...`. Not just the secret, and not the six digits the app is showing. |

**Settings → Secrets and variables → Actions → Variables** (repository variables).

| Variable | Required | What it is / default |
| --- | --- | --- |
| `CERTUM_CERTIFICATE_SHA1` | yes | SHA-1 thumbprint of the code signing certificate, 40 hex characters. Spaces are stripped, case does not matter. Not a secret: a thumbprint is a public identifier, printed in every signed binary and in the certificate dialog, so it is a variable - readable in the workflow log, where a wrong one is much easier to spot than a masked `***`. |
| `CERTUM_TIMESTAMP_SERVER` | no | `http://time.certum.pl` |
| `CERTUM_INTERMEDIATE_URL` | no | `https://repository.certum.pl/ccsca2021.cer` |

The two secrets and `CERTUM_CERTIFICATE_SHA1` are all required together; missing any one of the three turns
signing off for the whole workflow.

On a personal GitHub account these are per-repository, and have to be stored again for every project that signs.
An organisation can store them once as organisation secrets and variables and grant them to selected
repositories; that is the only way GitHub shares them. On AppVeyor the same three names go in the project's
environment variables, padlocked.

`CERTUM_OTP_URI` is a full second factor, not a hint at one - anyone holding it can generate valid codes for the
account indefinitely. Treat it like the account password, and re-issue the token in the Certum panel if it is
ever exposed.

### What the user sees in the prompt

`signtool /d` sets the program name in the UAC elevation prompt and the SmartScreen dialog, and `/du` the
"more information" link behind it. Both are set - left off, Windows falls back to the bare file name, so a user
is asked to approve a bare `Something-x64.exe` out of the downloads folder.

`/d` prefers the binary's own `FileDescription`, so for a project with a version resource the string stays in the
`.rc` and nothing has to be repeated in the workflow. A project without one passes `description:` instead, and
adding a version resource later takes over silently. `/du` defaults to the repository the build is running out
of; a project with a site of its own passes `description-url:`.

## Where to get the values

### `CERTUM_OTP_URI`

The QR code shown during SimplySign enrolment *is* the URI - the phone app just scans it. Capture the text
instead of scanning:

- during enrolment, most QR readers will show the raw contents rather than acting on them
- already enrolled? Re-issue the token in the Certum panel and capture the new QR. The old one stops working, so
  re-enrol the phone from the same code if it is still wanted there.

It looks like this, and all of it goes in the secret:

```
otpauth://totp/SimplySign:you@example.com?secret=BASE32SECRET&issuer=Certum&algorithm=SHA256&digits=6&period=30
```

`algorithm`, `digits` and `period` are read from the URI rather than assumed - Certum enrols with SHA-256, where
most authenticators default to SHA-1, and a code generated with the wrong one is simply wrong.

### `CERTUM_CERTIFICATE_SHA1`

Install SimplySign Desktop locally, connect it, then ask the store what arrived:

```powershell
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Format-List Subject, Thumbprint, NotAfter
```

The `Thumbprint` is the value. It changes when the certificate is renewed or re-issued, so a release failing with
*"Certificate ... is not in CurrentUser\My"* after a renewal usually means this variable, not the login - and it
means it in every repository at once. Being a variable rather than a secret, the value is in the run log, so it
can be compared against the store without guessing.

## Where the status shows up

Signed or not, every release run says which it was:

- a **workflow annotation** at the top of the run page - green notice for signed, warning for unsigned - or, on
  AppVeyor, a message on the Messages tab, which survives the log scrolling past
- a **table in the job summary**, one row per binary, with signer and whether it was timestamped
- the **draft release notes**, above the generated changelog, so it reaches whoever downloads the binary
- `SIGNING_STATUS`, `SIGNING_SUMMARY` and `SIGNING_NOTES`, for whatever the workflow does next - the header line
  of a `SHA256SUMS.txt`, say, which is a `#` comment that `sha256sum -c` ignores

The state is read back off the finished files with `Get-AuthenticodeSignature`, not inferred from "the signing
step ran". When signing was configured but a binary came out unsigned, the run fails rather than publishing a
release that claims to be signed.

"Timestamped" is one-way: *yes* means yes, and anything else means nobody knows. `TimeStamperCertificate` is only
filled in for the legacy counter-signature format on older Windows, and the AppVeyor images report nothing for
the RFC 3161 token `/tr` produces even while `signtool verify` in that same build prints it happily.

## How the login works

Adapted from [blinkdisk](https://github.com/blinkdisk/blinkdisk/tree/main/.github), itself from
[this write-up](https://www.devas.life/how-to-automate-signing-your-windows-app-with-certum/). The TOTP generator
follows them; the login does not. Theirs drives the login dialog with `WScript.Shell` SendKeys, which needs a
window to reach the foreground and keystrokes to land in it. On GitHub's runners that produced a login that never
completed and a certificate that never appeared. SimplySign Desktop takes the credentials directly instead:

```
SimplySignDesktop.exe /autologin <account> <otp>
```

It is undocumented, and read positionally - `/autologin` has to be `argv[1]`, with the account in `argv[2]` and
the code in `argv[3]`. Because the account is one argument and the launcher does not quote it, whitespace in
`CERTUM_USERNAME` would push the code into `argv[4]`; the script rejects that up front rather than letting it
look like a refused login. Values are trimmed for the same reason - a secret pasted with a trailing newline is
otherwise indistinguishable from a wrong one.

Success is the certificate being in `CurrentUser\My`, not the process still being alive. With a thumbprint known
the script waits for exactly that certificate, so a failed login fails there rather than later inside signtool,
and the failure message lists what *did* arrive - which separates "the login was refused" from
"`CERTUM_CERTIFICATE_SHA1` names a different certificate".

## Testing it locally

Most of this needs a Certum account, but the part that fails *silently* does not. A wrong code is
indistinguishable from a refused login from the outside, so the generator is checked against the RFC 6238
vectors, all three algorithms:

```bash
pwsh -File scripts/connect-simplysign.ps1 -SelfTest
```

That runs without an account, without SimplySign installed, and without touching the certificate store. It is
also what `selftest.yml` runs on every push.

What it does **not** cover is the login itself. Testing that end to end means a real account and a real one-time
code, so it belongs on a machine that already has SimplySign connected - and be aware that
`connect-simplysign.ps1` stops any running SimplySign Desktop before logging in, ending whatever session was
open. Repeated failed attempts are also worth avoiding on a live account.

Whether a given SimplySign build has the flag at all can be checked without running it - the literal and the
field names are in the binary:

```powershell
$exe = Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop\SimplySignDesktop.exe'
$s = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($exe))
$s.Contains('/autologin')
```

Bumping the pinned SimplySign version means changing the version *and* the hash in `install-simplysign.ps1`
together - the hash is what says the bytes are the ones that were reviewed.

## Ordering

The simple case is: build everything, open the session, sign, report. That keeps the session as short as it can
be - one TOTP code has to cover the signing only, not the build in front of it - and a second login inside the
same 30-second step reuses the code, which Certum may refuse.

Anything embedded in another binary breaks that: it has to be signed *before* the build that embeds it, or the
copy inside the download stays unsigned while the download itself looks fine. Pass the extracted helpers as
`embedded-path` and the run fails if that ordering ever breaks. PDBs carry no signature and are never signed.
