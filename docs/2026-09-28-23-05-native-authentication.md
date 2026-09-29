# Native authentication

## Summary
Use OpenSSH's askpass interface to show native host-trust, password and key-passphrase prompts.

## Product behavior target
A first connection asks the user to verify the server fingerprint. Password/passphrase prompts use a secure field. Cancellation never trusts a host or supplies a credential. Changed host keys remain rejected by OpenSSH.

## Architecture changes
The app executable has an isolated askpass mode, selected only in the SSH subprocess environment. The mode displays a native alert and writes only the answer to SSH's private stdout pipe. No passwords in arguments, logs or files. The helper watches its parent and exits if SSH exits. Browser passes its executable URL to the core; headless callers retain strict batch behavior. Authentication has a five-minute response limit; connected requests retain the 30-second idle limit.

## UX acceptance criteria
Trust prompt shows the full SSH fingerprint message and defaults to Cancel. Secrets use NSSecureTextField. New trust decisions persist through OpenSSH known_hosts; credentials are not stored by Retriever. Existing key/agent authentication continues to work.

## Automated test plan
Build and full core suite; authenticated fixture validates askpass with an encrypted generated key and first-host confirmation. AppKit checks verify prompt types, secure field and safe default button without using real credentials.

## Manual verification plan
Inspect the native prompt through the AppKit harness. Real user-entered password against an external server is not required for core automated tests; do not claim it without evidence.

## Assumptions and non-goals
No password persistence or credential manager. OpenSSH config and agent remain available. Source documentation: https://man.openbsd.com/ssh.1 and https://github.com/openbsd/src/blob/master/usr.bin/ssh/readpass.c .

## Verification evidence
- All 18 core tests passed in `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_23-08-28--0400.xcresult`; final helper lifecycle adjustment compiled in a subsequent successful Debug build.
- Real SSH fixture passed encrypted-key askpass authentication, explicit first-host confirmation/persistence and cancelled trust with no persisted host key. It uses a scripted answer helper, not automated clicks in the native helper. Existing authentication/download and host-key rejection checks also pass.
- AppKit checks passed, including native secure field construction, fingerprint presence and Cancel as the first trust button, as well as existing window checks.
- Inspected `artifacts/verification/host-trust-preview.png` from the exact built helper: app icon, fingerprint message and Trust/Cancel controls render clearly. Preview was disconnected and labelled as such.
- Full authenticated GUI download and interactive helper response/lifetime automation remain to be verified. No claim of a real external password-server test.
