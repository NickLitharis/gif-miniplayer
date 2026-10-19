$H = 'http://192.168.103.1:8001'
function T($label, $url) {
    "URL[$label] = '$url'"
    try { $r = (New-Object Net.WebClient).UploadString($url, 'POST', 'x'); "PASS $label -> $r" }
    catch { "FAIL $label :: $($_.Exception.InnerException.GetType().Name): $($_.Exception.Message)" }
}
T 'letter-prefix' "$H/upload?name=zz-probe.txt"
T 'digit-prefix'  "$H/upload?name=1017-000000-zz-probe.txt"
T 'digit-simple'  "$H/upload?name=123.txt"
T 'underscore'    "$H/upload?name=_zz.txt"
"--- and the exact expression build.ps1 uses ---"
$Build = '1017-000000'; $n = 'ui.txt'
$u = "$H/upload?name=$Build-$n"
"computed: '$u'  length=$($u.Length)"
try { (New-Object Net.WebClient).UploadString($u, 'POST', 'x') | Out-Null; "PASS computed" } catch { "FAIL computed :: $($_.Exception.Message)" }
"done"
