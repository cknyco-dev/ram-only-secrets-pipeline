# Security Policy

## Reporting a vulnerability

**Do not open a public issue or pull request with exploit details.** A
public issue is exactly as visible as a public PR — neither one gives a
fix a chance to ship before the problem is disclosed.

Instead:

1. **Preferred**: use GitHub's private vulnerability reporting — go to
   this repository's **Security** tab → **Report a vulnerability**. This
   opens a private advisory visible only to the maintainer until a fix is
   ready.
2. **Fallback**: if private reporting isn't enabled yet, or you'd rather
   not use GitHub for it, email the maintainer directly instead of filing
   anything public.

Include enough to reproduce the problem: which component (installer,
generated systemd unit, one of the two helper scripts, or the documented
pattern itself), the exact steps, and the actual vs. expected outcome. You
do not need a working exploit — a credible description of the gap is
enough to start from.

There's no bug bounty here — this is a documented pattern maintained by
one person, not a funded project — but a genuine report will be taken
seriously, fixed, and credited (unless you'd rather stay anonymous).

## What's in scope

- The installer script (`ram-only-secrets-install.sh`).
- The systemd unit, helper scripts, and file permissions it generates.
- A flaw in the *documented pattern itself* — e.g. a step in
  [`documentation/`](documentation/) that, if followed exactly as
  written, leaves secrets exposed in a way the docs don't disclose.

## What's out of scope

- Vulnerabilities in `systemd`/`systemd-creds` itself — report those
  upstream, to the [systemd project](https://github.com/systemd/systemd).
- Your own application's handling of the resulting `.env` file once it's
  been read — that's outside this pattern's boundary.
- Issues that only occur when a documented step was skipped or changed —
  please still report those, but as a regular [bug report](.github/ISSUE_TEMPLATE/bug_report.yml)
  rather than a security advisory, unless skipping that step wasn't
  obviously dangerous from the docs alone.

## Supported versions

This repository has no version branches — `main` is the only supported
line, and a fix ships there directly once confirmed.
