## 8. Disaster recovery — rebuilding on a different server

Two paths, depending on whether Section 7.5's optional key backup was ever
done. Don't mix them.

### 8.1 Default path — no key backup was made (the safer, slower default)

1. Provision the new host, create `YOUR_APP_USER` as before.
2. Clone the public config repo containing the unit file, both helper
   scripts, and this document (Section 7).
3. Retrieve real secret values from the password manager (Section 7.1) —
   not from any copy of the old host's encrypted blob, which is permanently
   unusable on new hardware; a fresh host always needs a fresh
   `systemd-creds encrypt`.
4. Run Section 5.1 to confirm the new host actually has what's needed, then
   Section 5.2 fresh, using the retrieved real values in step 4 of that
   section.
5. Point the application at the new host as normal for its own deployment
   process — outside the scope of this document.

### 8.2 Fast path — a key backup was made per Section 7.5

Same rule as everywhere else in this document: never paste a real secret
value directly into a typed command — it lands in shell history verbatim.
Paste into `nano` instead, decode from the resulting file, then shred that
file.

1. Provision the new host, create `YOUR_APP_USER` as before. Do **not** run
   `systemd-creds` for anything yet.
2. Restore the backed-up key onto the new host at the exact same path,
   before it ever auto-generates its own:
   ```bash
   : > /dev/shm/credential.secret.b64
   chmod 600 /dev/shm/credential.secret.b64
   nano /dev/shm/credential.secret.b64
   # paste the base64 you saved in Section 5.2 step 7b, save, exit
   base64 -d /dev/shm/credential.secret.b64 | sudo tee /var/lib/systemd/credential.secret > /dev/null
   shred -u /dev/shm/credential.secret.b64
   sudo chmod 600 /var/lib/systemd/credential.secret
   sudo sha256sum /var/lib/systemd/credential.secret
   # compare against the hash you saved alongside it in Section 5.2 step 7b
   ```
3. Restore the blob backup directly, the same way:
   ```bash
   sudo install -d -m 0755 /etc/credstore.encrypted
   : > /dev/shm/blob.b64
   chmod 600 /dev/shm/blob.b64
   nano /dev/shm/blob.b64
   # paste the blob's base64 backup, save, exit
   base64 -d /dev/shm/blob.b64 | sudo tee /etc/credstore.encrypted/YOUR_APP-env > /dev/null
   shred -u /dev/shm/blob.b64
   sudo sha256sum /etc/credstore.encrypted/YOUR_APP-env
   # compare against the hash you saved alongside that blob backup
   ```
4. Install the unit and both helper scripts (Section 4.2, Section 4.4),
   `systemctl daemon-reload`, `systemctl enable --now YOUR_APP-secrets.service`
   — no re-encryption needed, the restored blob decrypts with the restored
   key immediately.
5. Verify per Section 5.2's checklist, then continue from step 8 of Section
   5.2 (the app symlink) onward — no secret values need to be retyped.
6. Point the application at the new host as normal for its own deployment
   process — outside the scope of this document.
7. Clear this session's shell history, same as Section 5.2 step 10:
   ```bash
   # bash: history -c && history -w
   # zsh:  history -c && fc -W
   # best-effort terminal scrollback: printf '\033[3J'
   ```
