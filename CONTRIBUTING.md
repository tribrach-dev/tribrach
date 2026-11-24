# Contributing

Tribrach is private and pre-alpha. Outside contributions open when the
repository goes public; until then this describes how maintainers work.

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
