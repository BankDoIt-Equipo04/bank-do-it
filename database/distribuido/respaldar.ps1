# =====================================================================
# BANKDOIT · respaldar.ps1  (#57)
# Respalda el primario de cada fragmento (lógico + físico) en .\respaldos
# y aplica la retención. Detecta qué instancia es primaria, así que
# también funciona después de promover una réplica (#18).
# Uso (desde database\distribuido):   .\respaldar.ps1
# Para programarlo a diario: Programador de tareas de Windows con
#   powershell -File <ruta>\respaldar.ps1
# Copia .\respaldos a otro equipo o almacenamiento externo cifrado: un
# respaldo que vive solo en el mismo disco no protege de perderlo.
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }
$fecha = Get-Date -Format 'yyyyMMdd-HHmmss'
$candidatos = @('nodo-a-primario-impar', 'nodo-b-primario-par', 'nodo-a-replica-par', 'nodo-b-replica-impar', 'nodo-b-replica-par') | ForEach-Object { "$P$_" }

function Q($c, $sql) {
    $s = docker exec $c psql -U $usuarioBD -d $baseBD -tAqX -c $sql 2>&1
    (($s | ForEach-Object { "$_" }) -join "`n").Trim()
}

# Primario de cada fragmento.
$primarios = @{}
foreach ($c in $candidatos) {
    if ("$(docker inspect -f '{{.State.Running}}' $c 2>$null)".Trim() -ne 'true') { continue }
    if ((Q $c 'SELECT pg_is_in_recovery()') -ne 'f') { continue }
    $primarios[(Q $c 'SELECT nombre FROM fragmento_local')] = $c
}
if ($primarios.Count -eq 0) { Write-Host 'No hay primarios corriendo.' -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Force respaldos\manifiestos | Out-Null
$fallos = 0
foreach ($frag in ($primarios.Keys | Sort-Object)) {
    $c = $primarios[$frag]
    Write-Host "== Respaldando el fragmento $frag desde $c ==" -ForegroundColor Cyan
    $salida = docker exec -u postgres $c bash /scripts/respaldar.sh $fecha 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { Write-Host ($salida -join "`n") -ForegroundColor Red; $fallos++; continue }
    $datos = @{}
    $salida | Where-Object { $_ -match '^([a-z_]+)=(.*)$' } | ForEach-Object { $datos[$Matches[1]] = $Matches[2] }
    $log = $datos.logico -split ' '
    $conteos = Q $c ("SELECT json_build_object(" +
        "'usuario', (SELECT count(*) FROM usuario), 'bankroll', (SELECT count(*) FROM bankroll), " +
        "'apuesta', (SELECT count(*) FROM apuesta), 'movimiento', (SELECT count(*) FROM movimiento), " +
        "'partido', (SELECT count(*) FROM partido), 'saldo_total', (SELECT COALESCE(sum(saldo_disponible), 0) FROM bankroll), " +
        "'en_juego_total', (SELECT COALESCE(sum(monto_en_juego), 0) FROM bankroll), " +
        "'restricciones', (SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public'), " +
        "'triggers', (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal))")
    $manifiesto = [ordered]@{
        fecha = $fecha; fragmento = $frag; instancia = $c
        logico = $log[0]; logico_bytes = [int64]$log[1]; logico_sha256 = $log[2]
        fisico = ($datos.fisico -split ' ')[0]; fisico_bytes = [int64](($datos.fisico -split ' ')[1])
        wal_archivados = [int]$datos.wal_archivados
        retencion = "$($datos.retencion_logicos); físicos: $($datos.retencion_fisicos)"
        conteos = ($conteos | ConvertFrom-Json)
    }
    $ruta = "respaldos\manifiestos\${frag}_$fecha.json"
    $manifiesto | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $ruta
    Write-Host ("  lógico: {0} ({1:N0} bytes)" -f $manifiesto.logico, $manifiesto.logico_bytes)
    Write-Host ("  físico: {0} ({1:N0} bytes)" -f $manifiesto.fisico, $manifiesto.fisico_bytes)
    Write-Host "  WAL archivado: $($manifiesto.wal_archivados) segmentos · retención: $($manifiesto.retencion)"
    Write-Host "  manifiesto: $ruta"
}
if ($fallos) { exit 1 }
Write-Host ">>> Respaldo $fecha terminado" -ForegroundColor Green
"FECHA_RESPALDO=$fecha"
