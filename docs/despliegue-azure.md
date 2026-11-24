# Desplegar el backend en Azure

Esta guía deja las dos APIs en internet con HTTPS. Los frontends de GitHub
Pages las usan:

```
https://<dominio>/tienda/api/v1   ← frontend-e-commerce-RDA2 (CE_API_URL)
https://<dominio>/admin/api/v1    ← frontend-RDA2           (ADMIN_API_URL)
```

## Lo que ya está hecho y lo que te toca

**Ya está listo en este repositorio** y probado con un ensayo completo del
despliegue (Oracle, Redis, las dos APIs y Caddy con HTTPS):

- los `Dockerfile` de las dos APIs;
- `despliegue/docker-compose.yml`, `Caddyfile`, `.env.example` y `primera-vez.sh`;
- el instalador de la base, el mismo que prueba el CI.

**Tu parte** (unos 30–40 minutos, la mayoría esperando a Azure y a Oracle):

1. [ ] Instalar la CLI de Azure y activar Azure for Students (§2).
2. [ ] Crear la VM y abrir los puertos 80/443, con los comandos tal cual del §3. Anotar el dominio.
3. [ ] Entrar por SSH e instalar Docker (§4).
4. [ ] Clonar el repositorio, completar `despliegue/.env` y correr `./primera-vez.sh` (§5).
5. [ ] Comprobar las dos URLs con `curl` (§5).
6. [ ] Poner las variables `CE_API_URL` y `ADMIN_API_URL` en los repositorios de los fronts y volver a publicarlos (§6).
7. [ ] Entrar a https://macalderonr07.github.io/frontend-RDA2/ con tu `ADMIN_CORREO` y `ADMIN_CLAVE`.

Si algo falla, copia el mensaje del error (sin claves) y lo vemos; la tabla
del §9 tiene los problemas más probables.

## 1. La decisión: una sola máquina virtual

Lo difícil de este backend es **Oracle**. Las APIs son Node y corren casi en
cualquier lado; la base, no. Estas son las opciones que se evaluaron:

| Opción | Por qué sí / por qué no |
|---|---|
| **VM de Azure con Docker: Oracle 23 Free + Redis + APIs + Caddy** ✅ | Es la misma imagen `gvenzl/oracle-free` que usamos en desarrollo y en el CI, así que no hay sorpresas. Un solo servidor, un solo costo y nada de Oracle expuesto a internet. Los límites de Oracle Free (2 CPU, 2 GB de memoria y 12 GB de datos) sobran para el proyecto |
| Oracle Database@Azure | Oracle Exadata administrado dentro de Azure. Pensado para empresas: el costo mínimo está muy por encima del presupuesto de un proyecto universitario |
| Autonomous Database (Oracle Cloud, *Always Free*) + APIs en Azure | Es gratis, pero son dos nubes: hay latencia entre ellas, la conexión usa *wallet* (mTLS) y las migraciones habría que adaptarlas, porque ahí no hay SYSDBA |
| APIs en App Service o Container Apps, y Oracle en una VM | Sigue haciendo falta la VM para Oracle, y además hay que armar una red privada entre los servicios. Son más piezas para el mismo resultado |
| Azure Cache for Redis | Redis administrado, con costo aparte. Aquí Redis es solo caché (si se pierde, la API la reconstruye desde Oracle), así que un contenedor alcanza |

Así queda el servidor:

```
Internet ──443──▶ Caddy (HTTPS automático, Let's Encrypt)
                    ├── /tienda/* ──▶ api-tienda:5050 ──┬──▶ Oracle 23 Free (volumen persistente)
                    └── /admin/*  ──▶ api-admin:5070  ──┘     └──▶ Redis (caché, sin disco)
```

Solo los puertos 80 y 443, que usa Caddy, y el 22 (SSH) quedan abiertos.
Oracle, Redis y las APIs viven en la red interna de Docker.

## 2. Antes de empezar

- Una suscripción de Azure. Con correo de la universidad sirve **Azure for
  Students**, que trae crédito y no pide tarjeta.
- La CLI de Azure (`az`) en tu equipo:
  <https://learn.microsoft.com/cli/azure/install-azure-cli>.
- **Regiones de Azure for Students:** la suscripción tiene una política que
  solo permite algunas regiones. En otra región, `az vm create` falla con
  `RequestDisallowedByAzure`. Para ver cuáles tienes:

  ```bash
  az policy assignment list --query "[].parameters.listOfAllowedLocations.value" -o tsv
  ```

  En noviembre de 2026 eran `westus`, `northcentralus`, `canadacentral`,
  `brazilsouth` y `chilecentral`. Desde Ecuador conviene **`chilecentral`**, por
  ser la más cercana.
- Tamaño de la VM: **Standard_B2as_v2** (2 vCPU AMD, 8 GiB), de la serie B
  nueva. En Chile Central no hay B2ms ni B2s; para ver qué tamaños tiene una
  región:

  ```bash
  az vm list-skus -l chilecentral --resource-type virtualMachines --query "[?starts_with(name,'Standard_B2')].name" -o tsv
  ```

  El precio depende de la región: revisa la
  [calculadora](https://azure.microsoft.com/pricing/calculator/).

## 3. Crear la máquina virtual

En tu equipo, reemplazando `<etiqueta>` por un nombre único (será parte del dominio):

```bash
az login
az group create --name rg-comercial-elite --location chilecentral

az vm create \
  --resource-group rg-comercial-elite \
  --name vm-elite \
  --location chilecentral \
  --image Ubuntu2404 \
  --size Standard_B2as_v2 \
  --os-disk-size-gb 64 \
  --admin-username elite \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --public-ip-address-dns-name <etiqueta>

# HTTP (lo usa Let's Encrypt para validar) y HTTPS
az vm open-port -g rg-comercial-elite -n vm-elite --port 80  --priority 900
az vm open-port -g rg-comercial-elite -n vm-elite --port 443 --priority 910
```

El dominio queda como **`<etiqueta>.chilecentral.cloudapp.azure.com`**. Lo puedes
ver con:

```bash
az vm show -d -g rg-comercial-elite -n vm-elite --query fqdns -o tsv
```

Para que nadie más pruebe claves contra tu SSH, recomendado: deja el 22 abierto solo para tu IP.

```bash
az network nsg rule update -g rg-comercial-elite --nsg-name vm-eliteNSG \
  --name default-allow-ssh --source-address-prefixes "$(curl -s https://ifconfig.me)/32"
```

## 4. Preparar el servidor

```bash
ssh elite@<etiqueta>.chilecentral.cloudapp.azure.com

sudo apt update && sudo apt install -y docker.io docker-compose-v2 git
sudo usermod -aG docker "$USER" && exit      # salir y volver a entrar para usar docker sin sudo
```

## 5. Configurar y levantar

```bash
ssh elite@<etiqueta>.chilecentral.cloudapp.azure.com
git clone https://github.com/macalderonr07/Backend-RDA2.git
cd Backend-RDA2/despliegue
cp .env.example .env && chmod 600 .env
nano .env
```

Completa `.env`. Genera cada clave con el comando que indica el archivo:

| Variable | Valor |
|---|---|
| `DOMINIO` | `<etiqueta>.chilecentral.cloudapp.azure.com` |
| `CLIENT_ORIGIN` | `https://macalderonr07.github.io`, el origen de los dos frontends en Pages |
| `ORACLE_SYS_PASSWORD`, `CLAVE_*` | `echo "C$(openssl rand -hex 12)"` (una distinta para cada una) |
| `JWT_SECRETO` | `openssl rand -hex 32` |
| `ADMIN_CORREO`, `ADMIN_CLAVE` | La cuenta con la que vas a entrar a la administración |

Después:

```bash
./primera-vez.sh
```

El script hace cuatro cosas:

1. Levanta Oracle. La primera vez crea la base en el volumen, y eso tarda unos
   minutos.
2. Instala el esquema, la lógica y las 18 migraciones. Usa el mismo
   `instalar.sh` que prueba el CI.
3. Construye y levanta las APIs y Caddy.
4. Crea el administrador.

Al final muestra las URLs. Para comprobarlas:

```bash
curl -s https://<dominio>/tienda/api/v1/productos | head -c 200     # catálogo en JSON
curl -s -o /dev/null -w '%{http_code}\n' https://<dominio>/admin/api/v1/meta   # 401 sin token: correcto
```

## 6. Conectar los frontends

Desde tu equipo, con la CLI de GitHub:

```bash
gh variable set CE_API_URL    -R macalderonr07/frontend-e-commerce-RDA2 --body "https://<dominio>/tienda/api/v1"
gh variable set ADMIN_API_URL -R macalderonr07/frontend-RDA2           --body "https://<dominio>/admin/api/v1"

# volver a publicar los dos sitios para que tomen la variable
gh workflow run verificar-y-publicar.yml -R macalderonr07/frontend-e-commerce-RDA2
gh workflow run verificar-y-publicar.yml -R macalderonr07/frontend-RDA2
```

Para quitar la API, se borra la variable y se vuelve a publicar. La tienda usa
entonces `data/catalogo.json`.

## 7. Operación diaria

| Tarea | Comando (en `~/Backend-RDA2/despliegue`) |
|---|---|
| Ver logs | `docker compose logs -f api-tienda api-administracion` |
| Estado | `docker compose ps` |
| Actualizar a la última versión | `git pull && ./primera-vez.sh` (aplica solo las migraciones nuevas y reconstruye las APIs) |
| Reiniciar una API | `docker compose restart api-tienda` |
| Entrar a la base | `docker compose exec oracle sqlplus / as sysdba` y luego `ALTER SESSION SET CONTAINER = FREEPDB1;` |

**Respaldo.** Los datos viven en el volumen `comercial-elite_oracle-datos`.
La forma más simple es una instantánea del disco de la VM, que se puede
restaurar entera:

```bash
az snapshot create -g rg-comercial-elite -n elite-$(date +%F) \
  --source "$(az vm show -g rg-comercial-elite -n vm-elite --query storageProfile.osDisk.managedDisk.id -o tsv)"
```

**Cuidar el crédito.** Una VM apagada desde Azure (*deallocate*) no cobra
cómputo, solo el disco. La IP y el dominio se mantienen (la IP Standard es estática):

```bash
az vm deallocate -g rg-comercial-elite -n vm-elite   # apagar
az vm start      -g rg-comercial-elite -n vm-elite   # encender (Docker levanta todo solo: restart: unless-stopped)
```

Al terminar el semestre, `az group delete -n rg-comercial-elite` borra todo.

## 8. Seguridad (lo que ya queda resuelto)

- **Abierto a internet:** solo 80 y 443 (Caddy) y 22 (SSH con llave). Oracle y
  Redis no publican puertos.
- **Tráfico cifrado:** HTTPS con certificado de Let's Encrypt, que Caddy renueva
  solo, más HSTS, `nosniff` y sin cabecera `Server`.
- **Claves:** solo en `despliegue/.env` (permisos 600; git lo ignora). Ningún
  script las imprime.
- **Base de datos:** las APIs entran con usuarios de mínimo privilegio. La
  tienda usa `app_web` (rol `ELITE_ECOMMERCE`) y la administración `app_admin`
  (rol `ELITE_PRODUCCION`). Nunca usan los dueños de los esquemas.
- **CORS:** solo para los orígenes de `CLIENT_ORIGIN`.
- **IP real del cliente:** `TRUST_PROXY=uniquelocal` hace que la bitácora de
  accesos y el límite de intentos de clave vean la IP real del cliente, no la de
  Caddy. Un cliente no puede falsificarla mandando su propio `X-Forwarded-For`:
  Caddy lo reemplaza. Se probó en el ensayo.
- **Sistema operativo:** Ubuntu instala solo los parches de seguridad
  (*unattended-upgrades* viene activo).

## 9. Si algo falla

| Síntoma | Causa probable |
|---|---|
| Caddy no obtiene el certificado | Los puertos 80/443 no están abiertos (paso 3), o `DOMINIO` no coincide con el FQDN de la VM |
| `az vm create` falla con `RequestDisallowedByAzure` | La región no está permitida en tu suscripción (Azure for Students). Mira el §2 y usa una de las permitidas |
| `primera-vez.sh` se queda esperando a Oracle | La primera creación tarda. Revisa `docker compose logs oracle` |
| `permission denied` con `docker` justo después de instalarlo | El grupo `docker` se aplica al volver a entrar por SSH. También puedes usar `sg docker -c "./primera-vez.sh"` |
| La API responde 502 | La API no arrancó: `docker compose logs api-tienda` (suele ser una clave mal copiada en `.env`) |
| El frontend dice "Failed to fetch" | Falta el origen en `CLIENT_ORIGIN` (y después `docker compose up -d`), o la variable `*_API_URL` no tiene `https://` |
