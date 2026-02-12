describe('Project setup', () => {
  test('package.json is valid', () => {
    const pkg = require('../package.json');
    expect(pkg.name).toBe('ralph-test-tasktracker');
    expect(pkg.dependencies.express).toBeDefined();
  });

  test('server module exports app', () => {
    const { app } = require('../src/server');
    expect(app).toBeDefined();
    expect(typeof app.listen).toBe('function');
  });
});
