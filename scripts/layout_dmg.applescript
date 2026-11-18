on run argv
    set mountPath to item 1 of argv
    set appName to item 2 of argv
    set volumePath to POSIX file mountPath as text
    tell application "Finder"
        set volumeFolder to folder volumePath
        set targetWindow to make new Finder window to volumeFolder
        delay 1
        set current view of targetWindow to icon view
        set toolbar visible of targetWindow to false
        set statusbar visible of targetWindow to false
        set bounds of targetWindow to {100, 100, 760, 500}
        set viewOptions to icon view options of targetWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff" of volumeFolder
        set position of item appName of volumeFolder to {169, 198}
        set position of item "Applications" of volumeFolder to {491, 198}
        -- Keep hidden items below the artwork when Finder shows hidden files.
        set hiddenX to 169
        repeat with hiddenName in {".background", ".fseventsd", ".DS_Store"}
            if exists item (hiddenName as text) of volumeFolder then
                set position of item (hiddenName as text) of volumeFolder to {hiddenX, 500}
                set hiddenX to hiddenX + 161
            end if
        end repeat
        update volumeFolder without registering applications
        delay 2
        close targetWindow
    end tell
end run
