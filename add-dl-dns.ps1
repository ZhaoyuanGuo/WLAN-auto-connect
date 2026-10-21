$Csv = "c:\Users\Administrator\Desktop\SecretKey.csv"
$tools = "c:\Flutter\Projects\Uni_novel\server\uninovel-sync\tools"

$body = "{""Domain"":""suspect.top"",""SubDomain"":""dl"",""RecordType"":""CNAME"",""RecordLine"":""\u9ed8\u8ba4"",""Value"":""app-downloads-2026-1494458480.cos.ap-shanghai.myqcloud.com"",""TTL"":600}"

& (Join-Path $tools 'tc_dnspod.ps1') -Csv $Csv -Action 'CreateRecord' -Payload $body
