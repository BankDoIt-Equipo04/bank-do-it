# BANKDOIT · Genera los certificados TLS de prueba en .\certs (#32).
# No sobrescribe los existentes. Para el despliegue real, agrega la IP de
# la VPN de cada equipo antes de generarlos, por ejemplo:
#   $env:NODO_A_SAN_EXTRA = 'IP:100.64.0.11'; $env:NODO_B_SAN_EXTRA = 'IP:100.64.0.12'
#   .\generar_certificados.ps1
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$certs = (Resolve-Path .\certs).Path
docker run --rm -v "${certs}:/certs" -e NODO_A_SAN_EXTRA -e NODO_B_SAN_EXTRA postgres:16.4 bash /certs/generar.sh
exit $LASTEXITCODE
