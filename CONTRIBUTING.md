# Contributing

Tribrach is public and pre-alpha: APIs, formats and file layouts may change
without notice, and there are no releases yet.

Outside contributions are welcome:

- **Issues** for bugs, questions and ideas, at any size.
- **Pull requests** for fixes, documentation and neutral examples. For a new
  feature, a format change or anything that touches the core model, open an
  issue first so the design can be agreed before code is written.
- Every pull request needs the `lean`, `formats` and `dco` checks to pass and
  a maintainer's review before it is merged.

## Sign your commits (DCO)

Tribrach uses the [Developer Certificate of Origin](https://developercertificate.org/)
instead of a contributor licence agreement. By adding a sign-off line you
certify that you wrote the change, or otherwise have the right to submit it
under the project's licence (Apache-2.0):

```
Signed-off-by: Your Name <you@example.com>
```

`git commit -s` adds it for you. CI checks every commit in a pull request.

## Ground rules

- `lake build` must pass. Proofs may not use `sorry` or new `axiom`s.
- Tribrach never depends on, names, or contains code from an application that
  uses it. Write code fresh; examples must be neutral.
- CI may only use GitHub-made actions or actions from verified creators.
- Instruments live in their own repositories (tribrach-go, tribrach-swift,
  tribrach-data).
