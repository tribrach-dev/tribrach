# [code-bug] the app's state breaks the unique-id rule

Would create: github-issue
Labels: bug, has-replay
From: github-issue-form 12 https://github.com/example-org/todo-app/issues/12
Model: todo.v1  App: 2.3.0
Group: code-bug-afe0a465eb1e262e

## Evidence

- the app's state breaks the unique-id rule

## Replay

```json
{
  "start": [],
  "ops": [
    {
      "op": "add",
      "id": 1
    },
    {
      "op": "add",
      "id": 1
    }
  ],
  "observed": [
    {
      "id": 1,
      "done": false
    },
    {
      "id": 1,
      "done": false
    }
  ]
}
```

## What the user said

I added the same item twice and now I see two of them.

Also reported as github-issue-form-16.
