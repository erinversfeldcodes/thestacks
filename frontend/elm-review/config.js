const { Elm } = require("elm-review-no-unused");
module.exports = { rules: [Elm.NoUnused.Variables.rule, Elm.NoUnused.Imports.rule] };
