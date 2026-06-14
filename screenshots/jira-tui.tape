# render jira-tui views to screenshots/*.png
# run from repo root: `make screenshots`  (needs vhs + JIRA_* env)
Set FontSize 13
Set Width 1900
Set Height 1080
Set Padding 8

Hide
Type "./bin/jira-tui"
Enter
Show
Sleep 4s
Screenshot screenshots/my-issues.png

Type "t"
Sleep 1s
Screenshot screenshots/collapsed.png
Type "t"
Sleep 1s

Type "B"
Sleep 3s
Screenshot screenshots/backlog.png

Type "H"
Sleep 1s
Screenshot screenshots/help.png

Type "M"
Sleep 2s
Type "J"
Sleep 1s
Screenshot screenshots/jql-picker.png
Escape
Sleep 500ms

Type "q"
Sleep 500ms
