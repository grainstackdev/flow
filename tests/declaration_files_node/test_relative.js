/* @flow */

// This will require ./A.js.flow
var A1 = require('./A');
(A1.fun(): string); // Error number ~> string

// This will require ./A.js.flow
var A2 = require('./A.js');
(A2.fun(): string); // Error number ~> string

var CJS = require('./CJS.js');
(CJS: string);
(CJS: number); // Error: string ~> number

// flowlint-next-line untyped-import:error
require('./not_flow');

// should not resolve because we don't strip extensions from dirs
require('./confusing_dir'); // error: cannot-resolve-module

// should not resolve because we don't strip extensions from dirs
require('./confusing_dir_dot_flow'); // error: cannot-resolve-module
