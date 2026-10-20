# GLPI Auto-Install

Installateur Bash pour déployer **GLPI sur un serveur Linux dédié, une machine virtuelle KVM ou un conteneur LXC**. Il prépare Apache, PHP-FPM, MariaDB, la structure de fichiers GLPI et les tâches planifiées. La configuration initiale de GLPI et la création des comptes restent à terminer dans l'assistant Web.

> **Version 5.1.1 :** installation neuve, mise à jour et désinstallation contrôlée. Les opérations sur une ancienne installation réalisent une sauvegarde des fichiers et de la base SQL avant toute modification. Une désinstallation simple conserve les données. Les paquets partagés Apache, PHP et MariaDB ne sont jamais purgés.

## Plateformes

| Famille | Distributions visées | Gestionnaire de paquets | Init | Niveau de prise en charge |
| --- | --- | --- | --- | --- |
| Debian | Debian 12+, Ubuntu 24.04 LTS+ | `apt` | systemd | Chemin principal |
| RHEL | RHEL, Rocky, Alma, Oracle Linux et CentOS Stream 9+ | `dnf` | systemd | Compatible sous réserve de dépôts PHP 8.2+ / MariaDB 10.5+ |
| Fedora Server | Version actuellement maintenue | `dnf` | systemd | Compatible sous réserve des versions disponibles |
| openSUSE / SLES | Versions maintenues, disposant de PHP 8.2+ | `zypper` | systemd | **Expérimental : tester en préproduction** |
| Alpine Linux | Alpine 3.20+ | `apk` | OpenRC | **Expérimental : tester en préproduction** |

La présence d'un système dans cette liste **ne signifie pas que toutes ses versions ou variantes ont été testées**. Les dérivées Linux non reconnues, les systèmes Windows et BSD, ainsi que les conteneurs Docker/Podman, ne sont pas pris en charge par ce script. Pour ces derniers, utilisez un déploiement GLPI dédié.

**KVM / Proxmox / LXC :** le type de virtualisation ne modifie pas les dépendances GLPI. L'invité doit disposer d'un réseau fonctionnel, d'un gestionnaire de services actif, des droits administrateur et de l'espace nécessaire. Sur un conteneur LXC, vérifier notamment que systemd (ou OpenRC pour Alpine) démarre bien les services.

## Prérequis

- Serveur dédié à GLPI ; compte `root` ou `sudo`. Pour une mise à jour ou une désinstallation, GLPI doit être situé dans `/var/www/glpi`.
- 1 Gio de RAM minimum et 4 Gio libres sur `/var` (2 Gio ou plus de RAM recommandés).
- Accès HTTPS à GitHub pour récupérer la version officielle GLPI ; `curl` et `tar` sont nécessaires.
- **GLPI 11 : PHP >= 8.2 et MariaDB >= 10.5 ou MySQL >= 8.0**. Les modules PHP obligatoires sont vérifiés après l'installation des paquets.
- DNS public pointant vers le serveur et ports HTTP/HTTPS accessibles si vous demandez un certificat Let's Encrypt.

L'installateur utilise les dépôts standards de la distribution. Il n'ajoute pas de dépôts PHP non officiels et **refuse de poursuivre** si les versions obtenues ne respectent pas les prérequis.

Sur les systèmes RHEL 9 et dérivés, le script active le module officiel `php:8.2` avant d'installer les paquets. Si un autre flux PHP est déjà actif ou que le dépôt AppStream requis est absent, il s'arrête plutôt que de changer silencieusement une installation en place. Sur Alpine, il faut activer le dépôt `community` correspondant à la version installée pour disposer des paquets PHP-FPM.

## Installation

### Menu interactif

Lancez le script **sans argument** pour choisir l'opération directement dans le terminal :

```bash
sudo bash glpi-installer.sh
```

```text
GLPI Auto-Install 5.1.1

  1) Installer GLPI
  2) Mettre à jour GLPI
  3) Désinstaller GLPI
  0) Quitter

Votre choix [0-3] :
```

La sélection ouvre le parcours d'installation, de mise à jour ou de désinstallation, avec les confirmations existantes. Une saisie incorrecte affiche à nouveau l'invite. Le choix `0` quitte sans effectuer de modification. Les appels avec arguments (par exemple `--upgrade`, `--uninstall` et `--yes`) passent directement au mode indiqué. Un terminal interactif est nécessaire pour le menu ; un lancement sans argument depuis un processus non interactif échoue sans lancer d'installation.


Télécharger et inspecter le script avant de l'exécuter :

```bash
curl -fL https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh -o glpi-installer.sh
bash -n glpi-installer.sh
sudo bash glpi-installer.sh --dry-run
sudo bash glpi-installer.sh
```

Mode non interactif :

```bash
sudo bash glpi-installer.sh --yes --domain glpi.example.org
```

Avec HTTPS / Let's Encrypt :

```bash
sudo bash glpi-installer.sh --yes \
  --domain glpi.example.org --enable-ssl --ssl-email admin@example.org
```

Pour fournir un mot de passe de base de données sans l'écrire dans les arguments du processus :

```bash
sudo GLPI_DB_PASSWORD='un-mot-de-passe-de-12-caracteres-minimum' \
  bash glpi-installer.sh --yes
```

Sans variable de configuration, un mot de passe aléatoire est généré. Le fichier `/root/.glpi_credentials` est créé avec les droits `0600` et contient les informations nécessaires à l'assistant Web. **Le mot de passe n'est pas affiché dans les logs.**

### Options

| Option | Description |
| --- | --- |
| `-y`, `--yes` | Confirme une opération non interactive (sans contourner les confirmations de purge) |
| `--upgrade`, `--update` | Met à jour l'instance existante avec sauvegarde préalable |
| `--allow-major-upgrade` | Autorise une migration majeure après vérification des plugins |
| `--uninstall` | Supprime l'application et sa configuration de service, conserve SQL et données |
| `--purge-data` | Supprime aussi données et configuration, après sauvegarde |
| `--purge-db` | Supprime aussi la base SQL locale et son utilisateur dédié |
| `--confirm-purge TOKEN` | Confirmation obligatoire : `DELETE-GLPI-DATA` |
| `--confirm-db-purge TOKEN` | Confirmation obligatoire : `DELETE-GLPI-DATABASE` |
| `-d`, `--dry-run` | Vérifie le type d'OS et décrit le déploiement sans modifier l'hôte |
| `--glpi-version X.Y.Z` | Installe une archive officielle 10.x ou 11.x spécifique |
| `--db-name`, `--db-user` | Personnalise la base et son compte dédié |
| `--db-pass` | Mot de passe explicite (déconseillé : visible dans la liste des processus) |
| `--timezone` | Fuseau horaire PHP (défaut `Europe/Paris`) |
| `--domain` | Nom d'hôte Apache |
| `--enable-ssl`, `--ssl-email` | Certificat Let's Encrypt (prise en charge automatique sur Debian/RHEL) |
| `--help`, `--version` | Aide et numéro de version |

Les anciens raccourcis dangereux `--force`, `--skip-checks`, `--no-rollback`, `--keep-db`, `--keep-packages` restent indisponibles.

## Mise à jour d'une installation existante

La mise à jour conserve la base, les fichiers et les plugins. Elle met GLPI en maintenance, réalise une sauvegarde vérifiée, remplace les fichiers de l'application, puis exécute `php bin/console db:update --no-interaction` sous l'utilisateur du serveur Web.

```bash
# Simulation sans modification
sudo bash glpi-installer.sh --upgrade --dry-run

# Mise à jour vers la dernière version stable
sudo bash glpi-installer.sh --upgrade

# Installation d'une version cible précise
sudo bash glpi-installer.sh --upgrade --glpi-version 11.0.1

# Migration majeure, après revue des plugins et test sur une copie
sudo bash glpi-installer.sh --upgrade --allow-major-upgrade
```

Pour les installations manuelles ou héritées ne disposant pas de `/root/.glpi_credentials`, spécifier **la base locale réellement utilisée** avec `--db-name NOM` ; le script doit pouvoir effectuer un export SQL avec l'authentification root par socket. Les bases distantes ne sont pas gérées par cette procédure. Les versions de PHP et les extensions nécessaires doivent déjà être installées : `--upgrade` ne modifie pas les paquets système.

**Avant une migration GLPI 10 → 11 :** vérifier les plugins FormCreator, Generic Objects et Fields et leurs migrations spécifiques. Un changement majeur nécessite `--allow-major-upgrade`. En cas d'erreur pendant la migration SQL, l'installateur laisse GLPI en maintenance pour éviter une reprise sur un schéma incomplet. Une restauration exige **les fichiers et la base SQL du même point de sauvegarde** ; ne pas réimporter le dump dans une base partiellement migrée sans l'avoir vidée/recréée.

## Désinstallation et conservation des données

```bash
# Simulation
sudo bash glpi-installer.sh --uninstall --dry-run

# Enlever seulement l'application et ses fichiers de configuration Apache/cron/PHP-FPM
# Conserver la base SQL, les données GLPI et les identifiants
sudo bash glpi-installer.sh --uninstall

# Suppression des données/configuration en plus de l'application
sudo bash glpi-installer.sh --uninstall --yes \
  --purge-data --confirm-purge DELETE-GLPI-DATA

# Suppression complète de GLPI ET de sa base SQL locale (irréversible hors sauvegarde)
sudo bash glpi-installer.sh --uninstall --yes \
  --purge-data --confirm-purge DELETE-GLPI-DATA \
  --purge-db --confirm-db-purge DELETE-GLPI-DATABASE
```

Les opérations de purge sont explicites, y compris avec `--yes`. La suppression SQL requiert le fichier d'identifiants de l'installateur afin d'identifier le compte dédié ; aucun compte MySQL global ni paquet de serveur partagé ne doit être supprimé. Le script ne cherche pas GLPI hors de `/var/www/glpi` et refuse les répertoires GLPI symboliques non gérés.

### Sauvegardes de récupération

Les sauvegardes sont enregistrées dans `/var/backups/glpi-installer/<opération>_<date>_<identifiant>/` avec :

- `files.tar.gz` : fichiers GLPI, plugins, configuration, données et journaux locaux ;
- `database.sql.gz` : export transactionnel de la base ;
- `SHA256SUMS` et `manifest.txt` : empreintes et métadonnées.

Les archives sont privées (répertoire en mode `0700`) et **ne sont pas automatiquement effacées**. La présence d'empreintes valides ne garantit pas, à elle seule, la restaurabilité : tester périodiquement une restauration sur une VM de préproduction.

## Après l'installation

1. Ouvrir le site GLPI, compléter l'assistant de connexion et d'initialisation de la base.
2. Modifier immédiatement les mots de passe des comptes créés par GLPI (notamment `glpi`, `tech`, `normal` et `post-only` lorsqu'ils existent).
3. Sécuriser l'accès via HTTPS, un filtrage réseau et des sauvegardes régulières (base + répertoires de données/configuration).
4. Retirer ou désactiver l'assistant d'installation lorsque GLPI indique que cette étape est nécessaire.
5. Vérifier les actions automatiques, les droits d'écriture et les journaux Apache/PHP-FPM/GLPI.

### Emplacements

| Répertoire | Contenu |
| --- | --- |
| `/var/www/glpi` | Code de GLPI, servi uniquement depuis `public/` |
| `/etc/glpi` | Configuration de GLPI |
| `/var/lib/glpi` | Données, fichiers téléversés et marketplace |
| `/var/log/glpi` | Journaux de l'application |
| `/root/.glpi_credentials` | Accès à la nouvelle base, visible uniquement par root |
| `/var/log/glpi-installer` | Journaux de l'installateur (sans mot de passe) |

## Limites et reprise d'erreur

- Seul le chemin local `/var/www/glpi` est reconnu pour les anciennes installations ; les instances personnalisées nécessitent une reprise manuelle.
- Les versions anciennes de PHP/MariaDB doivent être mises à niveau séparément avant de cibler GLPI 11.
- La sauvegarde avant migration/désinstallation est obligatoire, mais ne remplace pas une politique de sauvegarde externalisée.
- Aucune restauration SQL automatique n'est lancée sur un schéma partiellement migré.
- Les règles de pare-feu et les reverse proxies ne sont pas modifiés.
- L'intégration SELinux, SUSE et Alpine doit être validée en préproduction.
- Le mode `--dry-run` ne valide pas les droits effectifs des services ni toutes les dépendances.

Se référer aux procédures officielles : [mise à jour GLPI](https://glpi-install.readthedocs.io/en/latest/update.html), [CLI de maintenance](https://glpi-install.readthedocs.io/en/latest/command-line.html) et [migration des plugins GLPI 10 → 11](https://help.glpi-project.org/tutorials/fr/procedures/migrate-of-specific-plugins-from-glpi-10-to-glpi-11).

## Contribution

Les correctifs sont bienvenus. Vérifiez au minimum `bash -n glpi-installer.sh`, ShellCheck et un déploiement complet en VM/LXC **jetable** avant toute mise en production. Le dépôt est distribué sous licence MIT.
