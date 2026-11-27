# =====================================================================
# BANKDOIT · probar_monitoreo.ps1  (#59)
# Comprueba el monitoreo antes, durante y después de una partición de red
# entre el Nodo A y el Nodo B, con monitorear.ps1 y (si está levantado el
# perfil "monitoreo") con las métricas de Prometheus.
# Requiere: levantar_y_probar.ps1 + configurar_acceso_api.ps1.
# Evidencia: evidencia\evidencia_monitoreo.md
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$A_PRIM = "${P}nodo-a-primario-impar"; $A_REPL = "${P}nodo-a-replica-par"
$B_PRIM = "${P}nodo-b-primario-par";   $B_REPL = "${P}nodo-b-replica-impar"
$RED = "${PROYECTO}_default"
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1]] = $Matches[2].Trim() }
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }
$puertoProm = if ($env:PUERTO_PROMETHEUS) { $env:PUERTO_PROMETHEUS } else { '9090' }
$script:fallos = 0
$filas = New-Object System.Collections.Generic.List[object]
$fotos = [ordered]@{}

function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Verificar($ok, $fase, $prueba, $obtenido) {
    $filas.Add([pscustomobject]@{ Fase = $fase; Prueba = $prueba; Obtenido = "$obtenido"; Ok = [bool]$ok })
    if ($ok) { Write-Host "OK    $prueba -> $obtenido" -ForegroundColor Green }
    else { Write-Host "FALLO $prueba ($obtenido)" -ForegroundColor Red; $script:fallos++ }
}
function Estado { (& .\monitorear.ps1 -Json 2>$null | Out-String) | ConvertFrom-Json }
function Prom($consulta) {
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$puertoProm/api/v1/query?query=$([uri]::EscapeDataString($consulta))" -TimeoutSec 5
        return @($r.data.result | ForEach-Object { [pscustomobject]@{ Instancia = $_.metric.instancia; Valor = [double]$_.value[1] } })
    } catch { return $null }
}
function Esperar([scriptblock]$condicion, $segundos = 90) {
    $limite = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $limite) { if (& $condicion) { return $true }; Start-Sleep -Seconds 3 }
    return $false
}
$hayProm = $null -ne (Prom 'up')
Write-Host ("Prometheus en el puerto {0}: {1}" -f $puertoProm, $(if ($hayProm) { 'disponible' } else { 'no levantado (solo se prueba monitorear.ps1)' }))

# ------------------------------------------------------------ 1. normal
Titulo 'Antes de la partición'
$e = Estado; $fotos['Antes de la partición'] = $e
Verificar ($e.Alertas.Count -eq 0) 'Antes' 'monitorear.ps1 sin alertas' "$($e.Alertas.Count) alertas"
Verificar (@($e.Replicas | Where-Object Sincronia -eq 'sync').Count -eq 2) 'Antes' 'Dos réplicas síncronas' (($e.Replicas | ForEach-Object { "$($_.Replica)=$($_.Sincronia)" }) -join ', ')
if ($hayProm) {
    Start-Sleep -Seconds 8
    $up = Prom 'pg_up'
    Verificar (@($up | Where-Object Valor -eq 1).Count -eq 4) 'Antes' 'Prometheus: pg_up de las 4 instancias' (($up | ForEach-Object { "$($_.Instancia)=$($_.Valor)" }) -join ', ')
    $sync = Prom 'bankdoit_nodo_replicas_sync{rol="primario"}'
    Verificar (@($sync | Where-Object Valor -eq 1).Count -eq 2) 'Antes' 'Prometheus: réplica síncrona por primario' (($sync | ForEach-Object { "$($_.Instancia)=$($_.Valor)" }) -join ', ')
}

# ----------------------------------------------------------- 2. partición
Titulo 'Durante la partición (Nodo B desconectado)'
docker network disconnect $RED $B_PRIM 2>&1 | Out-Null
docker network disconnect $RED $B_REPL 2>&1 | Out-Null
$usuario = (docker exec $A_PRIM psql -U $usuarioBD -d $baseBD -tAqc 'SELECT min(usuario_id) FROM bankroll WHERE saldo_disponible >= 5' | Out-String).Trim()
docker exec -d $A_PRIM psql -U $usuarioBD -d $baseBD -c "SELECT registrar_apuesta($usuario, 'monitoreo-$(Get-Date -Format HHmmss)', 101, 'América', 5.00, 2.00)" | Out-Null
$ok = Esperar { $x = Estado; ($x.Alertas -match 'esperando a la réplica').Count -gt 0 -and ($x.Alertas -match 'no tiene su réplica síncrona').Count -ge 2 } 60
$e = Estado; $fotos['Durante la partición'] = $e
$e.Alertas | ForEach-Object { Write-Host "  ALERTA $_" -ForegroundColor Yellow }
Verificar (($e.Alertas -match "$A_PRIM no tiene su réplica síncrona").Count -eq 1) 'Durante' 'Alerta: primario impar sin réplica síncrona' (($e.Alertas -match $A_PRIM) -join ' / ')
Verificar (($e.Alertas -match "$B_PRIM no tiene su réplica síncrona").Count -eq 1) 'Durante' 'Alerta: primario par sin réplica síncrona' (($e.Alertas -match "$B_PRIM no tiene") -join ' / ')
Verificar (($e.Alertas -match 'esperando a la réplica').Count -ge 1) 'Durante' 'Alerta: escrituras esperando a la réplica' (($e.Alertas -match 'esperando') -join ' / ')
if ($hayProm) {
    Start-Sleep -Seconds 8
    $esp = Prom "bankdoit_nodo_esperando_replica{instancia=`"nodo-a-primario-impar`"}"
    Verificar ($esp -and $esp[0].Valor -ge 1) 'Durante' 'Prometheus: escrituras esperando en el primario impar' $(if ($esp) { $esp[0].Valor } else { 'sin dato' })
    # Si el exportador no alcanza su instancia, Prometheus marca up = 0 y pg_up deja de existir.
    Esperar { @(Prom 'up{job="postgres"} == 0 or pg_up' | Where-Object Valor -eq 0).Count -ge 2 } 45 | Out-Null
    $up = Prom 'up{job="postgres"} == 0 or pg_up'
    $abajo = @($up | Where-Object Valor -eq 0 | ForEach-Object Instancia)
    Verificar ($abajo.Count -ge 2) 'Durante' 'Prometheus: instancias del Nodo B inalcanzables (pg_up = 0)' ($abajo -join ', ')
}

# ------------------------------------------------------- 3. recuperación
Titulo 'Después de restablecer la red'
docker network connect --alias nodo-b-primario-par $RED $B_PRIM 2>&1 | Out-Null
docker network connect --alias nodo-b-replica-impar $RED $B_REPL 2>&1 | Out-Null
$ok = Esperar { (Estado).Alertas.Count -eq 0 } 120
$e = Estado; $fotos['Después de restablecer la red'] = $e
Verificar ($e.Alertas.Count -eq 0) 'Después' 'monitorear.ps1 vuelve a cero alertas' "$($e.Alertas.Count) alertas"
if ($hayProm) {
    $ok = Esperar { $s = Prom 'bankdoit_nodo_esperando_replica'; $u = Prom 'pg_up'; $s -and @($s | Where-Object Valor -gt 0).Count -eq 0 -and @($u | Where-Object Valor -eq 1).Count -eq 4 } 60
    $u = Prom 'pg_up'
    Verificar $ok 'Después' 'Prometheus: 4 instancias arriba y 0 escrituras en espera' (($u | ForEach-Object { "$($_.Instancia)=$($_.Valor)" }) -join ', ')
}

# ------------------------------------------------------------ evidencia
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Evidencia: monitoreo de PostgreSQL distribuido (#59)'); $md.Add('')
$md.Add("Generado por ``database/distribuido/probar_monitoreo.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm') sobre la simulación de dos nodos (proyecto ``$PROYECTO``). Prometheus: $(if ($hayProm) { 'sí' } else { 'no' }).")
foreach ($fase in $fotos.Keys) {
    $x = $fotos[$fase]
    $md.Add(''); $md.Add("## $fase ($($x.Fecha))"); $md.Add('')
    $md.Add('| Instancia | Fragmento | Rol | Réplica sync | Esperando réplica | Retraso réplica | Conexiones | WAL archivado | Mantenimiento |'); $md.Add('| --- | --- | --- | --- | ---: | --- | --- | --- | --- |')
    foreach ($i in $x.Instancias) { $md.Add("| ``$($i.Instancia)`` | $($i.Fragmento) | $($i.Rol) | $($i.'Réplica sync') | $($i.'Esperando réplica') | $($i.'Retraso réplica') | $($i.Conexiones) | $($i.'WAL archivado') | $($i.Mantenimiento) |") }
    if ($x.Replicas) {
        $md.Add(''); $md.Add('| Primario | Réplica | Estado | Sincronía | Bytes pendientes |'); $md.Add('| --- | --- | --- | --- | ---: |')
        foreach ($r in $x.Replicas) { $md.Add("| ``$($r.Primario)`` | $($r.Replica) | $($r.Estado) | $($r.Sincronia) | $($r.BytesPendientes) |") }
    }
    $md.Add('')
    if ($x.Alertas.Count) { $x.Alertas | ForEach-Object { $md.Add("- **ALERTA** $_") } } else { $md.Add('Sin alertas.') }
}
$md.Add(''); $md.Add('## Comprobaciones'); $md.Add('')
$md.Add('| Fase | Prueba | Obtenido | |'); $md.Add('| --- | --- | --- | --- |')
foreach ($f in $filas) { $md.Add("| $($f.Fase) | $($f.Prueba) | $($f.Obtenido -replace '\|', '/') | $(if ($f.Ok) { '✔' } else { '✘' }) |") }
New-Item -ItemType Directory -Force evidencia | Out-Null
$md | Out-File -Encoding utf8 evidencia\evidencia_monitoreo.md

Write-Host ''
Write-Host 'Evidencia guardada en evidencia\evidencia_monitoreo.md'
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
