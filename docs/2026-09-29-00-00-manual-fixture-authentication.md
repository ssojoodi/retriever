# Manual fixture authentication correction

User reached the native trust prompt but reported publickey rejection. Server diagnostics identified OpenSSH StrictModes rejecting authorized_keys beneath shared /private/tmp. Keep fixture keys and authorization files under the private project checks directory; use a short /tmp directory only for the SSH-agent socket and sample files.

A second direct SFTP check found quoted internal-sftp -d arguments left the session in the home directory. Use the whitespace-free temporary sample directory without literal quotes in ForceCommand. Add an authenticated, pinned-host listing preflight before opening the packaged app so fixture failures are reported before asking the user to test.

Live fixture reloaded without changing its port or host key. System sftp authenticated with the isolated agent and listed exactly Empty folder and retriever-test.txt in the sample directory. User asked to retry the existing app connection. Native save/download/quit results remain pending. No Retriever transport change was needed.
