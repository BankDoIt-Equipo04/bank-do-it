# =====================================================================
# BANKDOIT · monitorear.ps1  (#59)
# Muestra el estado de las instancias de PostgreSQL y alerta si:
#   - una instancia no responde,
#   - un primario no tiene su réplica síncrona,
#   - hay escrituras esperando a la réplica (wait_event = 'SyncRep'),
#   - una réplica va atrasada, el archivado de WAL falla,
#   - el último mantenimiento encontró bankrolls descuadrados,
#   - las conexiones pasan del 80 % del máximo.
# Uso (desde database\distribuido):
#   .\monitorear.ps1                   una revisión (código de salida 1 si hay alertas)
#   .\monitorear.ps1 -Continuo         revisa cada 5 s hasta Ctrl+C
#   .\monitorear.ps1 -Json             salida en JSON (para pruebas y evidencia)
# =====================================================================
param([switch]$Continuo, [int]$Intervalo = 5, [switch]$Json)
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }
$UMBRAL_BYTES = 16MB
$UMBRAL_SEGUNDOS = 30
$instancias = 'nodo-a-primario-impar', 'nodo-b-replica-impar', 'nodo-b-primario-par', 'nodo-a-replica-par', 'nodo-b-replica-par' | ForEach-Object { "$P$_" }

function Q($c, $sql) {
    $s = docker exec $c psql -U $usuarioBD -d $baseBD -tAqX -c $sql 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    (($s | ForEach-Object { "$_" }) -join '').Trim()
}

function Revisar {
    $filas = @(); $alertas = @(); $replicas = @()
    foreach ($c in $instancias) {
        $existe = docker inspect -f '{{.State.Running}}' $c 2>$null
        if ($LASTEXITCODE -ne 0) { continue }                         # no es parte de esta instalación
        if ("$existe".Trim() -ne 'true') {
            $filas += [pscustomobject]@{ Instancia = $c; Rol = 'caída'; Fragmento = '—' }
            $alertas += "$c no está corriendo"; continue
        }
        $n = Q $c 'SELECT row_to_json(e) FROM estado_nodo() e'
        if (-not $n) {
            $filas += [pscustomobject]@{ Instancia = $c; Rol = 'sin respuesta'; Fragmento = '—' }
            $alertas += "$c no responde a consultas"; continue
        }
        $e = $n | ConvertFrom-Json
        if ($e.rol -eq 'primario') {
            $r = Q $c "SELECT COALESCE(json_agg(row_to_json(r)), '[]') FROM estado_replicacion() r"
            foreach ($x in @((ConvertFrom-Json $r) | ForEach-Object { $_ })) {
                $replicas += [pscustomobject]@{ Primario = $c; Replica = $x.replica; Estado = $x.estado; Sincronia = $x.sincronia
                                                BytesPendientes = $x.bytes_pendientes; RetrasoAplicacion = $x.retraso_aplicacion }
                if ([decimal]$x.bytes_pendientes -gt $UMBRAL_BYTES) { $alertas += "$($x.replica) va atrasada $([math]::Round($x.bytes_pendientes / 1MB, 1)) MB respecto a $c" }
            }
            if ($e.replicas_esperadas -gt $e.replicas_sync) { $alertas += "$c no tiene su réplica síncrona: las escrituras no se pueden confirmar" }
            if ($e.esperando_replica -gt 0) { $alertas += "$c tiene $($e.esperando_replica) escritura(s) esperando a la réplica (SyncRep)" }
        } elseif ($null -ne $e.retraso_replica_segundos -and [decimal]$e.retraso_replica_segundos -gt $UMBRAL_SEGUNDOS) {
            $alertas += "$c (réplica) lleva $($e.retraso_replica_segundos) s sin aplicar lo recibido"
        }
        if (-not $e.archivo_al_dia) { $alertas += "$c no está archivando el WAL (último fallo $($e.ultimo_fallo_archivo))" }
        if ($e.descuadres_ultimo_mantenimiento -gt 0) { $alertas += "${c}: el último mantenimiento encontró $($e.descuadres_ultimo_mantenimiento) bankroll(s) descuadrado(s)" }
        if ($e.conexiones -gt 0.8 * $e.conexiones_max) { $alertas += "$c usa $($e.conexiones) de $($e.conexiones_max) conexiones" }
        if ($e.esperando_bloqueo -gt 0) { $alertas += "$c tiene $($e.esperando_bloqueo) sesión(es) esperando un bloqueo" }
        $filas += [pscustomobject]@{
            Instancia = $c; Fragmento = $e.fragmento; Rol = $e.rol
            'Réplica sync' = if ($e.rol -eq 'primario') { "$($e.replicas_sync)/$($e.replicas_esperadas)" } else { '—' }
            'Esperando réplica' = $e.esperando_replica
            'Retraso réplica' = if ($e.rol -eq 'réplica') { "$($e.retraso_replica_segundos) s" } else { '—' }
            Conexiones = "$($e.conexiones)/$($e.conexiones_max)"
            'WAL archivado' = if ($e.archivo_al_dia) { "ok ($($e.archivados))" } else { 'FALLA' }
            Mantenimiento = if ($e.ultimo_mantenimiento) { "$($e.descuadres_ultimo_mantenimiento) descuadres" } else { 'sin ejecutar' }
        }
    }
    [pscustomobject]@{ Fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Instancias = $filas; Replicas = $replicas; Alertas = $alertas }
}

do {
    $estado = Revisar
    if ($Json) { $estado | ConvertTo-Json -Depth 5 }
    else {
        if ($Continuo) { Clear-Host }
        Write-Host "BANKDOIT · estado de PostgreSQL · $($estado.Fecha)" -ForegroundColor Cyan
        $estado.Instancias | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        if ($estado.Replicas) {
            Write-Host 'Replicación' -ForegroundColor Cyan
            $estado.Replicas | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        }
        if ($estado.Alertas.Count) { $estado.Alertas | ForEach-Object { Write-Host "ALERTA  $_" -ForegroundColor Red } }
        else { Write-Host 'Sin alertas.' -ForegroundColor Green }
    }
    if ($Continuo) { Start-Sleep -Seconds $Intervalo }
} while ($Continuo)
if (-not $Continuo) { exit ([int]($estado.Alertas.Count -gt 0)) }
