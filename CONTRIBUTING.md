# Contributing

Thanks for helping with Dynexus. Please read this before opening a pull request.

## Ground rules

- Open an issue first for anything larger than a small fix, so we can agree on the approach.
- One logical change per pull request; keep it small and focused.
- Security problems go through the private process in [SECURITY.md](SECURITY.md), never a public issue.
- By contributing you agree your work is released under this repository's [MIT license](LICENSE).

## Workflow

1. Fork the repository (or create a branch if you have access) from `main`.
2. Make the change and add or update tests.
3. Run the checks below and make sure they pass.
4. Open a pull request against `main` and fill in the template.

`main` is protected: changes land through pull requests with passing CI.

## Checks

```bash
aptos move fmt
aptos move test
```

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/), enforced by commitlint,
for example `fix(scope): short imperative summary`. Explain _why_ in the body.

## Never commit secrets

No `.env*` files (only `*.example` placeholders), keys, tokens or private URLs. Git hooks
run secretlint, but you are responsible for what you push.
