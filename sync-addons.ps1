# Sincroniza extra-addons/aura_odoo_19 con la copia viva del contenedor de
# desarrollo (odoo-vm). Es un espejo destructivo: borra la carpeta local y la
# vuelve a traer entera desde el contenedor, asi que cualquier edicion local
# que no este tambien en el contenedor se pierde.
#
# Va por tar en vez de "docker cp" directo porque node_modules tiene enlaces
# simbolicos y crearlos en Windows exige privilegios que la sesion no tiene;
# node_modules se excluye (se regenera con npm install) y el resto se copia
# tal cual, .git incluido.
#
#   Uso:  .\sync-addons.ps1

$ErrorActionPreference = 'Stop'

$Contenedor  = 'odoo-vm'
$PadreRemoto = '/home/odoo/odoo19/extra-addons'
$Carpeta     = 'aura_odoo_19'
$PadreLocal  = Join-Path $PSScriptRoot 'extra-addons'
$RutaLocal   = Join-Path $PadreLocal $Carpeta
$TarRemoto   = "/tmp/$Carpeta.tar"
$TarLocal    = Join-Path $env:TEMP "$Carpeta.tar"

# El contenedor tiene que estar arriba: docker cp no funciona si esta parado.
$estado = docker inspect -f '{{.State.Running}}' $Contenedor
if ($estado -ne 'true') { throw "El contenedor $Contenedor no esta en ejecucion." }

Write-Host "Empaquetando ${Contenedor}:$PadreRemoto/$Carpeta ..."
docker exec $Contenedor tar --exclude=node_modules -cf $TarRemoto -C $PadreRemoto $Carpeta
if ($LASTEXITCODE -ne 0) { throw "tar dentro del contenedor fallo ($LASTEXITCODE)." }

try {
    docker cp "${Contenedor}:${TarRemoto}" $TarLocal
    if ($LASTEXITCODE -ne 0) { throw "docker cp fallo ($LASTEXITCODE)." }

    if (Test-Path $RutaLocal) {
        Write-Host "Borrando $RutaLocal ..."
        Remove-Item -Recurse -Force $RutaLocal
    }

    Write-Host "Extrayendo en $PadreLocal ..."
    tar -xf $TarLocal -C $PadreLocal
    if ($LASTEXITCODE -ne 0) { throw "tar local fallo ($LASTEXITCODE)." }
}
finally {
    docker exec $Contenedor rm -f $TarRemoto | Out-Null
    if (Test-Path $TarLocal) { Remove-Item -Force $TarLocal }
}

Write-Host "Listo: $RutaLocal actualizado."
