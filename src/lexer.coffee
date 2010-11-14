# The Coco Lexer. Uses a series of token-matching regexes to attempt
# matches against the beginning of the source code. When a match is found,
# a token is produced, we consume the match, and start again. Tokens are in the
# form:
#
#     [tag, value, lineNumber]
#
# Which is a format that can be fed directly into [Jison](http://github.com/zaach/jison).

Rewriter = require './rewriter'

# The Lexer Class
# ---------------

# The Lexer class reads a stream of Coco and divvies it up into tagged
# tokens. Some potential ambiguity in the grammar has been avoided by
# pushing some extra smarts into the Lexer.
class exports.Lexer

  # **tokenize** is the Lexer's main method. Scan by attempting to match tokens
  # one at a time, using a regular expression anchored at the start of the
  # remaining code, or a custom recursive token-matching method
  # (for interpolations). When the next token has been recorded, we move forward
  # within the code past the token, and begin again.
  #
  # Each tokenizing method is responsible for returning the number of characters
  # it has consumed.
  #
  # Before returning the token stream, run it through the [Rewriter](rewriter.html)
  # unless explicitly asked not to.
  tokenize: (@code, o = {}) ->
    @line    = o.line or 0  # The current line.
    @indent  = 0            # The current indentation level.
    @indebt  = 0            # The over-indentation at the current level.
    @outdebt = 0            # The under-outdentation at the current level.
    @indents = []           # The stack of all current indentation levels.
    # Stream of parsed tokens in the form `['TYPE', value, line]`.
    @tokens  = [@last = ['DUMMY', '', 0]]
    # Flags for distinguishing FORIN/FOROF/FROM/TO.
    @seenFor = @seenFrom = false
    code = @code.replace(/\r/g, '').replace TRAILING_SPACES, ''
    i    = 0
    while @chunk = code.slice i
      if comments = COMMENTS.exec @chunk
        break unless @chunk = code.slice i += @countLines(comments[0]).length
      switch code.charAt i
      case '\n'      then step = do @lineToken
      case ' ', '\t' then step = do @whitespaceToken
      case "'", '"'  then step = do @heredocToken or do @stringToken
      case '/'       then step = do @heregexToken or do @regexToken
      case '<'       then step = do @wordsToken
      case '#'       then step = do @commentToken
      case '`'       then step = do @jsToken
      default step = @whitespaceToken() or @identifierToken() or @numberToken()
      i += step or @literalToken()
    # Close up all remaining open blocks at the end of the file.
    @outdentToken @indent
    @tokens.shift()  # Dispose dummy.
    Rewriter.rewrite @tokens unless o.rewrite is false
    @tokens

  # Tokenizers
  # ----------

  # Matches identifying literals: variables, keywords, method names, etc.
  # Check to ensure that JavaScript reserved words aren't being used as
  # identifiers. Because Coco reserves a handful of keywords that are
  # allowed in JavaScript, we're careful not to tag them as keywords when
  # referenced as property names here, so you can still do `jQuery.is()` even
  # though `is` means `===` otherwise.
  identifierToken: ->
    return 0 unless match = IDENTIFIER.exec @chunk
    [input, id, colon] = match
    if id is 'all'
      switch @last[0]
      case 'FOR'    then @token 'ALL', id; return id.length
      case 'IMPORT' then @last[1] = ''   ; return id.length
    if id is 'from' and @tokens[*-2]?[0] is 'FOR'
      @seenFor  = false
      @seenFrom = true
      @token 'FROM', id
      return id.length
    if @seenFrom and id of <[ to til ]>
      @seenFrom = false
      @token 'TO', id
      return id.length
    tag = if at = id.charAt(0) is '@'
      id .= slice 1
      'THISPROP'
    else
      'IDENTIFIER'
    forcedIdentifier = at or colon or
      if not (prev = @last).spaced and prev[1].colon2
      then @token<[ ACCESS . ]>
      else prev[0] is 'ACCESS'
    if id of JS_FORBIDDEN
      if forcedIdentifier
        id = new String id
        id.reserved = true
      else if id of RESERVED
        throw SyntaxError "reserved word \"#{id}\" on line #{ @line + 1 }"
    if not id.reserved      and id of     JS_KEYWORDS or
       not forcedIdentifier and id of COFFEE_KEYWORDS
      switch tag = id.toUpperCase()
      case 'FOR'                      then @seenFor = true
      case 'UNLESS'                   then tag = 'IF'
      case 'UNTIL'                    then tag = 'WHILE'
      case <[ NEW DO TYPEOF DELETE ]> then tag = 'UNARY'
      case <[ IN  OF  INSTANCEOF   ]>
        if tag isnt 'INSTANCEOF' and @seenFor
          tag = 'FOR' + tag
          @seenFor = false
        else
          tag = 'RELATION'
          if @last[1] is '!'
            @tokens.pop()
            id = '!' + id
    unless forcedIdentifier
      id  = COFFEE_ALIASES[id] if COFFEE_ALIASES.hasOwnProperty id
      switch id
      case <[ ! ]>                       then tag = 'UNARY'
      case <[ &&  ||  ]>                 then tag = 'LOGIC'
      case <[ === !== ]>                 then tag = 'COMPARE'
      case <[ true false null void    ]> then tag = 'LITERAL'
      case <[ break continue debugger ]> then tag = 'STATEMENT'
    @token tag, id
    @token<[ : : ]> if colon
    input.length

  # Matches numbers, including decimals, hex, and exponential notation.
  # Be careful not to interfere with ranges-in-progress.
  numberToken: ->
    return 0 unless number = NUMBER.exec @chunk
    @token 'STRNUM', number[=0]
    number.length

  # Matches strings, including multi-line strings. Ensures that quotation marks
  # are balanced within the string's contents, and within nested interpolations.
  stringToken: ->
    switch @chunk.charAt 0
    case "'"
      return 0 unless string = SIMPLESTR.exec @chunk
      @token 'STRNUM', (string[=0]).replace MULTILINER, '\\\n'
    case '"'
      return 0 unless string = @balancedString @chunk, [<[ " " ]>, <[ #{ } ]>]
      if 0 < string.indexOf '#{', 1
      then @interpolateString string.slice 1, -1
      else @token 'STRNUM', @escapeLines string
    default
      return 0
    @countLines(string).length

  # Matches heredocs, adjusting indentation to the correct level, as heredocs
  # preserve whitespace, but ignore indentation to the left.
  heredocToken: ->
    return 0 unless match = HEREDOC.exec @chunk
    [heredoc] = match
    quote = heredoc.charAt 0
    doc   = @sanitizeHeredoc match[2], {quote, indent: null}
    if quote is '"' and 0 <= doc.indexOf '#{'
    then @interpolateString doc, heredoc: true
    else @token 'STRNUM', @makeString doc, quote, true
    @countLines(heredoc).length

  # Matches block comments.
  commentToken: ->
    return 0 unless match = HERECOMMENT.exec @chunk
    @token 'HERECOMMENT', @sanitizeHeredoc match[1],
      comment: true, indent: Array(@indent + 1).join(' ')
    @token<[ TERMINATOR \n ]>
    @countLines(match[0]).length

  # Matches JavaScript interpolated directly into the source via backticks.
  jsToken: ->
    return 0 unless js = JSTOKEN.exec @chunk
    @token 'LITERAL', (js[=0]).slice 1, -1
    @countLines(js).length

  # Matches regular expression literals. Lexing regular expressions is difficult
  # to distinguish from division, so we borrow some basic heuristics from
  # JavaScript and Ruby.
  regexToken: ->
    # We distinguish it from the division operator using a list of tokens that
    # a regex never immediately follows.
    # Our list becomes shorter when spaced, due to sans-parentheses calls.
    return 0 if (prev = @last)[0] of <[ STRNUM LITERAL CREMENT ]> or
                not prev.spaced and prev[0] of CALLABLE or
                not regex = REGEX.exec @chunk
    @token 'LITERAL', if regex[=0] is '//' then '/(?:)/' else regex
    @countLines(regex).length

  # Matches multiline and extended regular expression literals.
  heregexToken: ->
    return 0 unless match = HEREGEX.exec @chunk
    [heregex, body, flags] = match
    if 0 > body.indexOf '#{'
      body .= replace(HEREGEX_OMIT, '').replace(/\//g, '\\/')
      @token 'LITERAL', "/#{ body or '(?:)' }/#{flags}"
      return @countLines(heregex).length
    @tokens.push ['IDENTIFIER', 'RegExp', @line], ['CALL_START', '(', @line]
    tokens = []
    for [tag, value] of @interpolateString(body, regex: true)
      if tag is 'TOKENS'
        tokens.push value...
      else
        continue unless value .= replace HEREGEX_OMIT, ''
        value .= replace /\\/g, '\\\\'
        tokens.push ['STRNUM', @makeString(value, '"', true)]
      tokens.push <[ PLUS_MINUS + ]>
    tokens.pop()
    unless tokens[0]?[0] is 'STRNUM'
      @tokens.push <[ STRNUM "" ]>, <[ PLUS_MINUS + ]>
    @tokens.push tokens...
    @tokens.push <[ , , ]>, ['STRNUM', '"' + flags + '"'] if flags
    @countLines heregex
    @token<[ ) ) ]>
    heregex.length

  # Matches words literal, a syntax sugar for an array of strings.
  wordsToken: ->
    return 0 unless words = WORDS.exec @chunk
    if call = not (prev = @last).spaced and prev[0] of CALLABLE
    then @token<[ CALL_START ( ]>
    else @token<[ [ [ ]>
    for word of (words[=0]).slice(2, -2).match(/\S+/g) or ['']
      @tokens.push ['STRNUM', @makeString word, '"'], <[ , , ]>
    @countLines words
    if call then @token<[ ) ) ]> else @token<[ ] ] ]>
    words.length

  # Matches newlines, indents, and outdents, and determines which is which.
  # If we can detect that the current line is continued onto the the next line,
  # then the newline is suppressed:
  #
  #     elements
  #       .each( ... )
  #       .map( ... )
  #
  # Keeps track of the level of indentation, because a single outdent token
  # can close multiple indents, so we need to know how far in we happen to be.
  lineToken: ->
    return 0 unless indent = MULTIDENT.exec @chunk
    @countLines indent[=0]
    @last.eol = true
    size = indent.length - 1 - indent.lastIndexOf '\n'
    noNewlines = @unfinished()
    if size - @indebt is @indent
      @newlineToken() unless noNewlines
      return indent.length
    if size > @indent
      if noNewlines
        @indebt = size - @indent
        return indent.length
      diff = size - @indent + @outdebt
      @token 'INDENT', diff
      @indents.push diff
      @outdebt = @indebt = 0
    else
      @indebt = 0
      @outdentToken @indent - size, noNewlines
    @indent = size
    indent.length

  # Record an outdent token or multiple tokens, if we happen to be moving back
  # inwards past several recorded indents.
  outdentToken: (moveOut, noNewlines) ->
    while moveOut > 0
      if (len = @indents.length - 1) < 0
        moveOut = 0
      else if (idt = @indents[len]) is @outdebt
        moveOut -= idt
        @outdebt = 0
      else if idt < @outdebt
        moveOut  -= idt
        @outdebt -= idt
      else
        moveOut -= dent = @indents.pop() - @outdebt
        @outdebt = 0
        @token 'OUTDENT', dent
    @outdebt -= moveOut if dent
    @newlineToken() unless noNewlines
    this

  # Matches and consumes non-meaningful whitespace. Tag the previous token
  # as being "spaced", because there are some cases where it makes a difference.
  whitespaceToken: ->
    return 0 unless match = WHITESPACE.exec @chunk
    @last.spaced = true
    match[0].length

  # Generate a newline token. Consecutive newlines get merged together.
  newlineToken: ->
    @token<[ TERMINATOR \n ]> unless @last[0] is 'TERMINATOR'
    this

  # We treat all other single characters as a token. e.g.: `( ) , . !`
  # Multi-character operators are also literal tokens, so that Jison can assign
  # the proper order of operations. There are some symbols that we tag specially
  # here. `;` and newlines are both treated as a `TERMINATOR`, we distinguish
  # parentheses that indicate a method call from regular parentheses, and so on.
  literalToken: ->
    [value] = SYMBOL.exec @chunk
    switch tag = value
    case <[ = := ]>
      prev = @last
      pval = prev[1]
      if not pval.reserved and pval of JS_FORBIDDEN
        throw SyntaxError \
          "reserved word \"#{pval}\" on line #{ @line + 1 } cannot be assigned"
      if value is '=' and pval of <[ || && ]>
        prev[0]  = 'COMPOUND_ASSIGN'
        prev[1] += '='
        return value.length
      tag = 'ASSIGN'
    case <[ -> => ]>
      @tagParameters()
      tag = 'FUNC_ARROW'
    case '*'
      tag = if @last[0] is 'INDEX_START' then 'LITERAL' else 'MATH'
    case <[ ! ~ ]>          then tag = 'UNARY'
    case <[ . ?. .= ]>      then tag = 'ACCESS'
    case <[ + - ]>          then tag = 'PLUS_MINUS'
    case <[ === !== <= < > >= == != ]> \
                            then tag = 'COMPARE'
    case <[ && || & | ^ ]>  then tag = 'LOGIC'
    case <[ / % ]>          then tag = 'MATH'
    case <[ ++ -- ]>        then tag = 'CREMENT'
    case <[ -= += ||= &&= ?= /= *= %= <<= >>= >>>= &= ^= |= ]> \
                            then tag = 'COMPOUND_ASSIGN'
    case <[ << >> >>> ]>    then tag = 'SHIFT'
    case <[ ?[ [= ]>        then tag = 'INDEX_START'
    case '@'                then tag = 'THIS'
    case ';'                then tag = 'TERMINATOR'
    case '?'                then tag = 'LOGIC' if @last.spaced
    case '\\\n'             then return value.length
    default
      if value.charAt(0) is '@'
        @tokens.push ['IDENTIFIER', 'arguments', @line],
          <[ INDEX_START [ ]>, ['STRNUM', value.slice 1], <[ INDEX_END  ] ]>
        return value.length
      if value is '::'
        id = new String 'prototype'
        id.colon2 = true
        @token<[ ACCESS . ]>
        @token 'IDENTIFIER', id
        return value.length
      unless (prev = @last).spaced
        if value is '(' and prev[0] of CALLABLE
          prev[0] = 'FUNC_EXIST' if prev[0] is '?'
          tag = 'CALL_START'
        else if value is '[' and prev[0] of INDEXABLE
          tag = 'INDEX_START'
    @token tag, value
    value.length

  # Token Manipulators
  # ------------------

  # Sanitize a heredoc or herecomment by
  # erasing all external indentation on the left-hand side.
  sanitizeHeredoc: (doc, options) ->
    {indent, comment} = options
    if comment
      return doc if 0 > doc.indexOf '\n'
    else
      while attempt = HEREDOC_INDENT.exec doc
        attempt[=1]
        indent = attempt if !indent? or 0 < attempt.length < indent.length
    doc .= replace /// \n #{indent} ///g, '\n' if indent
    doc .= replace /^\n/, '' unless comment
    doc

  # A source of ambiguity in our grammar used to be parameter lists in function
  # definitions versus argument lists in function calls. Walk backwards, tagging
  # parameters specially in order to make things easier for the parser.
  tagParameters: ->
    return this if @last[0] isnt ')'
    {tokens} = this
    level = 0
    i = tokens.length
    tokens[--i][0] = 'PARAM_END'
    while tok = tokens[--i]
      switch tok[0]
      case ')' then ++level
      case <[ ( CALL_START ]>
        break if level--
        tok[0] = 'PARAM_START'
        return this
    this

  # Matches a balanced group such as a single or double-quoted string. Pass in
  # a series of delimiters, all of which must be nested correctly within the
  # contents of the string. This method allows us to have strings within
  # interpolations within strings, ad infinitum.
  balancedString: (str, delimited, options = {}) ->
    levels = []
    i = 0
    slen = str.length
    while i < slen
      if levels.length and str.charAt(i) is '\\'
        i += 2
        continue
      for pair of delimited
        [open, close] = pair
        if levels.length and levels[*-1] is pair and
           close is str.substr i, close.length
          levels.pop()
          i += close.length - 1
          i += 1 unless levels.length
          break
        if open is str.substr i, open.length
          levels.push pair
          i += open.length - 1
          break
      break unless levels.length
      i += 1
    if levels.length then throw SyntaxError \
      "unterminated #{ levels.pop()[0] } starting on line #{ @line + 1 }"
    i and str.slice 0, i

  # Expand variables and expressions inside double-quoted strings using
  # Ruby-like notation for substitution of arbitrary expressions.
  #
  #     "Hello #{name.capitalize()}."
  #
  # If it encounters an interpolation, this method will recursively create a
  # new Lexer, tokenize the interpolated contents, and merge them into the
  # token stream.
  interpolateString: (str, {heredoc, regex} = {}) ->
    tokens = []
    pi = 0
    i  = -1
    while chr = str.charAt ++i
      if chr is '\\'
        ++i
        continue
      continue unless chr is '#' and str.charAt(i+1) is '{' and
                      (expr = @balancedString str.slice(i+1), [<[ { } ]>])
      tokens.push ['TO_BE_STRING', str.slice(pi, i)] if pi < i
      inner = expr.slice(1, -1)
              .replace( LEADING_SPACES, '')
              .replace(TRAILING_SPACES, '')
      if inner.length
        nested = new Lexer().tokenize inner, {@line, rewrite: false}
        nested.pop()
        if nested.length > 1
          nested.unshift <[ ( ( ]>
          nested.push    <[ ) ) ]>
        tokens.push ['TOKENS', nested]
      i += expr.length
      pi = i + 1
    tokens.push ['TO_BE_STRING', str.slice pi] if i > pi < str.length
    return tokens if regex
    return @token<[ STRNUM "" ]> unless tokens.length
    tokens.unshift ['', ''] unless tokens[0][0] is 'TO_BE_STRING'
    @token<[ ( ( ]> if interpolated = tokens.length > 1
    for [tag, value], i of tokens
      @token<[ PLUS_MINUS + ]> if i
      if tag is 'TOKENS'
      then @tokens.push value...
      else @token 'STRNUM', @makeString value, '"', heredoc
    @token<[ ) ) ]> if interpolated
    tokens

  # Helpers
  # -------

  # Add a token to the results, taking note of the line number.
  token: (tag, value) -> @tokens.push @last = [tag, value, @line]

  # Are we in the midst of an unfinished expression?
  unfinished: ->
    LINE_CONTINUER.test(@chunk) or @last[0] of <[
      ACCESS INDEX_START PLUS_MINUS MATH COMPARE LOGIC RELATION IMPORT SHIFT
    ]>

  # Converts newlines for string literals.
  escapeLines: (str, heredoc) ->
    str.replace MULTILINER, if heredoc then '\\n' else ''

  # Constructs a string token by escaping quotes and newlines.
  makeString: (body, quote, heredoc) ->
    return quote + quote unless body
    body .= replace /\\([\s\S])/g, (match, escaped) ->
      if escaped of ['\n', quote] then escaped else match
    body .= replace /// #{quote} ///g, '\\$&'
    quote + @escapeLines(body, heredoc) + quote

  # Count the number of lines in a string and add it to `@line`.
  countLines: (str) ->
    pos = 0
    ++@line while pos = 1 + str.indexOf '\n', pos
    str

# Constants
# ---------

# Keywords that Coco shares in common with JavaScript.
JS_KEYWORDS = <[
  true false null this void super
  if else for while switch case default try catch finally class extends
  return throw break continue debugger
  new do delete typeof in instanceof import function
]>

# Coco-only keywords.
COFFEE_KEYWORDS = <[ then unless until loop of by when ]>
COFFEE_KEYWORDS.push op for all op in COFFEE_ALIASES =
  and  : '&&'
  or   : '||'
  is   : '==='
  isnt : '!=='
  not  : '!'

# The list of keywords that are reserved by JavaScript, but not used, or are
# used by Coco internally. We throw an error when these are encountered,
# to avoid having a JavaScript error at runtime.
RESERVED = <[ var with const let enum export native ]>

# The superset of both JavaScript keywords and reserved words, none of which may
# be used as identifiers or properties.
JS_FORBIDDEN = JS_KEYWORDS.concat RESERVED

# Token matching regexes.
IDENTIFIER = /// ^
  ( @? [$A-Za-z_][$\w]* )
  ( [^\n\S]* : (?![:=]) )?  # Is this a property name?
///
NUMBER = ///
 ^ 0x[\da-f]+ |                              # hex
 ^ (?: \d+(\.\d+)? | \.\d+ ) (?:e[+-]?\d+)?  # decimal
///i
HEREDOC = /// ^ ("""|''') ([\s\S]*?) (?:\n[^\n\S]*)? \1 ///
SYMBOL  = /// ^ (
  ?: [-=]>                # function
   | [!=]==               # strict equality
   | [-+*/%&|^?:.[<>=!]=  # compound assign / comparison
   | >>>=?                # zero-fill right shift
   | ([-+:])\1            # {in,de}crement / prototype access
   | ([&|<>])\2=?         # logic / shift
   | \?[.[]               # soak access
   | \.{3}                # splat
   | @\d+                 # argument shorthand
   | \\\n                 # continued line
   | \S
) ///
WHITESPACE  = /^[^\n\S]+/
COMMENTS    = /^(?:\s*#(?!##[^#]).*)+/
HERECOMMENT = /^###([^#][\s\S]*?)(?:###|$)/
MULTIDENT   = /^(?:\n[^\n\S]*)+/
SIMPLESTR   = /^'[^\\']*(?:\\.[^\\']*)*'/
JSTOKEN     = /^`[^\\`]*(?:\\.[^\\`]*)*`/
WORDS       = /^<\[[\s\S]*?]>/

# Regex-matching-regexes.
REGEX = /// ^
  / (?! \s )       # disallow leading whitespace
  [^ [ / \n \\ ]*  # every other thing
  (?:
    (?: \\[\s\S]   # anything escaped
      | \[         # character class
           [^ \] \n \\ ]*
           (?: \\[\s\S] [^ \] \n \\ ]* )*
         ]
    ) [^ [ / \n \\ ]*
  )*
  / [imgy]{0,4} (?!\w)
///
HEREGEX      = /// ^ /{3} ([\s\S]+?) /{3} ([imgy]{0,4}) (?!\w) ///
HEREGEX_OMIT = /\s+(?:#.*)?/g

# Token cleaning regexes.
MULTILINER      = /\n/g
HEREDOC_INDENT  = /\n+([^\n\S]*)/g
LINE_CONTINUER  = /// ^ \s* (?: , | \??\.(?!\.) | :: ) ///
LEADING_SPACES  = /^\s+/
TRAILING_SPACES = /\s+$/

# Tokens which could legitimately be invoked or indexed. A opening
# parentheses or bracket following these tokens will be recorded as the start
# of a function invocation or indexing operation.
CALLABLE  = <[ IDENTIFIER THISPROP ) ] } ? SUPER THIS ]>
INDEXABLE = CALLABLE.concat<[ STRNUM LITERAL ]>
