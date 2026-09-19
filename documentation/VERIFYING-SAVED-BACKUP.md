## 6. Verifying a saved backup is actually correct

Whenever you save a base64 blob to your password manager — right after the
one-time setup (Section 5.2) or right after any `YOUR_APP-secrets-commit`
(Section 5.3) — verify it's a byte-for-byte match to what's actually live
on disk, not a copy-paste mistake:

```bash
sudo sha256sum /etc/credstore.encrypted/YOUR_APP-env
```

Then, separately, decode the copy you just saved and hash that. Same rule
as everywhere else in this document: never paste a real secret value
directly into a typed command — it lands in shell history verbatim. Paste
into `nano` instead, decode from the resulting file, then shred it:

```bash
: > /dev/shm/verify.b64
chmod 600 /dev/shm/verify.b64
nano /dev/shm/verify.b64
# paste the base64 you just saved, save, exit
base64 -d /dev/shm/verify.b64 | sha256sum
shred -u /dev/shm/verify.b64
```

**If the two `sha256sum` outputs match, the backup is correct.** Do this
once right after saving any new backup — it costs a few seconds and it's
the only way to know for certain the text that ended up in your password
manager is really what's on disk, not a truncated paste or a stray newline.

This is also the right check to run periodically as an audit, independent
of any change: confirm the backup you're relying on is still the one
actually protecting the currently-live blob, not an older one from before a
rotation you forgot to re-save.

Once you're done verifying, clear this session's shell history, same as
everywhere else a real secret has touched a terminal (Sections 5.2 step 10,
5.3, and 8.2):

```bash
# bash: history -c && history -w
# zsh:  history -c && fc -W
# best-effort terminal scrollback: printf '\033[3J'
```
