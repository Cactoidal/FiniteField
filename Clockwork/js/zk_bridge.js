window.zkBridge = {
    // SNARKJS


// Every time a new circuit is made, the witnessCalculatorBuilder file (witness_calculator.js) needs
// to be rewritten as a library.  This means changing its declaration from export.module to 
// window.witnessCalculatorBuilder, reformatting all the function declarations for a library,
// and adding the witnessCalculatorBuilder. prefix to any internal function calls
calculateProof: async function(_inputs, _zk_circuit, _zk_proving_key, success, failure, callback) {
    console.log(_inputs)
    try {
        // The key and circuit are read from the .PCK file as bytes and hex encoded
        // Here the hex strings are turned into Array Buffers
        var zk_proving_key = zkBridge.hexConvert(_zk_proving_key)
        var zk_circuit = zkBridge.hexConvert(_zk_circuit)
  
        var inputs = JSON.parse(_inputs);
        console.log(inputs)
  
        // Originally, I modified witness_calculator.js to turn it into a library.  But it's
        // in fact possible to just load it into the window by modifying the generated
        // script slightly (see the wrapper in gdscript)
        var witnessCalculator = await window.witnessCalculatorBuilder(zk_circuit);
        //var witnessCalculator = await window.witnessCalculatorBuilder.builder(zk_circuit);
    
        var witness = await witnessCalculator.calculateWTNSBin(inputs, 0);
      
        const { proof, publicSignals } = await window.snarkjs.groth16.prove(zk_proving_key, witness);
        
        console.log(publicSignals)

        const calldata = await window.snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
        
        success(callback, calldata)
        }
  
    catch (_error ){
        console.error(_error); 
        failure(callback, _error.code, _error.message)
      }
  
    },
  
  //credit : https://stackoverflow.com/questions/43131242/how-to-convert-a-hexadecimal-string-of-data-to-an-arraybuffer-in-javascript
  hexConvert: function(hex) {
    var typedArray = new Uint8Array(hex.match(/[\da-f]{2}/gi).map(function (h) {
      return parseInt(h, 16)
    }))
  
    return typedArray
  
  },

  poseidonHash: function (inputs){
  
    const poseidon = window.IdenJsCrypto.Poseidon;
  
    const hash = poseidon.hash(inputs);
  
    return hash.toString();
  
  },

  bigNumberModulus: function (number, modulus) {
    var big = BigInt(number)

    var result = big % BigInt(modulus)

    return result.toString()

  },



}

function toHexString(uint8Array) {
  return Array.from(uint8Array)
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
}