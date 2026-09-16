# Security policy

## Reporting a vulnerability

Do not disclose suspected vulnerabilities in a public issue.

After the public repository is available, use GitHub's private vulnerability
reporting or open a private draft security advisory for `ppanwin10/ReLand`.
Include:

- affected version/commit;
- reproducible steps;
- realistic impact;
- logs or screenshots with credentials, addresses, paths, and personal data
  removed;
- a suggested mitigation, if known.

## Supported versions

During pre-release development, only the latest `main` revision is supported.
Published beta support will be documented in release notes.

## Repository safeguards

- `main` is protected for administrators and contributors.
- Merges require the GitHub Actions `verify` check from the GitHub Actions app.
- Force pushes and branch deletion are disabled.
- Mainline commits must be signed; GitHub squash merges produce verified
  commits.
- External pull-request workflows require maintainer approval.
- Repository workflow defaults are read-only and cannot approve pull requests.
- The required `Repository Policy` check loads its scanners from the pull
  request base. It rejects write permissions, secrets, `pull_request_target`,
  unpinned/non-GitHub actions, persisted checkout credentials, and changes to
  policy or supply-chain files.
- Actions are limited to GitHub-owned actions pinned by commit SHA.
- A branch ruleset requires one code-owner approval, dismisses approvals after
  new pushes, requires approval of the latest push, and blocks CodeQL errors,
  warnings, and medium-or-higher security alerts.
- CodeQL scans Swift and Actions, and secret scanning with push protection is
  enabled.
- Dependabot security updates and private vulnerability reporting are enabled.
- All tags are owner-controlled, and published releases and release tags are
  immutable.
- `CODEOWNERS` requests the maintainer on application, package, build, workflow,
  privacy, and security changes.

No external contribution is merged automatically. A contributor cannot push to
`main` or publish a ReLand release without maintainer access.

ReLand currently has one maintainer account, so GitHub cannot enforce an
independent human approval without also blocking that maintainer's own pull
requests. External contributions require that maintainer's explicit approval;
owner-authored changes use an audited ruleset bypass. Before granting another
account write access, move the repository to an organization that enforces
two-factor authentication and add at least two trusted maintainers so the
bypass can be removed.

Maintainer accounts should use a passkey or hardware security key in addition
to two-factor authentication. Repository protections cannot compensate for a
compromised sole-owner account.

## Security boundaries

- Pairing is explicit, local, one-time, and QR-based.
- Transport uses Network.framework TLS-PSK.
- Client and host reject public network destinations.
- Screen capture and input require macOS TCC consent.
- Remote files are limited to ReLand storage and folders approved on the Mac.
- Hidden paths, traversal, and symlinks are rejected server-side.
- Terminal access is intentionally powerful and should be granted only to
  devices you control.

See [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) for limitations and
non-goals.
