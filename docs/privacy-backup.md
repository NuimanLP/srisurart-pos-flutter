# Privacy policy — "Srisurart POS backup" (Google Drive)

*Last updated: 2026-10-26*

"Srisurart POS backup" is a private tool used only by the owner of Srisurart Autopart (ร้านศรีสุราษฎร์ อะไหล่ยนต์).
It is not offered to the public.

## What it does

The shop's own point-of-sale server copies its backup files (database dumps and image archives, with their
checksums) into a folder in the **shop owner's own Google Drive**, and deletes that tool's own backup files there
once they are older than the retention period (30 days by default).

## What it accesses

- Google Drive with the `drive.file` scope only: it can see and change **only the files and folders it created
  itself**. It cannot read, list or change any other file in the Drive.
- No other Google data (no Gmail, contacts, calendar or profile data beyond what Google shows on the sign-in screen).

## Where data goes

- The backup files go from the shop's server to the owner's Google Drive and nowhere else.
- No data is sold, shared with third parties, or used for advertising or analytics.
- The sign-in credential is stored only on the shop's server and the owner's PC.

## Removing access

The owner can revoke access at any time at <https://myaccount.google.com/permissions> and delete the backup folder
in Google Drive.

## Contact

Open an issue at <https://github.com/NuimanLP/srisurart-pos-flutter/issues>.
