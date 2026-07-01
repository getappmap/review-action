const { add, greet } = require('../src/index');

describe('sample-project', () => {
  test('adds numbers', () => {
    expect(add(2, 3)).toBe(5);
  });

  test('greets by name', () => {
    expect(greet('world')).toBe('Hello, world!');
  });
});
