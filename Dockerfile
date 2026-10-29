# ---------- stage 1 "deps" : installe UNIQUEMENT les dépendances de prod ----------
# Version épinglée (pas de :latest) -> build reproductible, vérifié par hadolint DL3007 / trivy DS-0001
FROM node:24.22.1-trixie-slim AS deps
WORKDIR /app
# On copie d'abord les seuls fichiers de dépendances -> le cache Docker évite de refaire npm ci
COPY package.json package-lock.json ./
# --omit=dev : pas de mocha/cypress en prod ; --ignore-scripts : aucun script postinstall exécuté
RUN npm ci --omit=dev --ignore-scripts

# ---------- stage 2 : image d'exécution ----------
FROM node:24.22.1-trixie-slim
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
# Liste explicite (et non COPY . .) : ni .git, ni .gitlab-ci.yml, ni tests dans l'image
COPY package.json index.js index.html ./
# "node" = utilisateur créé par l'image officielle, UID/GID 1000.
# Forme numérique = vérifiable par Kubernetes (runAsNonRoot)
USER 1000:1000
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:5000/hello').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "index.js"]
