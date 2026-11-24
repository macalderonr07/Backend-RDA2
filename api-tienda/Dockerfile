# Imagen de producción de la API (api-tienda). Node 22 LTS, solo dependencias de
# producción y usuario sin privilegios. El driver oracledb va en modo "thin":
# no necesita Oracle Instant Client.
FROM node:22-slim

ENV NODE_ENV=production
WORKDIR /app

# Primero el lockfile: la capa de dependencias se reutiliza si el código cambia
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY --chown=node:node src ./src


USER node
EXPOSE 5050
# Salud: la API responde (401/404 sin token también cuentan como "viva")
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 5050) + '/api/v1').then(() => process.exit(0), () => process.exit(1))"
CMD ["node", "src/server.js"]
