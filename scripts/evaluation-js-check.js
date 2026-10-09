// Generated programs run without host objects, imports, dynamic code generation,
// filesystem APIs or network APIs. Each case has a VM timeout; the parent has a
// process timeout as well. This is a narrow algorithm checker, not a code runner.
const vm = require('node:vm');
let input = '';
process.stdin.on('data', data => input += data);
process.stdin.on('end', () => {
  try {
    const request = JSON.parse(input);
    if (request.code.length > 20000 || /\b(?:require|import|process|eval|Function|WebAssembly)\b|__proto__|constructor/.test(request.code)) {
      throw new Error('Program uses APIs outside the algorithm checker');
    }
    const outputs = request.tests.map(test => {
      const context = vm.createContext({}, {codeGeneration: {strings: false, wasm: false}});
      const source = request.code + '\nJSON.stringify(solve(JSON.parse(' + JSON.stringify(JSON.stringify(test.input)) + ')))';
      const result = vm.runInContext(source, context, {timeout: 100});
      if (typeof result !== 'string') throw new Error('solve did not return a JSON value');
      return JSON.parse(result);
    });
    process.stdout.write(JSON.stringify({outputs}));
  } catch (error) {
    process.stdout.write(JSON.stringify({error: error.message}));
    process.exitCode = 1;
  }
});
