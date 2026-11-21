# Security policy

## Supported versions

Only the latest commit on `main` is supported. Dynexus is deployed on Aptos **testnet**;
nothing here has been audited and it must not be used with real funds.

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report privately through GitHub: open the **Security** tab of this repository and choose
**Report a vulnerability** (https://github.com/DynexusLabs/dynexus-swap/security/advisories/new).

Include what is affected, how to reproduce it, and the impact you expect. You can expect
an acknowledgement within 7 days and a status update at least every 14 days until it is
resolved. Please give us a reasonable time to fix the issue before disclosing it.

## In scope

the Move smart contracts in `sources/` (loss of funds, broken access control, accounting errors, denial of service on-chain).

## Out of scope

Findings that need a compromised wallet or machine, social engineering, volumetric
denial of service against third-party infrastructure, and issues in dependencies that
have no demonstrated impact here (report those upstream).
