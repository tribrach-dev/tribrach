# [model-gap] start[0].pinned isn't in the model; observed[0].pinned isn't in the model

Would create: github-issue
Labels: model-gap
From: helpdesk 4471 https://help.example.com/tickets/4471
Model: todo.v1  App: 2.3.0
Group: model-gap-0

## Evidence

- start[0].pinned isn't in the model
- observed[0].pinned isn't in the model

## Replay

```json
{
  "start": [
    {
      "id": 1,
      "done": false,
      "pinned": true
    }
  ],
  "ops": [
    {
      "op": "complete",
      "id": 1
    }
  ],
  "observed": [
    {
      "id": 1,
      "done": true,
      "pinned": false
    }
  ]
}
```

## What the user said

My pinned item lost its pin
