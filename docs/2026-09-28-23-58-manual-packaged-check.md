# Manual packaged-app check

The user disabled Computer Use and requested a temporary local SFTP server for manual acceptance. Provide a fixture that runs the exact built app with a separate SSH agent and disposable key, a loopback-only read-only sshd, an empty folder and a known text file. Quit ends the fixture; finally blocks stop processes and remove temporary keys. Normal native host acceptance writes the user's known_hosts entry; do not edit personal SSH configuration or bypass native trust.

Validation: Python syntax passed. Fixture started successfully and launched the packaged Debug app. User received the actual port and host fingerprint plus connect/navigate/save/quit instructions. Manual results are pending. This key-agent fixture covers native host trust but does not establish native password/passphrase prompt acceptance.
