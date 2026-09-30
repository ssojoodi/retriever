# File context menu and preview

Right-click selects the pointed row and offers Download and Preview. Reuse native save/download behavior. Preview downloads a regular file into a private temporary folder and displays it in a native Quick Look view. Disable both actions for folders/symlinks and during operations. Empty space has no item menu. Support cancellation, errors, nested paths, and remove temporary preview files on close/replacement/quit.

Validate right-click targeting, menu enablement, download save sheet, nested-file preview bytes and cleanup, native rendering, and existing window behavior. Request actual-app verification from the user without Computer Use.

Results: Debug build and authenticated browser checks passed, including clicked-row targeting, no menu in empty space, disabled folder actions, context Download save cancellation, exact nested preview bytes, temporary-file cleanup on close/replacement/cancellation, and preserving the connection after closing Preview. Native window checks passed. Inspected `artifacts/verification/file-preview.png`; Quick Look displays the downloaded text in its own titled, resizable window. Actual-app right-click check pending.
