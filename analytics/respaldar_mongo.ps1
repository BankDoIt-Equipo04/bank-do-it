# =====================================================================
# BANKDOIT · respaldar_mongo.ps1  (#58)
# Respalda la base de análisis bankdoit_analytics (resúmenes con su hora
# de corte) con mongodump y aplica la retención.
#   .\respaldar_mongo.ps1                      contenedor del compose de analytics
#   $env:MONGO_CONTENEDOR = 'otro'; .\respaldar_mongo.ps1
# Salida en .\respaldos (fuera del repositorio):
#   mongo_<fecha>.archive.gz   y   mongo_<fecha>.json (manifiesto)
# Retención: el más reciente de cada uno de los últimos 7 días y de cada
# una de las últimas 4 semanas, igual que PostgreSQL (#57).
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$proyecto = if ($env:MONGO_PROYECTO) { $env:MONGO_PROYECTO } else { 'bankdoit-analytics' }
$c = $env:MONGO_CONTENEDOR
if (-not $c) { $c = (docker compose -p $proyecto -f compose.yaml ps -q mongo 2>$null | Select-Object -First 1) }
if (-not $c -or "$(docker inspect -f '{{.State.Running}}' $c 2>$null)".Trim() -ne 'true') {
    Write-Host "MongoDB de análisis no está corriendo (proyecto $proyecto)." -ForegroundColor Red; exit 1
}
$BASE = 'bankdoit_analytics'
$fecha = Get-Date -Format 'yyyyMMdd-HHmmss'
$archivo = "mongo_$fecha.archive.gz"
New-Item -ItemType Directory -Force respaldos | Out-Null

# Estado de la base al respaldar (para validar la restauración).
$consulta = @"
const r = {};
for (const n of db.getCollectionNames().sort()) {
  r[n] = { documentos: db.getCollection(n).countDocuments(),
           cortes: db.getCollection(n).find({}, {corte_utc: 1}).sort({_id: 1}).toArray()
                    .map(d => ({ id: String(d._id), corte_utc: d.corte_utc ? d.corte_utc.toISOString() : null })) };
}
print(JSON.stringify(r));
"@
$estado = docker exec $c mongosh --quiet $BASE --eval $consulta 2>&1 | Select-Object -Last 1

docker exec $c mongodump --quiet --db $BASE --gzip --archive="/tmp/$archivo" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'mongodump falló.' -ForegroundColor Red; exit 1 }
docker cp "${c}:/tmp/$archivo" "respaldos\$archivo" 2>&1 | Out-Null
docker exec $c rm -f "/tmp/$archivo" | Out-Null
$sha = (Get-FileHash "respaldos\$archivo" -Algorithm SHA256).Hash.ToLower()

# Retención.
$todos = Get-ChildItem respaldos -Filter 'mongo_*.archive.gz' | Sort-Object Name -Descending
$conservar = @{}; $dias = @{}; $semanas = @{}
foreach ($f in $todos) {
    $d = $f.Name.Substring(6, 8)
    $fechaArchivo = [datetime]::ParseExact($d, 'yyyyMMdd', $null)
    # Windows PowerShell 5.1 no tiene ISOWeek: semana con regla ISO (lunes, primera semana de 4 días).
    $semana = '{0}-{1}' -f $fechaArchivo.Year, [Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear($fechaArchivo, [Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
    if (-not $dias.ContainsKey($d) -and $dias.Count -lt 7) { $dias[$d] = 1; $conservar[$f.Name] = 1 }
    if (-not $semanas.ContainsKey($semana) -and $semanas.Count -lt 4) { $semanas[$semana] = 1; $conservar[$f.Name] = 1 }
}
$borrados = 0
foreach ($f in $todos) {
    if (-not $conservar.ContainsKey($f.Name)) {
        Remove-Item $f.FullName, ($f.FullName -replace '\.archive\.gz$', '.json') -ErrorAction SilentlyContinue
        $borrados++
    }
}

[ordered]@{
    fecha = $fecha; base = $BASE; archivo = $archivo; bytes = (Get-Item "respaldos\$archivo").Length; sha256 = $sha
    colecciones = ($estado | ConvertFrom-Json)
    retencion = "$($conservar.Count) conservados, $borrados eliminados"
} | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 "respaldos\mongo_$fecha.json"

Write-Host ("Respaldo de MongoDB: respaldos\{0} ({1:N0} bytes) · retención: {2} conservados, {3} eliminados" -f $archivo, (Get-Item "respaldos\$archivo").Length, $conservar.Count, $borrados) -ForegroundColor Green
"FECHA_RESPALDO=$fecha"
