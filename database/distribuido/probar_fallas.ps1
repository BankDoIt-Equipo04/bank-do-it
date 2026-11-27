# =====================================================================
# BANKDOIT · probar_fallas.ps1  (#18)
# Sobre la simulación de #17 ejecuta, por separado:
#   Escenario 1: partición de red entre el Nodo A y el Nodo B.
#   Escenario 2: caída del primario par (Nodo B), aislamiento, promoción
#                controlada de su réplica y resincronización del equipo.
# Registra qué operaciones se confirman en cada escenario y guarda la
# evidencia de saldos y movimientos en evidencia\evidencia_fallas.md.
# Uso (desde database\distribuido):   .\probar_fallas.ps1
# =====================================================================
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

# ------------------------------------------------------------ Ayudantes
$cfg = @{}
Get-Content .env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object {
    $cfg[$Matches[1]] = $Matches[2].Trim()
}
$usuarioBD = if ($cfg.POSTGRES_USER) { $cfg.POSTGRES_USER } else { 'bankdoit' }
$baseBD    = if ($cfg.POSTGRES_DB)   { $cfg.POSTGRES_DB }   else { 'bankdoit' }

# Proyecto y prefijo configurables para ensayar sin tocar otra instalación:
#   $env:BANKDOIT_PROYECTO='bankdoit-ensayo'; $env:BANKDOIT_PREFIJO='ensayo-'
$PROYECTO = if ($env:BANKDOIT_PROYECTO) { $env:BANKDOIT_PROYECTO } else { 'bankdoit-distribuido' }
$P = if ($env:BANKDOIT_PREFIJO) { $env:BANKDOIT_PREFIJO } else { '' }
$A_PRIM = "${P}nodo-a-primario-impar"
$A_REPL = "${P}nodo-a-replica-par"
$B_PRIM = "${P}nodo-b-primario-par"
$B_REPL = "${P}nodo-b-replica-impar"
$B_RECU = "${P}nodo-b-replica-par"
$RED    = "${PROYECTO}_default"
$perfiles = @('-p', $PROYECTO, '--profile', 'nodo-a', '--profile', 'nodo-b', '--profile', 'recuperacion')
$script:fallos = 0
$md = New-Object System.Collections.Generic.List[string]

function Titulo($texto) {
    Write-Host ''; Write-Host "== $texto ==" -ForegroundColor Cyan
    $md.Add(''); $md.Add("### $texto"); $md.Add('')
}
function Nota($texto) { Write-Host $texto; $md.Add($texto); $md.Add('') }

function Q($contenedor, $sql) {
    $salida = docker exec $contenedor psql -U $usuarioBD -d $baseBD -tAqX -v ON_ERROR_STOP=1 -c $sql 2>&1
    $script:codigo = $LASTEXITCODE
    return (($salida | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Verificar($condicion, $nombre, $detalle = '') {
    if ($condicion) { Write-Host "OK    $nombre" -ForegroundColor Green }
    else { Write-Host "FALLO $nombre $detalle" -ForegroundColor Red; $script:fallos++ }
}

function Esperar($descripcion, [scriptblock]$condicion, $segundos = 120) {
    $limite = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $limite) {
        if (& $condicion) { return }
        Start-Sleep -Seconds 2
    }
    Write-Host "FALLO tiempo agotado esperando: $descripcion" -ForegroundColor Red
    $script:fallos++
}

function Corriendo($contenedor) {
    $r = docker inspect -f '{{.State.Running}}' $contenedor 2>$null
    return ($LASTEXITCODE -eq 0 -and "$r".Trim() -eq 'true')
}

# Lanza una escritura sin esperar su respuesta (como la app enviando un
# borrador). Sirve para ver si queda confirmada o en espera.
function EnSegundoPlano($contenedor, $sql) {
    docker exec -d $contenedor psql -U $usuarioBD -d $baseBD -X -c $sql 2>&1 | Out-Null
}
function EsperandoReplica($contenedor) {
    return [int](Q $contenedor "SELECT count(*) FROM pg_stat_activity WHERE wait_event = 'SyncRep'")
}

# Tabla de operaciones de cada escenario.
$operaciones = New-Object System.Collections.Generic.List[object]
function Operacion($escenario, $operacion, $instancia, $resultado, $detalle) {
    $color = switch -Wildcard ($resultado) { 'Confirmada*' { 'Green' } 'En espera*' { 'Yellow' } default { 'Red' } }
    Write-Host ("  {0,-48} {1,-24} {2}" -f $operacion, $resultado, $detalle) -ForegroundColor $color
    $operaciones.Add([pscustomobject]@{ Escenario = $escenario; Operacion = $operacion; Instancia = $instancia
                                         Resultado = $resultado; Detalle = $detalle })
}

# Foto de saldos y movimientos de los usuarios 3 y 4 en cada instancia.
function Foto($fase) {
    Write-Host ''; Write-Host "  Foto: $fase" -ForegroundColor DarkCyan
    $md.Add("**$fase** — saldo disponible / en juego (movimientos, apuestas)"); $md.Add('')
    $md.Add('| Instancia | Estado | Usuario 3 | Usuario 4 |'); $md.Add('| --- | --- | --- | --- |')
    foreach ($c in @($A_PRIM, $B_REPL, $B_PRIM, $A_REPL, $B_RECU)) {
        if (-not (Corriendo $c)) {
            $existe = docker inspect $c 2>$null; if ($LASTEXITCODE -ne 0) { continue }
            $md.Add("| $c | **caído** | — | — |"); Write-Host ("  {0,-24} caído" -f $c); continue
        }
        $rol = Q $c "SELECT CASE WHEN pg_is_in_recovery() THEN 'réplica' ELSE 'primario' END"
        $celda = foreach ($u in 3, 4) {
            $v = Q $c ("SELECT b.saldo_disponible || ' / ' || b.monto_en_juego || ' (' || " +
                       "(SELECT count(*) FROM movimiento m WHERE m.usuario_id = b.usuario_id) || ' mov, ' || " +
                       "(SELECT count(*) FROM apuesta a WHERE a.usuario_id = b.usuario_id) || ' ap)' " +
                       "FROM bankroll b WHERE b.usuario_id = $u")
            if ($v) { $v } else { '—' }
        }
        $md.Add("| $c | $rol | $($celda[0]) | $($celda[1]) |")
        Write-Host ("  {0,-24} {1,-9} u3: {2,-30} u4: {3}" -f $c, $rol, $celda[0], $celda[1])
    }
    $md.Add('')
}

function Disponible($contenedor, $usuario) {
    return [decimal](Q $contenedor "SELECT saldo_disponible FROM bankroll WHERE usuario_id = $usuario")
}
function Conciliar($contenedores) {
    foreach ($c in $contenedores) {
        Verificar ((Q $c 'SELECT bool_and(cuadra) FROM conciliar_bankroll()') -eq 't') "${c}: bankroll = movimientos = apuestas pendientes"
    }
}

# ---------------------------------------------------------------------
Write-Host '== Preparando la simulación de #17 desde cero ==' -ForegroundColor Cyan
& .\levantar_y_probar.ps1 *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'Falló levantar_y_probar.ps1; ejecútalo solo para ver el detalle.' -ForegroundColor Red; exit 1 }
Write-Host 'Simulación lista: 2 primarios, 2 réplicas síncronas, usuarios 3 y 4.'

$md.Add('# Evidencia de pruebas de falla (#18)'); $md.Add('')
$md.Add("Generado por ``database/distribuido/probar_fallas.ps1`` el $(Get-Date -Format 'yyyy-MM-dd HH:mm') (simulación de los dos nodos en una sola PC con Docker).")
$md.Add('')
$md.Add("PostgreSQL: $(Q $A_PRIM 'SHOW server_version') · Replicación física síncrona (``synchronous_commit = remote_apply``) · Catálogo por replicación lógica.")

# =====================================================================
Titulo 'Escenario 1: partición de red entre el Nodo A y el Nodo B'
$E1 = 'Partición de red'
Foto 'Antes de la partición'
$u3Antes = Disponible $A_PRIM 3; $u4Antes = Disponible $B_PRIM 4

docker network disconnect $RED $B_PRIM 2>&1 | Out-Null
docker network disconnect $RED $B_REPL 2>&1 | Out-Null
Nota 'Se desconectan de la red los dos contenedores del Nodo B: ningún nodo puede comunicarse con el otro, pero los cuatro siguen encendidos.'

Write-Host '  Operaciones durante la partición:'
$r = Q $A_PRIM 'SELECT saldo_disponible FROM bankroll WHERE usuario_id = 3'
Operacion $E1 'Consultar saldo del usuario 3' $A_PRIM $(if ($script:codigo -eq 0) { 'Confirmada (lectura)' } else { 'Rechazada' }) "disponible $r"
$r = Q $B_REPL 'SELECT saldo_disponible FROM bankroll WHERE usuario_id = 3'
Operacion $E1 'Consultar saldo del usuario 3 en su réplica' $B_REPL $(if ($script:codigo -eq 0) { 'Confirmada (lectura)' } else { 'Rechazada' }) "disponible $r (último dato confirmado)"
$r = Q $A_REPL 'SELECT saldo_disponible FROM bankroll WHERE usuario_id = 4'
Operacion $E1 'Consultar saldo del usuario 4 en su réplica' $A_REPL $(if ($script:codigo -eq 0) { 'Confirmada (lectura)' } else { 'Rechazada' }) "disponible $r (último dato confirmado)"

EnSegundoPlano $A_PRIM "SELECT * FROM registrar_apuesta(3, 'particion-ana', 101, 'América', 30.00, 2.00)"
EnSegundoPlano $B_PRIM "SELECT * FROM registrar_apuesta(4, 'particion-beto', 202, 'Eagles', 40.00, 2.20)"
EnSegundoPlano $A_PRIM "INSERT INTO partido (deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES (1, 2, 1, '2026-12-13 19:00-06')"
Start-Sleep -Seconds 6

$visible = Q $A_PRIM "SELECT count(*) FROM apuesta WHERE clave_operacion = 'particion-ana'"
$espera  = EsperandoReplica $A_PRIM
Verificar (($visible -eq '0') -and ($espera -ge 2)) 'primario impar: la apuesta y el partido quedan en espera de su réplica' "(visibles $visible, en espera $espera)"
Operacion $E1 'Registrar apuesta del usuario 3 ($30)' $A_PRIM 'En espera (no confirmada)' "COMMIT esperando a la réplica del Nodo B; nadie más la ve"
Operacion $E1 'Dar de alta un partido (catálogo)' $A_PRIM 'En espera (no confirmada)' 'el catálogo también requiere la copia síncrona'
$visible = Q $B_PRIM "SELECT count(*) FROM apuesta WHERE clave_operacion = 'particion-beto'"
$espera  = EsperandoReplica $B_PRIM
Verificar (($visible -eq '0') -and ($espera -ge 1)) 'primario par: la apuesta queda en espera de su réplica' "(visibles $visible, en espera $espera)"
Operacion $E1 'Registrar apuesta del usuario 4 ($40)' $B_PRIM 'En espera (no confirmada)' 'COMMIT esperando a la réplica del Nodo A'
$r = Q $B_REPL "SELECT registrar_apuesta(3, 'en-replica', 101, 'América', 10, 2)"
Operacion $E1 'Registrar apuesta en una réplica' $B_REPL $(if ($script:codigo -ne 0 -and $r -match 'read-only') { 'Rechazada' } else { 'Confirmada (error)' }) 'las réplicas son de solo lectura'

Foto 'Durante la partición (ninguna escritura confirmada; saldos sin cambios)'
Verificar ((Disponible $A_PRIM 3) -eq $u3Antes) 'el saldo del usuario 3 no cambió durante la partición'
Verificar ((Disponible $B_PRIM 4) -eq $u4Antes) 'el saldo del usuario 4 no cambió durante la partición'

Write-Host '  Restableciendo la red...'
docker network connect --alias nodo-b-primario-par $RED $B_PRIM 2>&1 | Out-Null
docker network connect --alias nodo-b-replica-impar $RED $B_REPL 2>&1 | Out-Null
Nota 'Se reconecta el Nodo B. Las réplicas vuelven a conectarse solas y los COMMIT que estaban en espera se confirman.'
Esperar 'que se confirmen las escrituras en espera' {
    ((EsperandoReplica $A_PRIM) -eq 0) -and ((EsperandoReplica $B_PRIM) -eq 0) -and
    ((Q $A_PRIM "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'replica_impar'") -eq 'sync') -and
    ((Q $B_PRIM "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'replica_par'") -eq 'sync')
} 120
Esperar 'catálogo al día en las cuatro instancias' {
    $n = Q $A_PRIM 'SELECT count(*) FROM partido'
    ((Q $B_PRIM 'SELECT count(*) FROM partido') -eq $n) -and ((Q $A_REPL 'SELECT count(*) FROM partido') -eq $n) -and
    ((Q $B_REPL 'SELECT count(*) FROM partido') -eq $n)
} 60

Verificar ((Q $B_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'particion-ana'") -eq '1') 'la apuesta del usuario 3 quedó confirmada en su primario y en su réplica'
Verificar ((Q $A_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'particion-beto'") -eq '1') 'la apuesta del usuario 4 quedó confirmada en su primario y en su réplica'
Verificar ((Disponible $A_PRIM 3) -eq ($u3Antes - 30)) "usuario 3: el disponible bajó exactamente `$30 ($(Disponible $A_PRIM 3))"
Verificar ((Disponible $B_PRIM 4) -eq ($u4Antes - 40)) "usuario 4: el disponible bajó exactamente `$40 ($(Disponible $B_PRIM 4))"
Verificar ((Disponible $B_REPL 3) -eq (Disponible $A_PRIM 3)) 'el saldo del usuario 3 es igual en primario y réplica'
Verificar ((Disponible $A_REPL 4) -eq (Disponible $B_PRIM 4)) 'el saldo del usuario 4 es igual en primario y réplica'

# La app no supo si su borrador se confirmó y lo reenvía con la misma clave.
$r = Q $A_PRIM "SELECT es_reenvio FROM registrar_apuesta(3, 'particion-ana', 101, 'América', 30.00, 2.00)"
$reservas = Q $A_PRIM "SELECT count(*) FROM movimiento m JOIN apuesta a USING (apuesta_id) WHERE a.clave_operacion = 'particion-ana' AND m.tipo = 'reserva'"
Verificar (($r -eq 't') -and ($reservas -eq '1')) 'el reenvío del borrador con la misma clave no cobra dos veces'
Operacion $E1 'Reenviar el borrador del usuario 3 tras reconectar' $A_PRIM 'Confirmada (sin doble cargo)' "es_reenvio = $r, reservas = $reservas"
Conciliar @($A_PRIM, $B_REPL, $B_PRIM, $A_REPL)
Foto 'Después de restablecer la red'

# =====================================================================
Titulo 'Escenario 2: caída del primario par (Nodo B) y recuperación controlada'
$E2 = 'Caída del primario'
Foto 'Antes de la caída'
$u4Antes = Disponible $B_PRIM 4
$u3Antes = Disponible $A_PRIM 3

docker kill $B_PRIM 2>&1 | Out-Null
Nota "Se apaga de golpe ``$B_PRIM`` (docker kill), como si la laptop de Luis (Nodo B) perdiera la corriente. La réplica impar del Nodo B sigue encendida."

Write-Host '  Operaciones con el primario par caído:'
$r = Q $A_REPL 'SELECT saldo_disponible FROM bankroll WHERE usuario_id = 4'
Operacion $E2 'Consultar saldo del usuario 4 en su réplica' $A_REPL $(if ($script:codigo -eq 0) { 'Confirmada (lectura)' } else { 'Rechazada' }) "disponible $r"
$r = Q $B_PRIM "SELECT registrar_apuesta(4, 'caida-beto', 101, 'Chivas', 10, 2)"
Operacion $E2 'Registrar apuesta del usuario 4' $B_PRIM $(if ($script:codigo -ne 0) { 'Rechazada' } else { 'Confirmada (error)' }) 'su primario no está disponible; la app guarda el borrador'
$r = Q $A_REPL "SELECT registrar_apuesta(4, 'caida-beto', 101, 'Chivas', 10, 2)"
Operacion $E2 'Registrar apuesta del usuario 4 en su réplica' $A_REPL $(if ($script:codigo -ne 0 -and $r -match 'read-only') { 'Rechazada' } else { 'Confirmada (error)' }) 'la réplica todavía es de solo lectura'
$r = Q $A_PRIM "SELECT apuesta_id FROM registrar_apuesta(3, 'caida-ana', 202, 'Chiefs', 15.00, 1.90)"
$ok = ($script:codigo -eq 0) -and ((Q $B_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'caida-ana'") -eq '1')
Verificar $ok 'el fragmento impar sigue funcionando y replicando'
Operacion $E2 'Registrar apuesta del usuario 3 ($15)' $A_PRIM $(if ($ok) { 'Confirmada' } else { 'Rechazada' }) 'su réplica (Nodo B) sigue arriba'
Foto 'Con el primario par caído'

Write-Host '  Paso 1: aislar el primario anterior'
docker update --restart=no $B_PRIM 2>&1 | Out-Null
docker network disconnect $RED $B_PRIM 2>&1 | Out-Null
Verificar (-not (Corriendo $B_PRIM)) 'el primario anterior está apagado y fuera de la red'
Nota "**Paso 1 · Aislar:** ``$B_PRIM`` queda apagado, sin reinicio automático y desconectado de la red. Así no puede volver como segundo primario (*split-brain*); su disco ya no se usa."

Write-Host '  Paso 2: promover la réplica par del Nodo A'
$r = Q $A_REPL 'SELECT pg_promote(true, 60)'
Verificar (($r -eq 't') -and ((Q $A_REPL 'SELECT pg_is_in_recovery()') -eq 'f')) "$A_REPL fue promovida a primario del fragmento par"
Nota "**Paso 2 · Promover:** ``SELECT pg_promote()`` en ``$A_REPL``. Ahora es el primario del fragmento par (en el Nodo A); el directorio de la API debe apuntar los usuarios pares a esta instancia."

EnSegundoPlano $A_REPL "SELECT * FROM registrar_apuesta(4, 'promovido-beto', 101, 'Chivas', 25.00, 2.40)"
Start-Sleep -Seconds 5
$visible = Q $A_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'promovido-beto'"
$espera = EsperandoReplica $A_REPL
Verificar (($visible -eq '0') -and ($espera -ge 1)) 'el nuevo primario no confirma escrituras hasta tener réplica' "(visibles $visible, en espera $espera)"
Operacion $E2 'Registrar apuesta del usuario 4 en el primario promovido ($25)' $A_REPL 'En espera (no confirmada)' 'no hay réplica síncrona todavía: no se confirma sin copia'

Write-Host '  Paso 3: resincronizar el equipo recuperado del Nodo B como réplica'
Q $A_REPL "SELECT pg_create_physical_replication_slot('replica_par')" | Out-Null
docker compose @perfiles up -d nodo-b-replica-par 2>&1 | Out-Null
Esperar 'réplica par reconstruida y síncrona' {
    ((Q $A_REPL "SELECT state || '/' || sync_state FROM pg_stat_replication WHERE application_name = 'replica_par'") -eq 'streaming/sync') -and
    ((EsperandoReplica $A_REPL) -eq 0)
} 180
Nota "**Paso 3 · Resincronizar:** el equipo del Nodo B se reconstruye como ``$B_RECU`` con ``pg_basebackup`` desde el nuevo primario (ranura ``replica_par``). Solo cuando la copia síncrona está al día se confirman las escrituras que estaban en espera."

Verificar ((Q $B_RECU 'SELECT pg_is_in_recovery()') -eq 't') "$B_RECU es réplica (solo lectura)"
Verificar ((Q $A_REPL "SELECT count(*) FROM apuesta WHERE clave_operacion = 'promovido-beto'") -eq '1') 'la apuesta en espera se confirmó al resincronizar'
# Una transacción que seguía en espera mientras se copiaba el primario
# ya está en la réplica, pero esta calcula su límite de visibilidad con
# el último id de transacción que vio terminar y la trata como futura
# (snapshot 819:819 en la depuración). Una transacción nueva en el
# primario mueve ese límite; se hace como último paso de la recuperación.
Q $A_REPL 'SELECT txid_current()' | Out-Null
Esperar 'la apuesta en espera visible en la réplica reconstruida' {
    (Q $B_RECU "SELECT count(*) FROM apuesta WHERE clave_operacion = 'promovido-beto'") -eq '1'
} 30
Verificar ((Q $B_RECU "SELECT count(*) FROM apuesta WHERE clave_operacion = 'promovido-beto'") -eq '1') 'y ya está en la réplica reconstruida'
Nota "**Paso 4 · Avanzar la visibilidad:** ``SELECT txid_current()`` en el nuevo primario. La réplica recién copiada trataba la apuesta que estaba en espera durante la copia como una transacción futura (su límite de visibilidad era ese mismo id) y no la mostraba hasta que terminara otra transacción. ``pg_log_standby_snapshot()`` y ``CHECKPOINT`` no lo resolvieron; una transacción nueva sí."
Verificar ((Disponible $A_REPL 4) -eq ($u4Antes - 25)) "usuario 4: el disponible bajó exactamente `$25 ($(Disponible $A_REPL 4))"
Verificar ((Disponible $B_RECU 4) -eq (Disponible $A_REPL 4)) 'el saldo del usuario 4 es igual en el nuevo primario y su réplica'
Verificar ((Disponible $A_PRIM 3) -eq ($u3Antes - 15)) 'usuario 3: solo se descontó su apuesta de $15'

$r = Q $A_REPL "SELECT apuesta_id FROM registrar_apuesta(4, 'post-recuperacion', 202, 'Eagles', 5.00, 2.10)"
$ok = ($script:codigo -eq 0) -and ((Q $B_RECU "SELECT count(*) FROM apuesta WHERE clave_operacion = 'post-recuperacion'") -eq '1')
Verificar $ok 'después de recuperar, una apuesta nueva se confirma de inmediato y se replica'
Operacion $E2 'Registrar apuesta del usuario 4 tras recuperar ($5)' $A_REPL $(if ($ok) { 'Confirmada' } else { 'Rechazada' }) "apuesta_id $r (par), replicada en $B_RECU"

Q $A_PRIM "INSERT INTO partido (deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES (2, 3, 4, '2026-12-20 18:00-06')" | Out-Null
Esperar 'catálogo replicado al primario par promovido' {
    (Q $A_REPL 'SELECT count(*) FROM partido') -eq (Q $A_PRIM 'SELECT count(*) FROM partido')
} 90
Verificar ((Q $A_REPL 'SELECT count(*) FROM partido') -eq (Q $A_PRIM 'SELECT count(*) FROM partido')) 'la suscripción del catálogo continuó en el primario promovido'
Conciliar @($A_PRIM, $B_REPL, $A_REPL, $B_RECU)
Foto 'Después de recuperar el servicio'

# ------------------------------------------------------- Evidencia (.md)
$md.Add(''); $md.Add('### Operaciones en cada escenario'); $md.Add('')
$md.Add('| Escenario | Operación | Instancia | Resultado | Detalle |'); $md.Add('| --- | --- | --- | --- | --- |')
foreach ($o in $operaciones) { $md.Add("| $($o.Escenario) | $($o.Operacion) | ``$($o.Instancia)`` | $($o.Resultado) | $($o.Detalle) |") }
$md.Add(''); $md.Add('### Movimientos después de las pruebas'); $md.Add('')
$md.Add('| Instancia | Usuario | Tipo | Cambio disponible | Cambio en juego | Apuesta |'); $md.Add('| --- | --- | --- | ---: | ---: | --- |')
foreach ($par in @(@($A_PRIM, 3), @($A_REPL, 4))) {
    $filas = Q $par[0] ("SELECT m.usuario_id || '|' || m.tipo || '|' || m.cambio_disponible || '|' || m.cambio_en_juego || '|' || " +
                        "COALESCE(a.clave_operacion, '—') FROM movimiento m LEFT JOIN apuesta a USING (apuesta_id) " +
                        "WHERE m.usuario_id = $($par[1]) ORDER BY m.movimiento_id")
    foreach ($f in ($filas -split "`n")) { $c = $f -split '\|'; $md.Add("| ``$($par[0])`` | $($c[0]) | $($c[1]) | $($c[2]) | $($c[3]) | $($c[4]) |") }
}
New-Item -ItemType Directory -Force evidencia | Out-Null
$md | Out-File -Encoding utf8 evidencia\evidencia_fallas.md

Write-Host ''
Write-Host 'Resumen de operaciones:' -ForegroundColor Cyan
$operaciones | Format-Table Escenario, Operacion, Resultado -AutoSize | Out-String -Width 200 | Write-Host
Write-Host 'Evidencia guardada en evidencia\evidencia_fallas.md'
if ($script:fallos -eq 0) { Write-Host '>>> TODAS LAS COMPROBACIONES PASARON' -ForegroundColor Green; exit 0 }
Write-Host ">>> $($script:fallos) comprobación(es) fallaron" -ForegroundColor Red
exit 1
