# Express API Conventions — Task Tracker Project

## Route Pattern
```js
const express = require('express');
const router = express.Router();

router.get('/', (_req, res) => {
  res.json({ data: [] });
});

module.exports = router;
```

Mount in server.js: `app.use('/api/tasks', require('./routes/tasks'));`

## Middleware Ordering (in server.js)
1. `express.json()` — Parse JSON bodies
2. `express.static()` — Serve public/ directory
3. Route mounts — `/api/tasks`, etc.
4. 404 handler — Catch unmatched routes
5. Error handler — 4-arg `(err, req, res, next)` function (must be LAST)

## Testing with Supertest
```js
const request = require('supertest');
const { app } = require('../src/server');

describe('GET /api/tasks', () => {
  test('returns empty list', async () => {
    const res = await request(app).get('/api/tasks');
    expect(res.status).toBe(200);
    expect(res.body.tasks).toEqual([]);
  });
});
```

**Important**: Import `app` directly — do NOT call `app.listen()` in tests.

## Store Reset Between Tests
The in-memory store persists across requests in the same process. Reset it in `beforeEach`:
```js
const taskModel = require('../src/models/task');

beforeEach(() => {
  // If a reset/clear function exists, call it
  if (taskModel.clearAll) taskModel.clearAll();
});
```

## Error Response Format
```js
res.status(400).json({
  error: 'Validation failed',
  code: 'VALIDATION_ERROR',
  details: ['Title is required', 'Status must be pending, in_progress, or done']
});
```

## ESLint Compliance
- Use `'single quotes'` everywhere
- End all statements with `;`
- Prefix unused params with `_`: `(_req, res)`, `(err, _req, res, _next)`
- No `var` — use `const` and `let`
- No unused variables — remove or prefix with `_`
