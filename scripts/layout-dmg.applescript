-- Configure only the run-owned mounted image passed by the release pipeline.
-- Never address a disk by its display name: another Install Jort may be mounted.
on run arguments
    set mountPath to item 1 of arguments
    set backgroundFile to POSIX file ((item 1 of arguments) & "/.background/background.png") as alias
    tell application "Finder"
        -- Coercing a root-folder alias can return disk "Install Jort", losing
        -- its identity when another installer with that name is mounted.
        -- Keep an ID-based reference and verify the actual filesystem path.
        set imageDiskID to missing value
        repeat with diskIndex from 1 to count of disks
            set candidateID to id of disk diskIndex
            set candidatePath to POSIX path of (disk id candidateID as alias)
            if candidatePath is (mountPath & "/") then
                set imageDiskID to candidateID
                exit repeat
            end if
        end repeat
        if imageDiskID is missing value then error "Finder cannot locate the run-owned installer volume"
        set imageFolder to a reference to disk id imageDiskID
        open imageFolder
        set imageWindow to container window of imageFolder
        if (count of arguments) > 1 then
            if item 2 of arguments is "verify" then
                set viewOptions to icon view options of imageWindow
                set geometry to bounds of imageWindow
                set appPosition to position of item "Jort.app" of imageFolder
                set applicationsPosition to position of item "Applications" of imageFolder
                set correct to (current view of imageWindow is icon view) and ¬
                    (item 3 of geometry - item 1 of geometry is 900) and ¬
                    (item 4 of geometry - item 2 of geometry is 520) and ¬
                    (icon size of viewOptions is 112) and ¬
                    (appPosition is {220, 225}) and (applicationsPosition is {700, 225})
                close imageWindow
                return correct
            end if
        end if
        set current view of imageWindow to icon view
        set toolbar visible of imageWindow to false
        set statusbar visible of imageWindow to false
        set bounds of imageWindow to {100, 100, 1000, 620}
        set viewOptions to icon view options of imageWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set background picture of viewOptions to backgroundFile
        set position of item "Jort.app" of imageFolder to {220, 225}
        set position of item "Applications" of imageFolder to {700, 225}
        close container window of imageFolder
        open imageFolder
        update imageFolder without registering applications
        delay 2
        close container window of imageFolder
    end tell
    -- Finder persists .DS_Store asynchronously. Wait for it rather than signing
    -- an installer that merely looked right in Finder's in-memory window.
    repeat 40 times
        try
            set layoutFile to POSIX file (mountPath & "/.DS_Store") as alias
            return true
        end try
        delay 0.25
    end repeat
    error "Finder did not save the installer layout"
end run
