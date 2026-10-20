# GLPI Auto-Install

Installateur Bash pour déployer **GLPI sur un serveur Linux dédié, une machine virtuelle KVM ou un conteneur LXC**. Il prépare Apache, PHP-FPM, MariaDB, la structure de fichiers GLPI et les tâches planifiées. La configuration initiale de GLPI et la création des comptes restent à terminer dans l'assistant Web.

> **Version 5.0 : changement important.** L'installateur est réservé aux **nouvelles installations**. Il ne remplace plus une installation existante, ne supprime plus de bases de données et ne désinstalle plus automatiquement des paquets partagés. Ne l'utilisez pas pour une migration ou une mise à jour.

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

- Installation **neuve** sur un serveur dédié à GLPI ; compte `root` ou `sudo`.
- 1 Gio de RAM minimum et 4 Gio libres sur `/var` (2 Gio ou plus de RAM recommandés).
- Accès HTTPS à GitHub pour récupérer la version officielle GLPI ; `curl` et `tar` sont nécessaires.
- **GLPI 11 : PHP >= 8.2 et MariaDB >= 10.5 ou MySQL >= 8.0**. Les modules PHP obligatoires sont vérifiés après l'installation des paquets.
- DNS public pointant vers le serveur et ports HTTP/HTTPS accessibles si vous demandez un certificat Let's Encrypt.

L'installateur utilise les dépôts standards de la distribution. Il n'ajoute pas de dépôts PHP non officiels et **refuse de poursuivre** si les versions obtenues ne respectent pas les prérequis.

Sur les systèmes RHEL 9 et dérivés, le script active le module officiel `php:8.2` avant d'installer les paquets. Si un autre flux PHP est déjà actif ou que le dépôt AppStream requis est absent, il s'arrête plutôt que de changer silencieusement une installation en place. Sur Alpine, il faut activer le dépôt `community` correspondant à la version installée pour disposer des paquets PHP-FPM.

## Installation

Télécharger et inspecter le script avant de l'exécuter :

```bash
curl -fL https://raw.githubusercontent.com/Kofysh/GLPI-Auto-Install/main/glpi-installer.sh -o glpi-installer.sh
bash -n glpi-installer.sh
sudo bash glpi-installer.sh --dry-run
sudo bash glpi-installer.sh
```

> Pour tester cette refonte avant son intégration à `main`, utiliser le fichier de la branche `feat/multi-distro-production-installer` à la place du lien ci-dessus.

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
| `-y`, `--yes` | Confirme l'installation non interactive |
| `-d`, `--dry-run` | Vérifie le type d'OS et décrit le déploiement sans modifier l'hôte |
| `--glpi-version X.Y.Z` | Installe une archive officielle 10.x ou 11.x spécifique |
| `--db-name`, `--db-user` | Personnalise la base et son compte dédié |
| `--db-pass` | Mot de passe explicite (déconseillé : visible dans la liste des processus) |
| `--timezone` | Fuseau horaire PHP (défaut `Europe/Paris`) |
| `--domain` | Nom d'hôte Apache |
| `--enable-ssl`, `--ssl-email` | Certificat Let's Encrypt (prise en charge automatique sur Debian/RHEL) |
| `--help`, `--version` | Aide et numéro de version |

Les anciennes options `--uninstall`, `--force`, `--skip-checks`, `--no-rollback`, `--keep-db`, `--keep-packages` ont été retirées pour éviter des actions accidentellement destructives sur un serveur de production.

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

- L'installateur **ne modifie ni ne supprime** une ancienne instance GLPI, sa base ou son compte SQL.
- En cas d'échec après la création de la nouvelle base, celle-ci est conservée. L'administrateur doit examiner l'état de la machine et terminer ou nettoyer manuellement avant une nouvelle tentative.
- Il n'effectue pas de migration de GLPI 10 vers 11, d'upgrade SQL ou de sauvegarde/restauration automatique.
- Les règles du pare-feu et le reverse proxy ne sont pas modifiés.
- L'intégration Apache avec SELinux enforcing, les chemins PHP-FPM SUSE/Alpine et les modules fournis par chaque dépôt demandent des tests réels sur les distributions concernées.
- Le mode `--dry-run` ne vérifie ni la disponibilité des paquets ni les droits effectifs des services : il ne remplace pas un test sur VM/LXC.

La documentation officielle fait foi pour les prérequis : [prérequis GLPI](https://glpi-install.readthedocs.io/en/latest/prerequisites.html) et [installation](https://glpi-install.readthedocs.io/en/latest/install/).

## Contribution

Les correctifs sont bienvenus. Vérifiez au minimum `bash -n glpi-installer.sh`, ShellCheck et un déploiement complet en VM/LXC **jetable** avant toute mise en production. Le dépôt est distribué sous licence MIT.
