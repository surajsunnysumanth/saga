Saga __VERSION__ — read this first

1. Drag Saga into Applications, then open it.

macOS will say it cannot verify Saga. That is expected: the app is not
notarised by Apple yet.
  macOS 15 or later: System Settings > Privacy & Security > scroll to the
  bottom > Open Anyway > confirm with your password.
  macOS 14: right-click Saga in Applications, choose Open, then Open again.

Optional, if that button does not appear or you would rather not go through
Settings — run this in Terminal once Saga is in Applications:

  xattr -dr com.apple.quarantine /Applications/Saga.app

That removes the quarantine flag from that one app and nothing else. If you
keep Saga somewhere other than Applications, use that path instead.

Neither way gives Saga any extra access or changes a permission or a system
setting anywhere else.

Your archive stays on this Mac and nothing is uploaded. Saga asks GitHub once
a day whether a newer version exists; turn that off in Settings > Archive >
Updates.

Check the download arrived intact:  shasum -a 256 Saga.dmg
It must print the SHA-256 on the download page, also shipped as Saga.sha256
beside the download. If it differs, delete the file and download again.
