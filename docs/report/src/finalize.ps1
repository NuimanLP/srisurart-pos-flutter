param([string]$In,[string]$Out,[string]$Pdf)
$w = New-Object -ComObject Word.Application
$w.Visible = $false; $w.DisplayAlerts = 0
try {
  $d = $w.Documents.Open($In, $false, $false, $false)
  foreach ($t in $d.TablesOfContents) { $t.Update() }
  foreach ($t in $d.TablesOfFigures) { $t.Update() }
  $d.Fields.Update() | Out-Null
  foreach ($t in $d.TablesOfContents) { $t.Update() }
  foreach ($t in $d.TablesOfFigures) { $t.Update() }
  $d.SaveAs2($Out, 16)
  if ($Pdf) { $d.ExportAsFixedFormat($Pdf, 17) }
  "pages: " + $d.ComputeStatistics(2)
  $d.Close($false)
} finally { $w.Quit() }
