# Download publication

## Summary
Remove the hard-link requirement from completed downloads while preserving existing destination files.

## Product behavior target
Publish a complete download using a non-replacing same-directory rename. A competing file or symlink created during transfer must survive unchanged. No incomplete destination or abandoned partial file on failure.

## Architecture changes
Create the temporary file atomically with O_EXCL and mode 0600. Publish using Darwin renamex_np with RENAME_EXCL. Report EEXIST as the existing-destination error; other filesystem errors remain errors without an unsafe replacing fallback. Reference: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2 .

## UX acceptance criteria
Never overwrite a destination, including a dangling symbolic link or a file created while bytes arrive. Successful downloads retain exact contents. Unsupported destination filesystems fail explicitly.

## Automated test plan
Existing real SFTP downloads/cancellation plus competing-file and dangling-symlink publication failures. Verify existing bytes/link, absent partial files and useful error type.

## Manual verification plan
No UI change. External filesystem compatibility is not claimed without a mounted filesystem test.

## Assumptions and non-goals
No overwrite workflow. Exclusive rename support varies by filesystem; this change removes a hard-link dependency but does not claim universal volume compatibility.

## Evidence
Unsigned Debug build and all 21 XCTest cases passed. New real SFTP tests preserve a competing file created during transfer and a dangling destination symlink, report destinationExists, and leave no partial files. Existing exact downloads and mid-transfer cancellation remain green. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_23-29-43--0400.xcresult`. No external volume was mounted or tested.
