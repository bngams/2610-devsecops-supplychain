# Partie 1 : Image Docker, scans et SBOM (étapes 6 à 9)

> **Scénario à réaliser en autonomie.** Vous partez du pipeline obtenu à la fin de l'étape 5 du TP
> (jobs `build-app`, `unit-test-job`, `npm-audit`, `osv-scanner`, `sonarcloud-check`). Vous allez
> le prolonger job par job en complétant les blocs `# TODO`. La correction se trouve dans
> [`solution/.gitlab-ci.yml`](solution/.gitlab-ci.yml) : en dernier recours 😉.
>
> ⚠️ **Ne commitez jamais un bloc dont des `# TODO` sont encore vides.** Une clé YAML laissée
> sans valeur (`rules:`, `needs:`, `reports:`…) ou un élément de liste réduit à `- # TODO` vaut
> `null`, et GitLab refuse alors tout le pipeline (*This GitLab CI configuration is invalid*).
> Remplissez chaque bloc entièrement, puis commitez.

## ✨ Objectifs

- Conteneuriser l'application et **analyser le Dockerfile** avec trois outils (Hadolint, Trivy, KICS), puis comparer leurs résultats.
- **Construire et publier** l'image dans le registry GitLab, en la désignant par son **digest**.
- Comprendre la différence entre **scan de dépendances**, **scan d'image** et **SBOM**, en les exécutant tous sur la même application.
- Générer un **SBOM CycloneDX** avec Syft, le publier comme artefact et le **valider avec Grype**, qui jouera le rôle de « porte » du pipeline.
- Re-scanner chaque nuit un SBOM déjà produit, **sans rien reconstruire**.

## 📁 Point de départ

Votre projet contient aujourd'hui `operations.js`, `test.js`, `package.json`, `package-lock.json`,
`.gitignore`, `sonar-project.properties` et `.gitlab-ci.yml`. À la fin de cette partie, il
ressemblera à ceci :

```
pipeline-XX-CICD-<initiales>/
├── .gitlab-ci.yml        # + jobs Dockerfile, build, SBOM, scans d'image
├── .dockerignore         # nouveau (étape 7.6)
├── Dockerfile            # nouveau (étape 6), durci à l'étape 7.6
├── index.js  index.html  # nouveaux (étape 6) : l'app web
├── package.json          # remplacé (étape 6)
├── package-lock.json     # remplacé (étape 6), corrigé (étape 9.6)
├── operations.js  test.js  sonar-project.properties  .gitignore   # inchangés
```

---

## 🐳 Étape 6 : Préparer le déploiement

Jusqu'ici, notre projet n'était qu'une bibliothèque de calcul (`operations.js`) et ses tests.
Pour parler de déploiement, il nous faut une vraie application à exposer : un petit serveur web
Express. Nous allons ensuite l'emballer dans une image Docker.

### 6.1 Ajouter l'application web

Tous les fichiers de cette étape sont fournis dans [`assets/etape6/`](assets/etape6/). Ouvrez-les
avant de les copier, pour savoir ce que vous ajoutez :

| Fichier | Contenu | Action |
|---|---|---|
| [`index.js`](assets/etape6/index.js) | Un serveur **Express** avec deux routes : `GET /welcome` renvoie la page `index.html` et `GET /hello` renvoie `<p>Hello World!!!</p>`. Le port vient de la variable d'environnement `PORT`, avec `5000` par défaut. | **créer** à la racine |
| [`index.html`](assets/etape6/index.html) | Une page HTML minimale avec un bouton « Voir le texte » qui affiche ou masque un paragraphe. | **créer** à la racine |
| [`package.json`](assets/etape6/package.json) | Ajoute les dépendances de **production** `express` et `dotenv`, passe `mocha` en version 10, ajoute `cypress` en dépendance de **dev**, et les scripts `start`, `e2e`, `lint`. Seuls `test` et `start` serviront ici (`eslint` n'est d'ailleurs pas installé). | **remplacer** le vôtre |
| [`package-lock.json`](assets/etape6/package-lock.json) | Les versions exactes installées. Il fige volontairement `express` en **4.18.3**, une version ancienne et vulnérable, pour que les scanners aient quelque chose à trouver. | **remplacer** le vôtre |
| [`Dockerfile`](assets/etape6/Dockerfile) | La recette de l'image, **dans sa version naïve** : `FROM node:latest`, `COPY . .`, `npm install --production`, `CMD ["node", "index.js"]`. Nous la durcirons à l'étape 7. | **créer** à la racine |

🚧 **À vous de jouer :** dans le Web IDE (ou en local), créez `index.js`, `index.html` et
`Dockerfile` à la racine de votre projet en copiant le contenu des fichiers fournis. Remplacez
ensuite le contenu de vos `package.json` et `package-lock.json` par celui des fichiers fournis.
**Ne touchez pas** à `operations.js` ni à `test.js` : les tests mocha continuent de fonctionner
avec mocha 10.

### 6.2 Éviter le téléchargement de Cypress dans le pipeline

Le nouveau `package.json` déclare `cypress` en dépendance de dev. À l'installation, Cypress
télécharge en plus un binaire d'environ **500 Mo**, et votre job `build-app` (`npm ci`) le ferait
à chaque pipeline. Nous ne lançons pas de tests end-to-end ici, donc on désactive ce
téléchargement avec la variable que Cypress prévoit pour cela.

🚧 **À compléter**, dans le bloc `variables:` global de votre `.gitlab-ci.yml` :

```yaml
variables:
  # ... vos variables existantes (EXEC_ONLY, SONAR_USER_HOME, GIT_DEPTH)
  # TODO : variable d'environnement qui empêche Cypress de télécharger son binaire, valeur "0"
```

> 📖 [Cypress : variable `CYPRESS_INSTALL_BINARY`](https://docs.cypress.io/app/references/advanced-installation#Skipping-installation)

Commitez et poussez. Le pipeline existant doit rester vert : `build-app` et `unit-test-job`
passent, et les jobs SAST se comportent comme avant.

### 6.3 💡 Tester en local (facultatif, si Docker est installé)

Avant de l'analyser, vérifiez que l'image se construit et que l'app répond. Le conteneur écoute
sur le port 5000, qu'on publie sur le port **8080** de votre machine : sur macOS, le port 5000 est
souvent déjà pris par le récepteur AirPlay.

```bash
docker build -t demo-app:initial .
docker run -d --rm --name demo -p 127.0.0.1:8080:5000 demo-app:initial
curl 127.0.0.1:8080/hello          # -> <p>Hello World!!!</p>
docker exec demo id                # -> uid=0(root) gid=0(root) groups=0(root)
docker exec demo ls /app           # -> ... test.js, sonar-project.properties, .gitlab-ci.yml (!)
docker images demo-app             # -> demo-app  initial  ...  1.8GB
docker rm -f demo
```

### 6.4 🧪 Manip : Votre analyse avant les scanners

L'app fonctionne. Avant d'automatiser l'analyse, relisez le `Dockerfile` (5 lignes utiles) et la
sortie ci-dessus, puis **notez au moins trois défauts** de sécurité ou de robustesse. À l'étape
suivante, vous comparerez votre liste avec celle des outils : certains défauts seront trouvés par
tous les outils, d'autres par aucun.

---

## 🔍 Étape 7 : Analyser le Dockerfile

### 7.1 Une troisième famille d'analyse statique

Votre pipeline fait déjà deux familles d'analyse statique. Le Dockerfile en demande une troisième,
car c'est une **configuration d'infrastructure** : il ne contient ni code applicatif ni
dépendance, mais il décide avec quel utilisateur l'application tourne, ce qui est copié dans
l'image et sur quelle base on construit.

| Famille | Ce qu'on analyse | Question posée | Outils de votre pipeline |
|---|---|---|---|
| **SAST** (code) | votre code source | « Mon code contient-il une faille (injection, XSS…) ? » | Sonar |
| **SCA** (dépendances) | `package-lock.json` | « Une de mes librairies a-t-elle une CVE connue ? » | npm audit, OSV-Scanner |
| **Misconfiguration / IaC** | `Dockerfile`, manifests K8s, Terraform… | « Ma configuration respecte-t-elle les bonnes pratiques ? » | **Hadolint, Trivy, KICS** (cette étape) |

### 7.2 Trois outils, trois philosophies

Les trois outils lisent le même fichier, mais ils ne cherchent pas la même chose. C'est ce qui
rend la comparaison intéressante.

| Outil | Nature | Points forts | Limites |
|---|---|---|---|
| [**Hadolint**](https://github.com/hadolint/hadolint) | **Linter** spécialisé Dockerfile | Règles `DLxxxx` de bonnes pratiques Docker ; analyse aussi les commandes `RUN` avec ShellCheck ; très rapide ; sortie au format **GitLab Code Quality** | Ne fait que du Dockerfile ; vérifie le *style* plus que la *sécurité* |
| [**Trivy**](https://trivy.dev/latest/docs/scanner/misconfiguration/) (`trivy config`) | Scanner **tout-en-un** (config, image, SBOM, secrets…) | Un seul outil réutilisé à l'étape 9 pour l'image ; règles `DS-xxxx` | Couverture Dockerfile plus réduite qu'un outil dédié |
| [**KICS**](https://docs.kics.io/latest/) (Checkmarx) | Scanner **IaC** multi-plateformes | 2 000+ requêtes : Dockerfile, Kubernetes, Terraform, Ansible, CloudFormation… ; sortie au format **GitLab SAST** ; codes de sortie par sévérité | Plus lourd ; davantage de résultats à trier sur un gros dépôt |

### 7.3 Préparer un modèle de job commun

Votre pipeline choisit déjà ses scanners SAST avec la variable `EXEC_ONLY` et le modèle `.sast`.
On réutilise le même mécanisme. On ajoute trois valeurs (une par outil) et une valeur
`dockerfile` qui lance les trois d'un coup.

On change aussi la **valeur par défaut** de `EXEC_ONLY`, de `"sonar-scanner"` à `"dockerfile"`.
Ainsi, les scans du Dockerfile tournent à chaque push, ce qui sera indispensable quand KICS
deviendra une porte bloquante (étape 7.7). Faites les deux modifications **avant de commiter** :
GitLab refuse une valeur par défaut qui ne figure pas dans `options`.

🚧 **À compléter**, dans le bloc `variables:` global existant (ne créez pas un second bloc
`variables:` : la seconde clé remplacerait silencieusement la première), puis sous le modèle
`.sast` :

```yaml
variables:
  EXEC_ONLY:
    value: "dockerfile"
    # TODO : ajoutez "hadolint", "trivy-config", "kics" et "dockerfile" à la liste existante
    options: ["osv-scanner", "npm-audit", "sonar-scanner", "all", "none"]
    description: "Scanner SAST à exécuter"

# Modèle pour les 3 scanners de Dockerfile : même comportement que .sast...
.dockerfile-scan:
  extends: .sast
  # ...sauf la règle, qui accepte aussi la valeur "dockerfile"
  rules:
    # TODO : le job tourne si EXEC_ONLY vaut son SCANNER, OU "dockerfile", OU "all"
    #        (inspirez-vous de la règle du modèle .sast)
```

> 📖 [`rules:if` et comparaison de variables](https://docs.gitlab.com/ci/jobs/job_rules/#compare-a-variable-to-another-variable)

### 7.4 Les trois jobs

Avant d'écrire les jobs, un point technique qui reviendra tout au long du lab. Pour exécuter votre
`script:`, le runner GitLab démarre le conteneur du job **avec un shell** (`sh`). Deux situations
posent problème :

| Situation | Exemple | Solution |
|---|---|---|
| L'image définit un `ENTRYPOINT` (le conteneur lance l'outil au démarrage) | `aquasec/trivy` démarre `trivy`, `checkmarx/kics` démarre `kics` | Neutraliser l'entrypoint : `image: { name: ..., entrypoint: [""] }`. Vous l'avez déjà fait pour Sonar. |
| L'image n'a **pas de shell** du tout | `hadolint/hadolint:v2.15.1` (image vide + un binaire) | Prendre la **variante** prévue avec un shell : `-alpine` ou `-debian` pour Hadolint, `-debug` pour Syft et Grype |

**7.4.a Hadolint.** Ce premier job est donné en entier : lisez-le pour comprendre le
modèle, puis recopiez-le.

```yaml
hadolint:
  extends: .dockerfile-scan
  image: hadolint/hadolint:v2.15.1-alpine     # variante AVEC shell
  variables:
    SCANNER: "hadolint"
  script:
    # 1) rapport au format Code Quality, affiché dans les merge requests ("|| true" : ne bloque pas ici)
    - hadolint --format gitlab_codeclimate Dockerfile > hadolint-codequality.json || true
    # 2) sortie lisible dans le log + code retour (échec à partir de la sévérité "warning")
    - hadolint --failure-threshold warning Dockerfile
  artifacts:
    paths: [hadolint-codequality.json]
    reports:
      codequality: hadolint-codequality.json
```

> 📖 [Hadolint : options et formats](https://github.com/hadolint/hadolint#cli) · [GitLab : rapport `codequality`](https://docs.gitlab.com/ci/testing/code_quality/#import-code-quality-results-from-a-cicd-job)

**7.4.b Trivy.** Même modèle. Cette fois, c'est à vous de remplir les commandes.

🚧 **À compléter :**

```yaml
trivy-config:
  extends: .dockerfile-scan
  image:
    name: aquasec/trivy:0.75.0
    # TODO : neutraliser l'entrypoint de l'image
  variables:
    SCANNER: "trivy-config"
  script:
    # TODO 1 : "trivy config" sur le Dockerfile, sortie en table dans le fichier trivy-config.txt
    #          (options --format et --output)
    # TODO 2 : relancer "trivy config" pour qu'il ÉCHOUE (code 1) s'il trouve du HIGH ou du CRITICAL
    #          (options --exit-code et --severity)
  artifacts:
    paths: [trivy-config.txt]
```

> 📖 [Trivy : `trivy config`](https://trivy.dev/latest/docs/references/configuration/cli/trivy_config/) · [Trivy : scan de misconfiguration](https://trivy.dev/latest/docs/scanner/misconfiguration/)

**7.4.c KICS.** Vous avez maintenant le modèle en main : écrivez ce job **seul**, à partir de la
documentation. Voici le cahier des charges :

- l'image `checkmarx/kics:v2.2.0`, avec son entrypoint neutralisé ;
- la commande `kics scan`, qui analyse le fichier `Dockerfile` (option `-p`) et écrit ses rapports dans `kics-report/` (option `-o`) ;
- trois formats de rapport : `html`, `json` et `glsast`, le format SAST de GitLab, qui produit `kics-report/gl-sast-results.json` ;
- pas de barre de progression dans les logs (`--no-progress`) ;
- en artefacts, le dossier `kics-report/` ainsi que le rapport `sast`.

> 📖 [KICS : `scan` et ses options](https://docs.kics.io/latest/commands/) · [KICS : formats de résultats](https://docs.kics.io/latest/results/) · [GitLab : rapport `sast`](https://docs.gitlab.com/ci/yaml/artifacts_reports/#artifactsreportssast)

> 💡 **Tester :** poussez vos modifications (ou lancez *Build > Pipelines > Run pipeline* avec
> `EXEC_ONLY = dockerfile`). Les trois jobs passent en **orange** (échec toléré grâce à
> `allow_failure: true`, hérité de `.sast`). Ouvrez leurs logs. Pour Trivy, le log ne montre que
> le résultat filtré de la seconde commande (`HIGH,CRITICAL` : uniquement `DS-0002`). Le rapport
> complet est dans l'artefact `trivy-config.txt` (bouton **Browse** dans la colonne de droite du
> job), qui doit contenir :
>
> ```
> Tests: 27 (SUCCESSES: 24, FAILURES: 3)
> Failures: 3 (UNKNOWN: 0, LOW: 1, MEDIUM: 1, HIGH: 1, CRITICAL: 0)
> DS-0001 (MEDIUM): Specify a tag in the 'FROM' statement for image 'node'
> DS-0002 (HIGH): Specify at least 1 USER command in Dockerfile with non-root user as argument
> DS-0026 (LOW): Add HEALTHCHECK instruction in your Dockerfile
> ```

### 7.5 📊 Comparer les trois outils

🚧 **À vous de jouer :** remplissez ce tableau à partir de vos logs, puis comparez-le avec votre
liste de l'étape 6.4.

| Défaut | Hadolint | Trivy | KICS | Vous (6.4) |
|---|---|---|---|---|
| Image de base en `:latest` | | | | |
| Pas de `USER` (exécution en root) | | | | |
| Pas de `HEALTHCHECK` | | | | |
| `COPY . .` copie `.git`, la CI et les tests dans l'image | | | | |
| Image de 1,8 Go (pas de multi-stage) | | | | |

<details>
<summary>Ce que nous avons obtenu (à n'ouvrir qu'après avoir rempli le vôtre)</summary>

| Défaut | Hadolint | Trivy | KICS |
|---|---|---|---|
| `:latest` | ✅ `DL3007` (warning) | ✅ `DS-0001` (MEDIUM) | ✅ *Image Version Using 'latest'* (MEDIUM) |
| Root | ❌ | ✅ `DS-0002` (HIGH) | ✅ *Missing User Instruction* (HIGH) |
| Pas de `HEALTHCHECK` | ❌ | ✅ `DS-0026` (LOW) | ✅ *Healthcheck Instruction Missing* (LOW) |
| `COPY . .` | ❌ | ❌ | ❌ |
| Taille / multi-stage | ❌ | ❌ | ❌ |

**Ce qu'il faut en retenir :**

- **Hadolint est un linter, pas un scanner de sécurité.** Il ne signale le root que si un `USER root` est *écrit* (règle `DL3002`), pas s'il manque un `USER`. Il excelle en revanche sur le contenu des `RUN` (`apt-get` sans `--no-install-recommends`, `cd` au lieu de `WORKDIR`…), que notre Dockerfile n'utilise presque pas.
- **Trivy et KICS sont d'accord** sur ce petit fichier. KICS prend l'avantage dès que le dépôt contient aussi du Kubernetes, du Terraform ou de l'Ansible.
- **Aucun outil ne voit `COPY . .`** : le risque (embarquer `.git`, des secrets ou la CI) dépend du *contenu du dossier*, que ces outils ne regardent pas. Ce défaut se corrige par la relecture humaine et par un `.dockerignore`.
- ⚖️ **En pratique**, on garde souvent deux outils : Hadolint pour le retour rapide sur le style dans les merge requests, plus Trivy *ou* KICS pour la sécurité. Trois, c'est redondant. On les garde ici pour la comparaison.

</details>

### 7.6 Durcir le Dockerfile

Les outils vous ont donné une liste de corrections. Voici comment chacune se traduit dans le
Dockerfile, et quel problème elle règle :

| Changement | Pourquoi | Règle satisfaite |
|---|---|---|
| `FROM node:24.22.1-trixie-slim` au lieu de `node:latest` | Build reproductible : `latest` change sans prévenir (aujourd'hui Node 26, demain autre chose). La variante `-slim` est aussi beaucoup plus petite. | DL3007, DS-0001 |
| **Multi-stage** : un stage `deps` installe, le stage final copie seulement `node_modules` | L'image finale ne contient ni cache npm ni fichiers intermédiaires d'installation | (propreté) |
| `npm ci --omit=dev --ignore-scripts` | `ci` respecte exactement le lockfile ; `--omit=dev` exclut mocha et cypress ; `--ignore-scripts` empêche les scripts `postinstall` de s'exécuter (on y revient à l'étape 13) | |
| `COPY package.json index.js index.html ./` au lieu de `COPY . .` | On ne copie que ce qui sert à l'exécution | (aucun outil) |
| `USER 1000:1000` | L'image `node` fournit déjà l'utilisateur `node` (UID 1000). La forme numérique permet à Kubernetes de vérifier `runAsNonRoot`. | DS-0002, KICS *Missing User* |
| `HEALTHCHECK` | Docker (ou l'orchestrateur) sait si l'app répond vraiment | DS-0026 |
| Un fichier `.dockerignore` | Seconde barrière : même un `COPY . .` ajouté plus tard n'enverra ni `.git` ni `node_modules` au build | |

Le **multi-stage build** est la seule notion nouvelle de ce squelette. Un Dockerfile peut contenir
plusieurs `FROM` : chacun démarre une étape (*stage*) indépendante, qu'on peut nommer avec
`AS <nom>`. Seule la **dernière** étape devient l'image livrée. Les précédentes servent d'atelier :
on y installe ce qu'il faut, puis l'étape finale ne récupère que le résultat, avec
`COPY --from=<nom> <chemin source> <chemin cible>`.

> ⚖️ Sur les 1,8 Go de départ, l'essentiel du gain vient du passage à l'image `-slim` (l'image
> `node` complète embarque compilateurs et outils de build). Le multi-stage apporte surtout de la
> **propreté** : rien de ce qui a servi à l'installation ne part en production.

🚧 **À compléter** : remplacez votre `Dockerfile` par ce squelette et remplissez les `# TODO`.

```dockerfile
# ---------- stage 1 "deps" : installe UNIQUEMENT les dépendances de prod ----------
FROM node:24.22.1-trixie-slim AS deps
WORKDIR /app
# TODO : copier uniquement package.json et package-lock.json
# TODO : RUN npm ci (sans les devDependencies, sans exécuter les scripts)

# ---------- stage 2 : image d'exécution ----------
FROM node:24.22.1-trixie-slim
ENV NODE_ENV=production
WORKDIR /app
# TODO : copier /app/node_modules depuis le stage "deps"  (COPY --from=...)
# TODO : copier package.json, index.js et index.html (et rien d'autre)
# TODO : passer en utilisateur non-root, sous forme numérique (UID:GID de l'utilisateur "node")
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:5000/hello').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "index.js"]
```

Le `HEALTHCHECK` vous est donné tel quel. L'image `-slim` ne contient pas `curl`, et on ne
l'installe pas exprès : c'est un outil de plus pour un attaquant. On utilise donc `fetch`, qui est
intégré à Node 18+.

🚧 **À compléter** : créez ensuite un fichier `.dockerignore` à la racine du projet. Il doit
exclure au minimum `.git`, `.gitlab-ci.yml`, `node_modules`, `.npm`, `.sonar`, `test.js`,
`sonar-project.properties`, les fichiers `*.md` et les `Dockerfile*`.

> 📖 [Docker : multi-stage builds](https://docs.docker.com/build/building/multi-stage/) · [`.dockerignore`](https://docs.docker.com/build/concepts/context/#dockerignore-files) · [`npm ci`](https://docs.npmjs.com/cli/commands/npm-ci) · [`HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck)

> 💡 **Tester :** relancez le pipeline avec `EXEC_ONLY = dockerfile`. Les trois jobs passent au
> **vert**. En local (facultatif), on obtient ceci :
>
> ```bash
> docker build -t demo-app:hardened .
> docker run -d --rm --name demo -p 127.0.0.1:8080:5000 demo-app:hardened
> sleep 35; docker ps --filter name=demo --format '{{.Status}}'   # -> Up 35 seconds (healthy)
> docker exec demo id                  # -> uid=1000(node) gid=1000(node) groups=1000(node)
> docker exec demo ls /app             # -> index.html  index.js  node_modules  package.json
> docker images demo-app               # -> hardened 359MB   (contre 1.8GB)
> docker rm -f demo
> ```

### 7.7 Transformer un scanner en « porte »

Jusqu'ici, les scans sont **informatifs** : `allow_failure: true` laisse le pipeline continuer
même en cas d'échec. Une porte de sécurité, c'est l'inverse : **le pipeline s'arrête** si la
règle n'est pas respectée. KICS s'y prête bien, car son code de sortie reflète la sévérité la
plus haute trouvée :

| Code de sortie KICS | Signification |
|---|---|
| `0` | aucun résultat (ou aucun résultat de sévérité incluse dans `--fail-on`) |
| `20` / `30` / `40` | au pire INFO / LOW / MEDIUM |
| `50` | au moins un HIGH |
| `60` | au moins un CRITICAL |

🚧 **À compléter** dans le job `kics` :

```yaml
kics:
  # ...
  # TODO : ce job ne doit plus être "toléré en échec" (il hérite de allow_failure: true via .sast)
  script:
    # TODO : ajoutez l'option qui limite l'échec aux sévérités high et critical
    - kics scan -p Dockerfile -o kics-report --report-formats html,json,glsast --no-progress
```

> 📖 [KICS : codes de sortie et `--fail-on`](https://docs.kics.io/latest/results/#exit_status_code)

> 💡 **Tester :** remettez temporairement `FROM node:latest` et supprimez la ligne `USER`. Le job
> `kics` passe au **rouge** avec `Job failed: exit code 50` et le pipeline s'arrête. Restaurez
> ensuite le Dockerfile durci.

---

## 📦 Étape 8 : Construire et publier l'image

Pour analyser l'image comme objet livré, le pipeline doit d'abord la **construire** puis la
**stocker** quelque part. Chaque projet GitLab dispose d'un **Container Registry** intégré, et le
runner reçoit automatiquement des identifiants pour y écrire.

### 8.1 Les variables prédéfinies du registry

Vous n'avez **rien à configurer** : GitLab injecte ces variables dans chaque job.

| Variable | Exemple de valeur | Rôle |
|---|---|---|
| `CI_REGISTRY` | `registry.gitlab.com` | adresse du registry |
| `CI_REGISTRY_IMAGE` | `registry.gitlab.com/<groupe>/<projet>` | nom de base des images du projet |
| `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD` | `gitlab-ci-token` / *(jeton du job)* | identifiants **temporaires**, valables le temps du job |
| `CI_COMMIT_SHORT_SHA` | `1117ebc` | identifiant court du commit, idéal pour taguer l'image |

> 📖 [GitLab : variables prédéfinies](https://docs.gitlab.com/ci/variables/predefined_variables/) · [Container Registry : s'authentifier depuis la CI](https://docs.gitlab.com/user/packages/container_registry/authenticate_with_container_registry/)

### 8.2 Comment construire une image *dans* un conteneur ?

Le job s'exécute lui-même dans un conteneur. Pour lancer `docker build`, il lui faut un démon
Docker. Il existe plusieurs approches :

| Approche | Principe | ⚖️ |
|---|---|---|
| **Docker-in-Docker (dind)** | un **service** `docker:dind` démarre un démon Docker à côté du job | simple et standard sur les runners gitlab.com ; mais le service tourne en **privileged**, ce qui pose problème sur un runner partagé que vous administrez vous-même (étape 13) |
| **Buildah / Podman** | construit l'image sans démon, en *rootless* | plus sûr ; syntaxe un peu différente |
| **BuildKit rootless** (`moby/buildkit:rootless`) | le moteur de build moderne de Docker, sans privilèges | recommandé quand on gère ses propres runners |
| ~~Kaniko~~ | build sans démon | le projet Google a été **archivé en 2025** : à éviter pour un nouveau pipeline |

On utilise **dind** ici, car c'est l'option documentée et prête à l'emploi sur gitlab.com. La
partie 2 revient sur le risque qu'elle représente.

> 📖 [GitLab : construire des images Docker avec docker-in-docker](https://docs.gitlab.com/ci/docker/using_docker_build/#use-docker-in-docker)

### 8.3 Tag ou digest ? La notion clé de la suite

Une image se désigne de deux façons :

```
registry.gitlab.com/groupe/projet:1117ebc                     # TAG : une étiquette, DÉPLAÇABLE
registry.gitlab.com/groupe/projet@sha256:b27b23b579f6...      # DIGEST : l'empreinte du contenu, IMMUABLE
```

Un **tag** ressemble à un nom de branche : n'importe qui ayant les droits d'écriture peut
pousser une *autre* image sous le même tag. Un **digest** est le hash SHA-256 du manifeste de
l'image. Si un seul octet change, le digest change aussi.

Toutes les étapes suivantes (SBOM, scans, signature) travailleront donc **sur le digest**. On
garantit ainsi qu'on analyse, puis qu'on signe, *exactement* l'image qui a été construite, et
pas une image glissée sous le même tag entre deux jobs.

### 8.4 Le job de build

Le build produit le digest, mais les jobs suivants tournent dans d'autres conteneurs. Pour leur
transmettre une valeur calculée pendant un job, GitLab propose le rapport **`dotenv`** : le job
écrit des lignes `CLE=valeur` dans un fichier, et ces variables sont injectées dans tous les jobs
qui le citent dans leurs `needs:`.

🚧 **À compléter.** Ajoutez d'abord le stage `package` après `test` dans `stages:`, la variable
`IMAGE_TAG` dans le bloc `variables:` global existant, puis le job :

```yaml
variables:
  # ... vos variables existantes, dans le MÊME bloc
  IMAGE_TAG: "${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}"

docker-build:
  stage: package
  image: docker:28.3.2
  services:
    - # TODO : le service docker-in-docker, MÊME version que l'image du job
  variables:
    DOCKER_TLS_CERTDIR: "/certs"     # le client et le démon dind communiquent en TLS
  needs: [unit-test-job]             # on ne construit que du code dont les tests passent
  cache: []                          # pas besoin du cache npm ici
  before_script:
    # TODO : docker login sur $CI_REGISTRY avec $CI_REGISTRY_USER, mot de passe lu sur l'entrée standard
    #        (echo "$CI_REGISTRY_PASSWORD" | docker login ... --password-stdin)
  script:
    - docker build --pull -t "$IMAGE_TAG" .
    # TODO : pousser l'image taguée
    # Après le push, Docker connaît le digest : RepoDigests = "registry/projet@sha256:..."
    - IMAGE_REF=$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE_TAG")
    - echo "IMAGE_REF=${IMAGE_REF}" >> build.env
    - echo "BUILD_JOB_ID=${CI_JOB_ID}" >> build.env    # servira à la provenance (partie 2)
    - cat build.env
  artifacts:
    reports:
      # TODO : déclarer build.env comme rapport dotenv
```

> 📖 [GitLab : `artifacts:reports:dotenv`](https://docs.gitlab.com/ci/yaml/artifacts_reports/#artifactsreportsdotenv) · [`services`](https://docs.gitlab.com/ci/yaml/#services)

> 💡 **Tester :** le log du job se termine par deux lignes de ce type :
>
> ```
> IMAGE_REF=registry.gitlab.com/<groupe>/<projet>@sha256:b27b23b579f69d1bc1030dd07afc28add305cc42e128302bb53a29a74fa323e4
> BUILD_JOB_ID=556...
> ```
>
> L'image apparaît dans **Deploy > Container registry**, avec le tag `<sha court>`. Vérifiez que
> le digest affiché dans l'interface est bien celui du log.

> ⚖️ Ce job tourne sur **chaque** push, donc chaque commit de chaque branche publie une image
> d'environ 360 Mo. Pour un lab, c'est acceptable. Sur un vrai projet, configurez une
> [politique de nettoyage](https://docs.gitlab.com/user/packages/container_registry/reduce_container_registry_storage/#cleanup-policy)
> du registry (par exemple : garder les 10 dernières images par branche).

---

## 🧾 Étape 9 : Dépendances, image ou SBOM ?

C'est le cœur de cette partie. Votre pipeline va bientôt contenir trois façons de chercher des
vulnérabilités connues (CVE). On commence par bien les distinguer, avant de les exécuter côte à
côte sur la même application.

### 9.1 Trois approches, trois périmètres

Les trois approches ne regardent pas le même objet :

```
 package-lock.json ──► [1] SCAN DE DÉPENDANCES (npm audit, osv-scanner source)
        │                  ne voit QUE ce qui est déclaré dans le lockfile
        ▼
   docker build
        │
        ▼
  IMAGE (Debian + Node.js + npm + votre app + node_modules)
        ├────────► [2] SCAN D'IMAGE DIRECT (trivy image)
        │              inventorie le contenu de l'image ET le compare aux CVE, en une seule passe
        │
        └──► SBOM (fichier JSON) ──► [3] SCAN DU SBOM (grype, osv-scanner)
            [3a] inventaire seul        [3b] comparaison aux CVE, rejouable à volonté
```

| | [1] Dépendances | [2] Image directe | [3] SBOM puis scan |
|---|---|---|---|
| **Entrée** | lockfile (`package-lock.json`) | l'image (couches téléchargées) | un fichier **SBOM** : CycloneDX ou SPDX |
| **Voit les paquets OS (Debian)** | ❌ | ✅ | ✅ (si le SBOM vient de l'image) |
| **Voit le runtime embarqué (npm de l'image `node`)** | ❌ | ✅ | ✅ |
| **Voit les devDependencies** | ✅ (bruit si non livrées) | ❌ (pas dans l'image) | selon la source du SBOM |
| **Quand** | dès le push, en quelques secondes | après le build | génération après le build, puis scan **à tout moment** |
| **Résultat conservable** | non | un rapport, qui n'est plus valable le lendemain | **l'inventaire**, qui reste valable tant que l'image ne change pas |

Un **SBOM** (*Software Bill of Materials*) est la « liste des ingrédients » d'un logiciel : un
fichier JSON qui recense chaque composant, avec son nom, sa version, son identifiant universel
(`purl`, par exemple `pkg:npm/express@4.18.3`) et souvent sa licence. Deux formats standard
coexistent :

| Format | Porté par | Usage dominant |
|---|---|---|
| [**CycloneDX**](https://cyclonedx.org/) | OWASP | sécurité : vulnérabilités, VEX. Le plus courant dans les outils DevSecOps. **C'est celui qu'on utilise.** |
| [**SPDX**](https://spdx.dev/) | Linux Foundation (norme ISO/IEC 5962) | conformité de licences, juridique |

#### Pourquoi un SBOM plutôt qu'un simple scan d'image ?

Un `trivy image` fait en réalité la même chose « sous le capot » : il inventorie l'image, puis
compare l'inventaire aux bases de CVE. L'intérêt du SBOM est de **séparer ces deux opérations**,
et de conserver l'inventaire. Ce découpage apporte quatre avantages :

1. **Le temps joue pour vous.** Un scan dit « aucune CVE critique *aujourd'hui* ». Or de nouvelles
   CVE sont publiées chaque jour : l'image validée ce matin peut être vulnérable la semaine
   prochaine, sans avoir changé d'un octet. Avec un SBOM conservé (quelques centaines de Ko, contre
   des centaines de Mo pour l'image), on peut **re-scanner chaque nuit** ce qui tourne en
   production, sans reconstruire ni retélécharger l'image. Vous le mettrez en place à l'étape 9.7.
   C'est aussi le principe des plateformes comme [Dependency-Track](https://dependencytrack.org/).
2. **Le SBOM se partage, l'image non.** Un client, un auditeur ou une équipe conformité ne veut
   pas (ou ne doit pas) recevoir votre image propriétaire. En revanche, il peut lire un SBOM avec
   ses propres outils (licences, CVE). La réglementation va dans ce sens : le **Cyber Resilience
   Act** européen impose aux éditeurs de produits numériques de tenir à jour un SBOM.
3. **Le SBOM se signe et voyage avec l'image.** Dans la partie 2, vous l'attacherez à l'image sous
   forme d'**attestation signée**. Quiconque récupère l'image pourra alors récupérer *son*
   inventaire certifié.
4. **VEX : réduire le bruit.** Un SBOM peut être accompagné d'un document **VEX** (*Vulnerability
   Exploitability eXchange*). Il permet de déclarer : « la CVE-X est présente dans ce composant,
   mais *non exploitable* chez nous, car la fonction vulnérable n'est jamais appelée ». Trivy et
   Grype savent lire un VEX et masquer l'alerte correspondante.

> ⚖️ **Restons nuancés.** On lit parfois qu'un SBOM est « plus complet » qu'un scan d'image, ou que
> les scanners d'image « ratent » les images *distroless*. C'est en partie faux : le SBOM produit
> par Syft à partir d'une image voit **exactement** ce que voit `trivy image`. Les deux lisent les
> mêmes métadonnées (la base `dpkg`, les `package.json`…), et les images distroless conservent ces
> métadonnées : vous le constaterez au bonus de l'étape 9.6. Le vrai angle mort de **tous** les
> outils, ce sont les fichiers **sans métadonnées** : un binaire copié à la main, ou du JavaScript
> *bundlé* par webpack, dont les dépendances ont disparu dans un seul fichier. Pour ce cas, on
> génère **aussi** un SBOM depuis les **sources**, au moment du build (cdxgen, étape 9.3).

> 📖 [CycloneDX : spécification](https://cyclonedx.org/specification/overview/) · [CISA : qu'est-ce qu'un SBOM](https://www.cisa.gov/sbom) · [Trivy et VEX](https://trivy.dev/latest/docs/supply-chain/vex/)

### 9.2 L'approche [2] : scan direct de l'image avec Trivy

Un rappel avant d'écrire ces jobs. À l'étape 5, le modèle `.sast` a restreint ses rapports avec
`artifacts: access: developer`. Les rapports de cette étape ne passent pas par `.sast` : ajoutez-leur
la même ligne. Sur un projet public, une liste de vulnérabilités de votre image ne doit pas être
lisible par tout le monde, car c'est une feuille de route pour un attaquant.

On commence par l'approche la plus simple, qui servira de référence. Trivy doit télécharger
l'image depuis votre registry, il a donc besoin des identifiants. Il les lit dans ses variables
`TRIVY_USERNAME` et `TRIVY_PASSWORD`. Il télécharge aussi sa base de CVE, volumineuse : on la met
en cache entre deux pipelines.

🚧 **À compléter.** Ajoutez les stages `sbom` puis `scan-image` après `package`, puis le job :

```yaml
trivy-image:
  stage: scan-image
  image:
    name: aquasec/trivy:0.75.0
    entrypoint: [""]
  needs: [docker-build]          # -> récupère IMAGE_REF via le dotenv
  allow_failure: true            # informatif : la "porte" sera Grype (9.4)
  variables:
    TRIVY_USERNAME: # TODO : utilisateur du registry
    TRIVY_PASSWORD: # TODO : mot de passe du registry
    TRIVY_CACHE_DIR: ".trivycache/"
  cache:
    key: trivy-db
    paths: [.trivycache/]
  script:
    # TODO 1 : "trivy image" sur $IMAGE_REF (le DIGEST, pas le tag), sortie table dans trivy-image.txt
    # TODO 2 : relancer en échouant (code 1) s'il existe au moins une CVE CRITICAL
  artifacts:
    access: developer
    when: always                 # on veut le rapport MÊME si le job échoue
    paths: [trivy-image.txt]
```

> 📖 [Trivy : `trivy image`](https://trivy.dev/latest/docs/target/container_image/) · [Trivy : registres privés](https://trivy.dev/latest/docs/advanced/private-registries/docker-hub/)

> 💡 **Tester :** ouvrez l'artefact `trivy-image.txt`. Le détail se découpe en **deux blocs** :
>
> ```
> registry.gitlab.com/.../projet@sha256:... (debian 13.7)
> Total: 162 (UNKNOWN: 1, LOW: 60, MEDIUM: 58, HIGH: 43, CRITICAL: 0)     <- paquets du système Debian
> Node.js (node-pkg)
> Total: 34 (UNKNOWN: 0, LOW: 7, MEDIUM: 14, HIGH: 12, CRITICAL: 1)       <- TOUS les paquets npm de l'image
> ```
>
> Le bloc `Node.js` mélange deux origines. Pour les distinguer, remontez au **Report Summary** en
> haut du fichier, qui liste chaque `package.json` analysé. Ceux qui commencent par
> `app/node_modules/` sont **vos** dépendances. Ceux qui commencent par
> `usr/local/lib/node_modules/npm/` appartiennent au **npm embarqué** dans l'image `node`. Gardez
> cette distinction en tête pour la comparaison de l'étape 9.5.

### 9.3 L'approche [3], étape 1 : générer le SBOM

On sépare maintenant l'inventaire du scan. Deux générateurs, pour deux points de vue :

| Générateur | Source analysée | Ce que contient le SBOM |
|---|---|---|
| [**Syft**](https://github.com/anchore/syft) (Anchore) | l'**image** construite | tout ce qui est réellement livré : Debian, Node, npm, votre `node_modules` |
| [**cdxgen**](https://github.com/CycloneDX/cdxgen) (OWASP CycloneDX) | les **sources** (lockfile, manifestes) | l'arbre de dépendances déclaré, y compris les devDependencies |

**9.3.a Syft.** C'est le SBOM principal, celui qu'on scannera et qu'on signera. L'image
`anchore/syft` standard n'a pas de shell, on prend donc la variante `-debug`. Dans cette variante,
le binaire se trouve à la racine du conteneur (`/syft`) et n'est pas dans le `PATH` : on l'appelle
avec son chemin complet. Syft lit les identifiants du registry dans ses propres variables
`SYFT_REGISTRY_AUTH_*`.

🚧 **À compléter :**

```yaml
sbom-image:
  stage: sbom
  image:
    name: anchore/syft:v1.54.1-debug
    entrypoint: [""]
  needs: [docker-build]
  cache: []
  variables:
    SYFT_REGISTRY_AUTH_AUTHORITY: "$CI_REGISTRY"
    SYFT_REGISTRY_AUTH_USERNAME: # TODO
    SYFT_REGISTRY_AUTH_PASSWORD: # TODO
    # Sans cette variable, Syft ajoute une entrée par FICHIER de l'image (~2 600 composants "file")
    # qui noient le SBOM et perturbent certains scanners (OSV, voir 9.5)
    SYFT_FILE_METADATA_SELECTION: "none"
  script:
    # TODO : /syft scan "registry:<image par digest>" avec DEUX sorties :
    #        - cyclonedx-json dans le fichier sbom.cdx.json
    #        - table (affichée dans le log)
    #        syntaxe : -o <format>=<fichier>  (répétable)
  artifacts:
    access: developer
    paths: [sbom.cdx.json]
    expire_in: 90 days    # on le garde longtemps : il servira au re-scan nocturne (9.7)
```

> 📖 [Syft : formats de sortie](https://github.com/anchore/syft/wiki/Output-Formats) · [Syft : sources (`registry:`, `docker-archive:`…)](https://github.com/anchore/syft#supported-sources) · [Syft : authentification registre](https://github.com/anchore/syft#private-registry-authentication)

Publier le SBOM brut comme artefact permet aux développeurs de le télécharger : il est disponible
dans la page du job, bouton **Download** dans la colonne de droite. `expire_in: 90 days` le conserve
assez longtemps pour le re-scan nocturne.

**9.3.b cdxgen (facultatif).** Pour comparer avec le point de vue « sources », ce job tourne dès
le début du pipeline (`needs: []`) dans l'image node par défaut :

```yaml
sbom-source:
  stage: sbom
  needs: []
  cache: []
  script:
    - npx --yes @cyclonedx/cdxgen@12.8.5 -t js -o sbom-source.cdx.json .
  artifacts:
    paths: [sbom-source.cdx.json]
    expire_in: 30 days
```

> ⚖️ `npx --yes` télécharge cdxgen **et ses dépendances** au moment du job. La version de cdxgen
> est épinglée, mais pas celles de ses dépendances. C'est acceptable pour un outil d'analyse, mais
> c'est exactement le type de risque de chaîne d'approvisionnement que traite la partie 2. Pour
> la production, préférez une image versionnée.

> 💡 **Tester :** téléchargez `sbom.cdx.json` et ouvrez-le. Cherchez `pkg:npm/express@` : vous
> trouvez la version réellement installée dans l'image (`4.18.3` pour l'instant). Cherchez ensuite
> `pkg:npm/mocha` : **aucun résultat**. Les devDependencies ne sont pas dans l'image, donc pas dans
> son SBOM. Si vous avez `jq` en local, vous pouvez aussi compter les composants :
>
> ```bash
> jq '.components | length' sbom.cdx.json                                         # -> environ 300
> jq -r '.components[].purl // empty' sbom.cdx.json | cut -d/ -f1 | sort | uniq -c
> #     79 pkg:deb
> #      1 pkg:generic
> #    218 pkg:npm
> ```

### 9.4 L'approche [3], étape 2 : valider le SBOM avec Grype

[**Grype**](https://github.com/anchore/grype) est le scanner « compagnon » de Syft. Il lit un
SBOM et le compare à sa base de vulnérabilités. C'est lui qui jouera le rôle de **porte** : sans
`allow_failure`, un échec bloque la suite du pipeline (et, dans la partie 2, la signature).

| Option Grype | Rôle |
|---|---|
| `sbom:<fichier>` | la cible est un SBOM (et non une image) |
| `-o table` / `-o json=grype.json` | sortie lisible dans le log + rapport JSON en fichier |
| `--fail-on <sévérité>` | code de sortie **2** si une vulnérabilité de cette sévérité *ou plus* est trouvée |
| `--only-fixed` | ignore les CVE sans correctif disponible (utile pour ne bloquer que ce qu'on *peut* corriger) |

🚧 **À compléter** (même remarque que Syft : variante `-debug`, binaire en `/grype`) :

```yaml
grype-sbom:
  stage: scan-image
  image:
    name: anchore/grype:v0.120.1-debug
    entrypoint: [""]
  needs: [sbom-image]            # -> récupère l'artefact sbom.cdx.json
  variables:
    GRYPE_DB_CACHE_DIR: "${CI_PROJECT_DIR}/.grype-db"
  cache:
    key: grype-db
    paths: [.grype-db/]
  script:
    # TODO : /grype sur le SBOM, sorties table + json=grype.json, échec à partir de "critical"
  artifacts:
    access: developer
    when: always
    paths: [grype.json]
```

> 📖 [Grype : scanner un SBOM](https://github.com/anchore/grype#supported-sources) · [Grype : `--fail-on`](https://github.com/anchore/grype#gating-on-severity-of-vulnerabilities)

Ajoutez enfin un job **OSV-Scanner sur le SBOM**, pour comparer avec Grype. Comme les deux
précédents, il a besoin de l'artefact `sbom.cdx.json` du job `sbom-image`. On réutilise ici votre
façon d'installer OSV (`alpine:edge` + `apk`) ; la partie 2 la remplacera par une installation
vérifiée.

```yaml
osv-sbom:
  stage: scan-image
  image: alpine:edge
  needs: [sbom-image]
  allow_failure: true
  cache: []
  before_script:
    - apk add --no-cache osv-scanner
  script:
    # -L : "lockfile" explicite ; OSV reconnaît un SBOM CycloneDX grâce à l'extension .cdx.json
    - osv-scanner scan source -L sbom.cdx.json --format html --output-file osv-sbom.html
  artifacts:
    access: developer
    when: always
    paths: [osv-sbom.html]
```

> 📖 [OSV-Scanner : scanner un SBOM](https://google.github.io/osv-scanner/usage/scan-source#sbom-scanning)

> 💡 **Tester :** avec le `package-lock.json` fourni à l'étape 6, `grype-sbom` passe au **rouge**,
> et la vulnérabilité responsable apparaît dans le log :
>
> ```
> NAME        INSTALLED  FIXED IN  TYPE  VULNERABILITY        SEVERITY
> proxy-addr  2.0.7      2.0.8     npm   GHSA-jqcg-44mw-7w3h  Critical
> ...
> ERROR discovered vulnerabilities at or above the severity threshold
> ```
>
> La porte fonctionne : la dépendance transitive `proxy-addr`, tirée par `express` 4.18.3, bloque
> le pipeline. On la corrigera à l'étape 9.6.

### 9.5 📊 Comparer les approches

Vous avez maintenant, dans **un seul pipeline**, les trois approches appliquées à la même
application. 🚧 **À vous de jouer :** lancez un pipeline avec `EXEC_ONLY = all` (*Build > Pipelines > Run
pipeline*), pour que `npm-audit` et `osv-scanner` tournent aussi. Relevez vos propres chiffres dans
les logs et les artefacts, puis comparez-les avec les nôtres. Deux lignes ne viennent pas
directement d'un job : le chiffre « prod uniquement » s'obtient en local avec
`npm audit --omit=dev`, et la ligne « SBOM des sources » demande d'appliquer OSV à
`sbom-source.cdx.json` (en local, ou dans une copie du job `osv-sbom`). Elles sont facultatives.

| Approche | Job | Ce qu'il a vu (le 29/10/2026) |
|---|---|---|
| [1] Dépendances | `npm-audit` | **24** paquets vulnérables, dont **8** seulement en dépendances de prod (`npm audit --omit=dev`) |
| [1] Dépendances | `osv-scanner` (source) | 272 paquets lus ; **54** vulnérabilités dans **22** paquets, devDependencies comprises |
| [3] SBOM des sources *(facultatif)* | `sbom-source` puis OSV | 276 composants ; quasiment le même résultat que la ligne précédente (**55** vulnérabilités, 22 paquets) |
| [2] Image directe | `trivy-image` | **196** vulnérabilités : **162** Debian (39 paquets), **16** dans *vos* `node_modules` (8 paquets), **18** dans le **npm embarqué** par l'image `node` (5 paquets) |
| [3] SBOM de l'image | `sbom-image` puis `grype-sbom` | 299 composants ; **191** correspondances (157 Debian, 34 npm), dont **1 Critical** |
| [3] SBOM de l'image | `sbom-image` puis `osv-sbom` | **33** vulnérabilités, **uniquement npm** : les 79 paquets Debian du SBOM sont ignorés |

**Ce qu'il faut en retenir :**

- **Les sources ne voient qu'un tiers du problème.** Les 8 paquets de prod signalés par `npm audit --omit=dev` sont exactement les 8 que Trivy trouve dans `/app/node_modules`. Tout le reste (Debian, npm embarqué) est invisible depuis le dépôt Git.
- **Les sources voient aussi du « faux » problème.** Les vulnérabilités des devDependencies (mocha, cypress…) ne sont pas livrées en production. Le scan de dépendances est utile *tôt*, mais il est bruyant.
- **Syft + Grype ≈ Trivy.** C'est attendu : les deux inventorient la même image. Les petits écarts viennent de bases de CVE différentes.
- **L'interopérabilité des SBOM a ses limites.** En théorie, CycloneDX permet de combiner n'importe quel générateur avec n'importe quel scanner. En pratique, avec les versions testées, OSV-Scanner ignore les paquets Debian d'un SBOM. De plus, Grype appliqué à un SBOM produit par **Trivy** ne trouve que 18 CVE Debian, contre 157 avec un SBOM produit par **Syft**. **Validez toujours le couple générateur + scanner** sur un cas connu avant de lui faire confiance. On retient ici Syft + Grype, qui viennent du même éditeur.

### 9.6 Corriger, puis repasser la porte

La porte bloque à cause de `express` 4.18.3. On met à jour les dépendances **de production**
uniquement, sans casser les tests :

```bash
# en local (Node.js 24 installé) ; mêmes précautions que dans le pipeline : pas de Cypress, pas de scripts
CYPRESS_INSTALL_BINARY=0 npm audit fix --omit=dev --ignore-scripts
npm audit --omit=dev             # -> found 0 vulnerabilities
npm ls express                   # -> express@4.22.3
```

Seul `package-lock.json` change : les plages de versions de `package.json` (`^4.18.3`) autorisent
déjà `4.22.3`. Si vous avez Docker mais pas Node.js, lancez la même chose dans un conteneur :

```bash
docker run --rm -v "$PWD:/app" -w /app -e CYPRESS_INSTALL_BINARY=0 node:24.22.1-trixie-slim \
  sh -c 'npm audit fix --omit=dev --ignore-scripts && rm -rf node_modules'
```

Si vous travaillez uniquement dans le Web IDE, remplacez le contenu de votre `package-lock.json`
par celui de [`assets/etape9/package-lock.json`](assets/etape9/package-lock.json). C'est le
lockfile obtenu par la commande ci-dessus : seules les versions de `express` et de ses dépendances
changent.

Commitez le nouveau `package-lock.json` et poussez.

> 💡 **Tester :** `grype-sbom` passe au **vert**. La porte est franchie.

Il reste pourtant des vulnérabilités **High** dans l'image. Ouvrez `grype.json` ou le log et
regardez leur `TYPE`. Elles sont toutes soit `deb` (Debian), soit dans `brace-expansion`,
`undici`, `ip-address`… Ces derniers paquets ne sont **pas** dans votre `package.json` : ce sont
les dépendances du **npm** livré dans l'image `node`. Votre application n'en a pas besoin pour
tourner.

<details>
<summary>✅ Bonus : une image d'exécution <em>distroless</em></summary>

Une image [*distroless*](https://github.com/GoogleContainerTools/distroless) ne contient que le
runtime : ni shell, ni `apt`, ni `npm`. Le fichier
[`solution/Dockerfile.distroless`](solution/Dockerfile.distroless) garde le même stage `deps`, mais
remplace le stage d'exécution par `gcr.io/distroless/nodejs24-debian13:nonroot`.

| | Image `-slim` durcie | Image distroless |
|---|---|---|
| Taille | 359 Mo | **228 Mo** |
| Vulnérabilités (Grype, après correction) | 175 | **31** (Debian uniquement, 0 npm) |
| Shell (`docker exec ... sh`) | oui | **non** : `exec: "sh": executable file not found` |

**Le piège.** Sans ligne `USER`, Trivy (`DS-0002`) et KICS lèvent une alerte **HIGH** *Missing
User Instruction*, alors que l'image `:nonroot` tourne déjà sous l'UID 65532. C'est un **faux
positif** : un scanner de Dockerfile ne lit que *ce fichier*, jamais l'image de base. La bonne
correction n'est pas de désactiver la règle, mais d'**écrire explicitement** `USER 65532:65532`.
C'est plus lisible, et les outils sont satisfaits.

</details>

### 9.7 Re-scanner chaque nuit sans reconstruire

C'est l'avantage « temporel » du SBOM (argument 1 de la section 9.1). Une fois par nuit, un
pipeline **planifié** récupère le dernier SBOM de `main` et le soumet à la base de CVE du jour.
Il n'y a ni build, ni téléchargement d'image.

Deux mécanismes sont nécessaires :

1. **Un job dédié**, qui télécharge l'artefact `sbom.cdx.json` du dernier job `sbom-image` réussi sur `main`, via l'[API des artefacts](https://docs.gitlab.com/api/job_artifacts/#download-a-single-artifact-file-by-reference-name). Le jeton `CI_JOB_TOKEN` du job suffit pour s'authentifier.
2. **Exclure tous les autres jobs** des pipelines planifiés, pour ne pas tout reconstruire chaque nuit.

Pour ne pas recopier la même règle dans chaque job, on utilise une **ancre YAML**, une fonction
du format YAML lui-même (et non de GitLab). On écrit le bloc une fois, en le nommant avec `&nom`,
puis on le réinsère ailleurs avec `*nom`. Une ancre doit être **définie avant** sa première
utilisation dans le fichier : placez donc le bloc `.no-schedule` **tout en haut** de votre
`.gitlab-ci.yml`, juste après `stages:` et avant le premier job. Sinon, GitLab signale une erreur
d'alias inconnu.

🚧 **À compléter.** Le premier bloc s'ajoute en haut du fichier. Pour les jobs existants,
**modifiez** chacun d'eux (n'en recopiez pas un second `build-app:`, ce serait une clé en double) :

```yaml
# Règle réutilisable : "jamais dans un pipeline planifié"
.no-schedule: &no-schedule
  if: $CI_PIPELINE_SOURCE == "schedule"
  when: never

# Dans CHAQUE job existant, ajoutez cette règle EN PREMIER. Exemple pour build-app :
build-app:
  stage: build
  rules:
    - *no-schedule
    - when: on_success          # sinon : comportement normal
  # ...
# Pour .sast, .dockerfile-scan ET sonarcloud-check (qui a ses propres rules, sans hériter de
# celles de .sast) : ajoutez "- *no-schedule" en tête de leur liste rules existante.

nightly-sbom-rescan:
  stage: scan-image
  image:
    name: anchore/grype:v0.120.1-debug
    entrypoint: [""]
  needs: []
  rules:
    # TODO : uniquement dans les pipelines planifiés
  variables:
    GRYPE_DB_CACHE_DIR: "${CI_PROJECT_DIR}/.grype-db"
  cache:
    key: grype-db
    paths: [.grype-db/]
  script:
    # wget (busybox) avec le jeton du job dans l'en-tête JOB-TOKEN
    - 'wget --header "JOB-TOKEN: ${CI_JOB_TOKEN}" -O sbom.cdx.json "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/artifacts/${CI_DEFAULT_BRANCH}/raw/sbom.cdx.json?job=sbom-image"'
    # TODO : grype sur ce SBOM, échec à partir de "critical"
```

Pourquoi la ligne `wget` est-elle entre apostrophes ? Elle contient `: ` (deux-points suivi d'une
espace) dans `JOB-TOKEN: ...`, ce que YAML interpréterait comme une clé. Les apostrophes en font
une simple chaîne.

> ⚖️ **Effet de bord : les pipelines en double.** Un job dont la dernière règle est
> `- when: on_success` tourne dans *tous* les types de pipeline, y compris les pipelines de merge
> request. Comme `sonarcloud-check` déclenche déjà des pipelines de MR, chaque push sur une
> branche avec une MR ouverte produira **deux** pipelines. Le remède standard est un bloc
> `workflow:rules`, à placer en haut du fichier :
>
> ```yaml
> workflow:
>   rules:
>     - if: $CI_PIPELINE_SOURCE == "merge_request_event"   # pipeline de MR
>     - if: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS     # branche avec MR ouverte :
>       when: never                                          #   pas de pipeline de branche en plus
>     - if: $CI_COMMIT_BRANCH                                # sinon : pipeline de branche
> ```
>
> Les pipelines planifiés ou lancés à la main restent couverts par la dernière règle, car ils
> portent eux aussi une branche.

> 📖 [GitLab : pipelines planifiés](https://docs.gitlab.com/ci/pipelines/schedules/) · [éviter les pipelines en double](https://docs.gitlab.com/ci/jobs/job_rules/#avoid-duplicate-pipelines) · [ancres YAML dans GitLab CI](https://docs.gitlab.com/ci/yaml/yaml_optimization/#anchors) · [`CI_JOB_TOKEN`](https://docs.gitlab.com/ci/jobs/ci_job_token/)

> 💡 **Tester :** créez une planification dans **Build > Pipeline schedules > New schedule**
> (par exemple `0 3 * * *`, branche `main`), puis cliquez sur ▶️ pour la lancer immédiatement. Le
> pipeline ne contient **qu'un seul job**, `nightly-sbom-rescan`, et son log affiche
> `'sbom.cdx.json' saved` puis la table Grype.

---

## 🎉 Challenge de fin de partie

- [ ] Les trois scanners de Dockerfile tournent avec `EXEC_ONLY = dockerfile`, et votre tableau de comparaison (7.5) est rempli.
- [ ] Le Dockerfile durci passe les trois scanners ; KICS est une porte bloquante (`allow_failure: false` + `--fail-on high,critical`).
- [ ] L'image est publiée dans le registry, et `IMAGE_REF` (digest) circule entre les jobs via `dotenv`.
- [ ] `sbom.cdx.json` est téléchargeable depuis le job `sbom-image`.
- [ ] `grype-sbom` a bloqué le pipeline avant la correction de `express`, puis l'a laissé passer après.
- [ ] Vous savez expliquer, chiffres à l'appui, ce qu'un scan de dépendances **ne voit pas**.
- [ ] Un pipeline planifié ne lance que `nightly-sbom-rescan`.

## Récap

| Notion | À retenir |
|---|---|
| Analyse de Dockerfile | Une famille à part entière (misconfiguration / IaC). Hadolint = style, Trivy/KICS = sécurité. Aucun outil ne remplace la relecture (`COPY . .`). |
| Digest | Désigne une image **immuable**. Toujours scanner et signer par digest, jamais par tag. |
| Scan de dépendances | Rapide, précoce, mais aveugle à l'OS et au runtime, et bruyant (devDependencies). |
| Scan d'image | Voit tout ce qui est livré, mais produit un résultat périssable. |
| SBOM | L'**inventaire** séparé du **scan** : conservable, partageable, signable, re-scannable. Validez le couple générateur/scanner. |
| Porte | Un job **non toléré en échec** qui arrête le pipeline. On en a deux : KICS (Dockerfile) et Grype (CVE critiques). |

➡️ **Suite :** [Partie 2 : Sécurité du pipeline](partie-2-securite-pipeline.md). Vous savez
maintenant *ce que contient* votre image. Reste à prouver *d'où elle vient*, et qu'elle n'a pas
été remplacée en chemin.
