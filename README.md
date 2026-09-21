# aura_stack

Odoo + Dash + PostgreSQL/TimescaleDB en Docker.
**Node-RED NO está aquí**: sigue nativo en Windows y se conecta a `localhost:5433`.

## Puertos

Este stack convive con el contenedor de desarrollo `odoo-vm`, que ocupa
5432, 8069, 8072 y 5678. Para no chocar con él, `aura_stack` publica sus
servicios **corridos**:

| Servicio | Puerto en el host | Puerto interno |
|---|---|---|
| Odoo | 8169 | 8069 |
| Dash | 8150 | 8050 |
| Postgres | 5433 (solo `127.0.0.1`) | 5432 |

Los puertos **internos** no cambian: dentro de la red de Compose los servicios
se hablan por nombre (`db:5432`), y `odoo.conf` sigue con `db_port = 5432`. Solo
cambia el mapeo hacia Windows. Si algún día `odoo-vm` desaparece, se pueden
devolver a los originales — pero no hace falta.

## Primer arranque, paso a paso

Todo se ejecuta desde esta carpeta (la que contiene `docker-compose.yml`).

### 0. Comprobaciones previas

```powershell
docker version                      # Docker Desktop tiene que estar corriendo
netstat -ano | findstr :5433        # si algo ya escucha ahí, el contenedor no podrá bindear
docker ps --format "{{.Names}} {{.Ports}}"   # ver qué contenedores ya ocupan puertos
```

Las dos causas habituales de que `db` no levante son un Postgres nativo de
Windows y **otro contenedor** publicando el mismo puerto. El error se reconoce
así:

```
Bind for 0.0.0.0:5432 failed: port is already allocated
```

`netstat` solo da el PID de `com.docker.backend`, que no dice cuál contenedor
es; el `docker ps` de arriba sí.

### 1. Crear el `.env`

```powershell
copy .env.example .env
notepad .env                        # cambiar LAS 5 contraseñas
```

Compose lee `.env` solo y sustituye cada `${VAR}` del compose. Si falta una
variable la reemplaza por vacío y Postgres arranca roto: este es el paso cero.

Dos reglas al elegir contraseñas:

- **`PG_SUPERUSER` se deja en `postgres`.** Si se pone `odoo`, choca con el rol
  `odoo` que crea `initdb/01-roles-y-bases.sh` y el init aborta a medias (ver
  "Problemas conocidos").
- **Un `$` en una contraseña hay que escribirlo `$$`.** Compose interpreta `$`
  como inicio de variable: `Y6$tW9nC4` se convierte en `Y6` más una variable
  inexistente. Se nota por este warning al arrancar:

  ```
  warning: The "tW9nC4" variable is not set. Defaulting to a blank string.
  ```

Para comprobar cómo quedan los valores ya resueltos, sin arrancar nada:

```powershell
docker compose config
```

### 2. Levantar

```powershell
docker compose up -d --build
```

Construye la imagen de `dash` (es el único con `build:`; los otros dos bajan de
Docker Hub), crea la red y los volúmenes `pgdata` / `odoo-data`, y arranca los
tres servicios. `-d` = en segundo plano.

El orden no es casual: `odoo` y `dash` declaran
`depends_on: db → condition: service_healthy`, así que esperan a que el
healthcheck (`pg_isready`) dé verde.

La primera vez —y **solo** la primera, con `pgdata` vacío— Postgres ejecuta
`initdb/01-roles-y-bases.sh`, que crea las bases `nodered` (proceso) y `odoo`
con sus roles. Para rehacerlo hay que borrar los datos: `docker compose down -v`.

Para confirmar que el init corrió entero:

```powershell
docker compose logs db | findstr /C:"Roles y bases creados"
```

Si esa línea no aparece, el script falló: ver "Problemas conocidos".

### 3. Inicializar la base de Odoo

El script de `initdb/` crea la base `odoo` **vacía**. Odoo no la puebla solo, y
como `odoo.conf` tiene `list_db = False`, la web tampoco ofrece crearla. Sin
este paso el log repite `Database odoo not initialized`:

```powershell
docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -i base --stop-after-init
docker compose up -d
```

Tarda uno o dos minutos. Termina con `Modules loaded.`.

> **Desde Git Bash**, hay que anteponer `MSYS_NO_PATHCONV=1` a ese comando. Si
> no, Git Bash traduce `/etc/odoo/odoo.conf` a una ruta de Windows y Odoo
> responde `config file ... doesn't exist or is not readable`.

### 4. Ver qué pasó

```powershell
docker compose ps                   # estado de los tres
docker compose logs -f              # logs en vivo, Ctrl+C para salir
docker compose logs db              # solo un servicio
```

Si algo aparece en `Restarting`, el log de ese servicio dice por qué. Mirar los
logs antes de tocar nada.

### 5. Probar

| Servicio | URL |
|---|---|
| Odoo | http://localhost:8169 |
| Dash | http://localhost:8150 |
| Postgres | localhost:5433 (solo localhost) |

Odoo tarda 30–60 s en responder la primera vez. Cuando pida base, usar la que ya
existe: `odoo`.

### 6. Instalar el módulo

```powershell
docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -i aura --stop-after-init
docker compose up -d
```

`-i` instala, `-u` actualiza (ver la tabla más abajo). Instalar `aura` arrastra
sus dependencias: `aura_utils`, `metallurgy` y el tema `muk_web_theme` con sus
seis módulos `muk_web_*`. Son ~37 módulos en total y tarda un par de minutos.
Termina con `Modules loaded.`.

**Usar `run`, no `exec`.** `docker compose exec` entra al contenedor saltándose
el entrypoint de la imagen, que es quien pasa la contraseña de la base desde
`.env`. Con `exec` el comando falla así:

```
psycopg2.OperationalError: connection to server at "db" ... failed:
fe_sendauth: no password supplied
```

`run --rm` sí pasa por el entrypoint y toma la contraseña de `.env`, que sigue
siendo la única fuente de la verdad. `--no-deps` evita que arranque otra copia
de `db`.

#### Dónde vive el código y qué es `addons_path`

```
extra-addons/                 <- el bind mount (./extra-addons:/mnt/extra-addons)
└── aura_odoo_19/             <- REPO de módulos  <- addons_path apunta AQUÍ
    ├── aura/                 <- módulo (tiene __manifest__.py)
    ├── metallurgy/           <- módulo
    ├── aura_utils/           <- módulo
    └── muk_web_*/            <- módulos del tema
```

`addons_path` tiene que apuntar al directorio que **contiene módulos**, no al
que contiene el repo. Por eso `odoo.conf` dice
`addons_path = /mnt/extra-addons/aura_odoo_19,...` y no `/mnt/extra-addons`.
Si se apunta un nivel de más, Odoo avisa y sigue sin el módulo:

```
WARNING odoo.tools.config: option addons_path, invalid addons directory '/mnt/extra-addons', skipped
```

Se confirma que quedó bien mirando que la ruta aparezca en el arranque:

```powershell
docker compose logs odoo | findstr /C:"addons paths"
```

Si mañana se clona un segundo repo de módulos al lado, hay que añadirlo a
`addons_path` separado por comas.

### 7. Apagar

```powershell
docker compose stop                 # pausa, conserva todo
docker compose down                 # borra contenedores, conserva volúmenes
docker compose down -v              # BORRA los datos, incluido pgdata
```

`down -v` solo cuando se quiera volver a ejecutar el script de `initdb/`.
`down` y `down -v` actúan **solo sobre este proyecto**: no tocan `odoo-vm` ni
ningún otro contenedor de fuera. Lo que sí hay que evitar es
`docker system prune -a`, que barre todo lo que no esté en uso.

## Reinstalar desde cero

Secuencia completa, borrando datos:

```powershell
docker compose down -v
docker compose up -d --build
docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -i base --stop-after-init
docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -i aura --stop-after-init
docker compose up -d
```

Los dos `run` se pueden fusionar en uno (`-i base,aura`), pero separados se ve
mejor cuál de los dos falló.

Comprobación rápida de que quedó bien:

```powershell
docker compose ps
docker compose exec db psql -U postgres -c "\l"
docker compose exec db psql -U postgres -d odoo -c "select name, state from ir_module_module where state != 'uninstalled' and name like 'aura%' or name = 'metallurgy'"
```

Tienen que existir las bases `odoo` y `nodered`, los tres contenedores estar
`Up` (con `db` en `healthy`), y `aura` / `metallurgy` en estado `installed`.
Si algún módulo queda en `to install`, la instalación se cortó a medias.

## Problemas conocidos

Los cuatro que aparecieron en la primera instalación, con su síntoma exacto.

### `port is already allocated`

Otro contenedor o un Postgres nativo ocupa el puerto. Ver paso 0. En esta PC era
`odoo-vm`, y por eso este stack usa 5433/8169/8150.

### `role "odoo" already exists` y el init se queda a medias

Síntoma en `docker compose logs db`:

```
ERROR:  role "odoo" already exists
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

Causa: `PG_SUPERUSER=odoo` en `.env`. El entrypoint de Postgres ya crea ese rol,
y luego `01-roles-y-bases.sh` intenta crearlo otra vez; con `ON_ERROR_STOP=1` el
script aborta y **no se crean** las bases `odoo` / `nodered` ni los roles
`nodered_w` / `dash_r`. El contenedor reinicia, encuentra el volumen ya no vacío
y salta el init para siempre.

Arreglo: `PG_SUPERUSER=postgres` en `.env`, y `docker compose down -v` para que
el init vuelva a correr — no basta con reiniciar.

### La contraseña de `nodered_w` no funciona

Un `$` sin escapar en `.env`. Ver paso 1. Para verificar que una contraseña
llega entera, probar la conexión desde **fuera** del contenedor:

```powershell
docker run --rm --network aura_stack_default -e PGPASSWORD=<la contraseña> timescale/timescaledb:latest-pg16 psql -h db -U nodered_w -d nodered -c "select 1"
```

No sirve probar con `docker compose exec db psql`: por el socket local y por el
loopback de dentro del contenedor, `pg_hba.conf` está en `trust` y entra
cualquier contraseña, incluso una incorrecta. Las conexiones reales (desde otros
contenedores o desde Windows por el 5433) llegan de otra IP y sí validan con
`scram-sha-256`.

### `dash` en bucle de reinicio: `ModuleNotFoundError: No module named 'psycopg2'`

`requirements.txt` instala **psycopg v3**, pero un DSN que empieza por
`postgresql://` hace que SQLAlchemy cargue psycopg**2**, que no está. Falla al
crear el engine, antes del `try` de `app.py`.

Arreglo (ya aplicado en `docker-compose.yml`): nombrar el driver en el DSN.

```yaml
DSN_NODERED: postgresql+psycopg://dash_r:${DASH_PG_PASSWORD}@db:5432/nodered
```

### `fe_sendauth: no password supplied` al instalar el módulo

Se usó `docker compose exec` en vez de `run`. Ver paso 6.

### `invalid addons directory '/mnt/extra-addons', skipped`

`addons_path` apunta al directorio que contiene el **repo** en vez del que
contiene los **módulos**. Ver paso 6.

### `External ID not found in the system: metallurgy.metallurgy_area_molienda`

Error al instalar `metallurgy`:

```
ParseError: while parsing .../metallurgy/views/metallurgy_particle_size_views.xml:108
Error while validating view (491):
External ID not found in the system: metallurgy.metallurgy_area_molienda
```

Orden de carga en el `__manifest__.py` de `metallurgy`. Varios campos usan
`domain=lambda self: [... self.env.ref("metallurgy.metallurgy_area_molienda")]`,
y ese lambda se evalúa **al validar la vista**, no al abrirla. Si
`data/metallurgy_area_data.xml` se carga después de las vistas, el registro
todavía no existe y la instalación aborta.

Arreglo (ya aplicado): mover `data/metallurgy_area_data.xml` arriba, justo
después de `security/ir.model.access.csv` y antes de cualquier `views/`. Regla
general: los datos que las vistas referencian se cargan primero.

## Conexión desde Node-RED (Windows nativo)

Host `localhost`, puerto **`5433`**, base `nodered`, usuario `nodered_w`.

El `127.0.0.1:` del mapeo en `docker-compose.yml` es deliberado: Postgres queda
accesible desde esta máquina pero **no** desde la red de planta.

## Actualizar el módulo `aura`

El código vive en `./extra-addons` (bind mount), así que se edita desde Windows
y el contenedor lo ve al instante. Lo que hay que hacer después depende del cambio:

| Cambio | Comando |
|---|---|
| Solo Python | `docker compose restart odoo` |
| Vistas XML, campos, modelos nuevos | `docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -u aura --stop-after-init` y luego `docker compose up -d` |
| Instalar el módulo por primera vez | `docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -i aura --stop-after-init` |

Para actualizar un módulo suelto en vez de todo el bundle, cambiar `-u aura`
por `-u metallurgy`. Desde Git Bash, anteponer `MSYS_NO_PATHCONV=1`.

Durante desarrollo, para no reiniciar a cada rato, agregar a `odoo.conf`:

```ini
dev_mode = reload,xml,qweb
```

> **Nota:** el bind mount de `extra-addons` es correcto — es código, se lee y se
> edita desde Windows. La regla de "volumen nombrado, nunca bind a C:\" aplica
> solo al **datadir de Postgres**, que hace miles de escrituras chicas y sufre
> mucho sobre el filesystem de Windows.

## Actualizar la versión de Odoo (19 → 20)

Es otra cosa, mucho más delicada: cambiar el tag de la imagen **no** migra la
base. Requiere backup, script de migración y probar en una copia. No hacerlo en
caliente sobre la PC de planta.

## Backup

```powershell
docker compose exec db pg_dump -Fc -U postgres nodered -f /backup/nodered.dump
docker compose exec db pg_dump -Fc -U postgres odoo    -f /backup/odoo.dump
```

`./backup` está montado en el contenedor. Sincronizar esa carpeta fuera de la PC.

## Pendiente

- `odoo/odoo.conf` sigue con `admin_passwd = cambiar_esto_master`. Cambiarlo
  antes de que esto salga de la PC de pruebas.

## Antes de arrancar en Windows

1. `C:\Users\<usuario>\.wslconfig` con `[wsl2]` / `memory=8GB` / `processors=4`
2. Docker Desktop iniciando con Windows
3. Excluir del antivirus la carpeta de Node-RED y este directorio
4. Node-RED necesita spool local: al reiniciar Windows arranca antes que los
   contenedores, y sin spool se pierden los primeros minutos de datos
5. **No dejar este stack dentro de OneDrive.** El bind de `extra-addons` se
   sincroniza a la nube mientras Odoo lee esos archivos: lentitud y bloqueos de
   archivo. Moverlo a algo como `C:\aura_stack`. Los datos de Postgres sí están
   a salvo: viven en el volumen nombrado `pgdata`, fuera del filesystem de Windows.


Como hacer -u

docker compose run --rm --no-deps odoo odoo -c /etc/odoo/odoo.conf -d odoo -u metallurgy --stop-after-init
docker compose up -d
#   a u r a _ s t a c k _ p l a n t a  
 