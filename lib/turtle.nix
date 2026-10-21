{ ... }:
let
  hexDigits = [
    "0"
    "1"
    "2"
    "3"
    "4"
    "5"
    "6"
    "7"
    "8"
    "9"
    "a"
    "b"
    "c"
    "d"
    "e"
    "f"
  ];
  hexPair =
    code:
    builtins.elemAt hexDigits (code / 16) + builtins.elemAt hexDigits (code - 16 * (code / 16));
  unicodeChar = code: builtins.fromJSON ("\"\\u00" + hexPair code + "\"");
  unicodeEscape = code: builtins.fromJSON ("\"\\\\u00" + hexPair code + "\"");
  controlCodes = builtins.filter (code: code != 0) (builtins.genList (code: code) 32) ++ [ 127 ];
  escapeTable = [
    {
      from = "\\";
      to = "\\\\";
    }
    {
      from = "\"";
      to = "\\\"";
    }
  ] ++ builtins.map (code: {
    from = unicodeChar code;
    to =
      if code == 9 then
        "\\t"
      else if code == 10 then
        "\\n"
      else if code == 13 then
        "\\r"
      else
        unicodeEscape code;
  }) controlCodes;
  escapeLiteral =
    value:
    builtins.replaceStrings (builtins.map (entry: entry.from) escapeTable) (
      builtins.map (entry: entry.to) escapeTable
    ) value;
  controlCharacters = builtins.concatStringsSep "" (builtins.map unicodeChar controlCodes);
  iri = value: "<" + builtins.toString value + ">";

  renderClauses =
    clauses:
    let count = builtins.length clauses; in
    builtins.genList (
      index:
      let clause = builtins.elemAt clauses index; in
      "    "
      + clause.predicate
      + " "
      + builtins.concatStringsSep ", " clause.objects
      + (if index == count - 1 then " ." else " ;")
    ) count;

  renderSubject =
    subject: [ "" (iri subject.iri) ] ++ renderClauses subject.clauses;
in
{
  turtle = {
    literal = value: "\"" + escapeLiteral (builtins.toString value) + "\"";
    inherit iri controlCharacters;
    prefix = prefix: namespace: "@prefix ${prefix}: <${namespace}> .";
    document =
      { prefixes, subjects }:
      builtins.concatStringsSep "\n" (prefixes ++ builtins.concatMap renderSubject subjects) + "\n";
  };
}
