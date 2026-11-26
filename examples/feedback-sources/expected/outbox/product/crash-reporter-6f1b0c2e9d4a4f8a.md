# [expectation-mismatch] the app followed the rules; the user expected something else

Would create: tracker-card
Labels: spec-question
From: crash-reporter 6f1b0c2e9d4a4f8a
Model: todo.v1  App: 2.2.9
Group: expectation-mismatch-51bfb518b0208cb5

## Evidence

- the app followed the rules; the user expected something else

## Replay

```json
{
  "start": [
    {
      "id": 1,
      "done": true
    }
  ],
  "ops": [
    {
      "op": "add",
      "id": 1
    }
  ],
  "observed": [
    {
      "id": 1,
      "done": true
    }
  ],
  "expected": [
    {
      "id": 1,
      "done": false
    }
  ]
}
```

## What the user said

I re-added a finished item and expected it to come back unticked.
