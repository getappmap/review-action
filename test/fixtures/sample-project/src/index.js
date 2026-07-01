// Minimal application code for the sample project. A couple of small,
// deterministic functions that a gold trace could exercise.

function add(a, b) {
  return a + b;
}

function greet(name) {
  if (!name) throw new Error('name is required');
  return `Hello, ${name}!`;
}

module.exports = { add, greet };
