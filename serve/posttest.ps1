# posttest.ps1 -- find out why POST requests from a child process vanish.
$H = 'http://192.168.103.1:8001'
function Try-It($label, $block) {
    try { & $block; "PASS $label" } catch { "FAIL $label :: $($_.Exception.Message)" }
}
"PSVersion: $($PSVersionTable.PSVersion)"
"OutputEncoding: $([Console]::OutputEncoding.WebName)  CodePage: $([Console]::OutputEncoding.CodePage)"

Try-It 'GET' { Invoke-WebRequest -UseBasicParsing -Uri "$H/agent.ps1" -TimeoutSec 10 | Out-Null }
Try-It 'POST ascii' { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=pt-ascii.txt" -Method Post -Body 'hello' -ContentType 'text/plain' -TimeoutSec 15 | Out-Null }
Try-It 'POST glyphs' { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=pt-glyph.txt" -Method Post -Body 'arrows << >> x +' -ContentType 'text/plain' -TimeoutSec 15 | Out-Null }
Try-It 'POST unicode' { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=pt-uni.txt" -Method Post -Body "arrows $([char]0x25C0)$([char]0x25B6)" -ContentType 'text/plain' -TimeoutSec 15 | Out-Null }
Try-It 'POST json' { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=pt-json.json" -Method Post -Body '{"a":1}' -ContentType 'application/json' -TimeoutSec 15 | Out-Null }
# file upload
$tmp = Join-Path $env:TEMP 'pt.bin'
[System.IO.File]::WriteAllBytes($tmp, [byte[]](1..64))
Try-It 'POST -InFile' { Invoke-WebRequest -UseBasicParsing -Uri "$H/upload?name=pt-file.bin" -Method Post -InFile $tmp -ContentType 'application/octet-stream' -TimeoutSec 15 | Out-Null }
# the .NET HttpWebRequest route, as a fallback candidate
Try-It 'WebClient UploadString' {
    $wc = New-Object Net.WebClient
    $wc.UploadString("$H/upload?name=pt-webclient.txt", 'POST', "wc $([char]0x25C0)")
}
"done"
