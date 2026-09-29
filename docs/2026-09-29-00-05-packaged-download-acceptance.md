# Packaged download acceptance

The user manually tested the exact built Debug Retriever.app using the disposable loopback SFTP fixture. They first reached the native host-trust modal; an initial publickey rejection was traced to fixture authorized-key placement and corrected without changing Retriever transport code. After retrying, the user reported: “yes the test worked i was able to download the text file”.

This establishes packaged-app authentication, remote selection and native-save download for the sample file. It does not independently establish folder/Up interaction, saved-byte comparison, native password/passphrase handling, or release distribution. Automated core/controller tests provide separate byte-integrity coverage.

The tracked fixture process returned status 0 with cleanup confirmation. Server logs show authenticated connection and orderly disconnect, then server termination. The separate public authorization file used during live repair was removed. Temporary agent and private keys were cleaned up by the fixture. Accepted host trust remains in normal known_hosts as disclosed before the test.

Update README and the acceptance audit to distinguish these verified results from remaining checks. No app code changes in this iteration.
