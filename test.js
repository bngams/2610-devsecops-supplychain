// importer le fichier operations.js
const operations = require('./operations.js');
// importer la librairie assert
const assert = require('assert');

describe('testing', () => {
	// tester chaque fonction de operation.js
	it('should be 40 when you add 20 and 20', () => {
	    // test ...
          const wantedResult = 40; 
          const result = operations.add(20,20);
          // order matters given result, wanted result
          assert.equal(result, wantedResult);
      })
})