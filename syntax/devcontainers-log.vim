syn match logDelimiter '[:<>=@{},\[\].]'

syn match logNumber '\<-\?\d\+\>'
syn match logHexNumber '\<0[xX]\x\+\>'
syn match logHexNumber '\<\x\{4,}\>'
syn match logHexNumber '\<\x\{2}\>'
syn match logBinNumber '\<0[bB][01]\+\>'
syn match logFloatNumber '\<\d.\d\+[eE]\?\>'

syn match logPercent '\<\d\{,2}\(\.\d\+\)\?%'

syn keyword logBool TRUE FALSE True False true false
syn keyword logNull NULL Null null nil

syn match logHeader '^\[[^]]\+]' nextgroup=logModule

syn match logTimestamp '\d+-\d+-\d+ \d+:\d+:\d+' containedin=logHeader

syn match logTrace 'TRACE' containedin=logHeader
syn match logDebug 'DEBUG' containedin=logHeader
syn match logInfo 'INFO' containedin=logHeader
syn match logWarn 'WARN' containedin=logHeader
syn match logError 'ERROR' containedin=logHeader

syn region logString start=/"/ end=/"/ end=/$/ skip=/\\./
" Quoted strings, but no match on quotes like "don't", "plurals' elements"
syn region logString start=/'\(s \|t \| \w\)\@!/ end=/'/ end=/$/ end=/s / skip=/\\./

syn match logModule / [^:]\+:/ contained

hi def link logNumber Number
hi def link logHexNumber Number
hi def link logBinNumber Number
hi def link logFloatNumber Number
hi def link logFloatNumber Number
hi def link logBool Boolean
hi def link logNull Constant
hi def link logString String
hi def link logPath String

hi def link logPercent Number

hi def link logTrace CommentNoItalic
hi def link logDebug DiagnosticHint
hi def link logInfo DiagnosticInfo
hi def link logWarn DiagnosticWarn
hi def link logError DiagnosticError

hi def link logModule Special
hi def link logVariableName Identifier

hi def link logDelimiter Delimiter
