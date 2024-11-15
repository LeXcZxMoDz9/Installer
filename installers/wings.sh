#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                    #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>             #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer et/ou le       #
#   modifier selon les termes de la Licence publique générale GNU telle que          #
#   publiée par la Free Software Foundation, version 3 de la licence ou              #
#   (selon votre choix) toute version ultérieure.                                    #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                      #
#   mais SANS AUCUNE GARANTIE ; sans même la garantie implicite de                   #
#   COMMERCIALISATION ou d'ADÉQUATION À UN BUT PARTICULIER. Voir                    #
#   la Licence publique générale GNU pour plus de détails.                           #
#                                                                                    #
#   Vous devez avoir reçu une copie de la Licence publique générale GNU              #
#   avec ce programme. Si ce n'est pas le cas, consultez <https://www.gnu.org/licenses/>. #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet Pterodactyl officiel.                         #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

# Vérifie si le script est chargé, le charge sinon échoue.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERREUR : Impossible de charger le script lib" && exit 1
fi

# ------------------ Variables ----------------- #

INSTALL_MARIADB="${INSTALL_MARIADB:-false}"

# Pare-feu
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# SSL (Let's Encrypt)
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
FQDN="${FQDN:-}"
EMAIL="${EMAIL:-}"

# Hôte de la base de données
CONFIGURE_DBHOST="${CONFIGURE_DBHOST:-false}"
CONFIGURE_DB_FIREWALL="${CONFIGURE_DB_FIREWALL:-false}"
MYSQL_DBHOST_HOST="${MYSQL_DBHOST_HOST:-127.0.0.1}"
MYSQL_DBHOST_USER="${MYSQL_DBHOST_USER:-pterodactyluser}"
MYSQL_DBHOST_PASSWORD="${MYSQL_DBHOST_PASSWORD:-}"

if [[ $CONFIGURE_DBHOST == true && -z "${MYSQL_DBHOST_PASSWORD}" ]]; then
  error "Le mot de passe de l'utilisateur de la base de données MySQL est requis"
  exit 1
fi

# ----------- Fonctions d'installation ----------- #

enable_services() {
  [ "$INSTALL_MARIADB" == true ] && systemctl enable mariadb
  [ "$INSTALL_MARIADB" == true ] && systemctl start mariadb
  systemctl start docker
  systemctl enable docker
}

dep_install() {
  output "Installation des dépendances pour $OS $OS_VER..."

  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    install_packages "ca-certificates gnupg lsb-release"

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    ;;

  rocky | almalinux)
    install_packages "dnf-utils"
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "epel-release"

    install_packages "device-mapper-persistent-data lvm2"
    ;;
  esac

  # Met à jour les nouveaux dépôts
  update_repos

  # Installe les dépendances
  install_packages "docker-ce docker-ce-cli containerd.io"

  # Installe mariadb si nécessaire
  [ "$INSTALL_MARIADB" == true ] && install_packages "mariadb-server"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot"

  enable_services

  success "Dépendances installées !"
}

ptdl_dl() {
  echo "* Téléchargement des Pterodactyl Wings.. "

  mkdir -p /etc/pterodactyl
  curl -L -o /usr/local/bin/wings "$WINGS_DL_BASE_URL$ARCH"

  chmod u+x /usr/local/bin/wings

  success "Pterodactyl Wings téléchargé avec succès"
}

systemd_file() {
  output "Installation du service systemd.."

  curl -o /etc/systemd/system/wings.service "$GITHUB_URL"/configs/wings.service
  systemctl daemon-reload
  systemctl enable wings

  success "Service systemd installé !"
}

firewall_ports() {
  output "Ouverture des ports 22 (SSH), 8080 (Port Wings), 2022 (Port SFTP Wings)"

  [ "$CONFIGURE_LETSENCRYPT" == true ] && firewall_allow_ports "80 443"
  [ "$CONFIGURE_DB_FIREWALL" == true ] && firewall_allow_ports "3306"

  firewall_allow_ports "22 8080 2022"

  success "Ports du pare-feu ouverts !"
}

letsencrypt() {
  FAILED=false

  output "Configuration de Let's Encrypt.."

  # Si l'utilisateur a nginx
  systemctl stop nginx || true

  # Obtenir le certificat
  certbot certonly --no-eff-email --email "$EMAIL" --standalone -d "$FQDN" || FAILED=true

  systemctl start nginx || true

  # Vérifie si cela a réussi
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "Le processus d'obtention du certificat Let's Encrypt a échoué !"
  else
    success "Le processus d'obtention du certificat Let's Encrypt a réussi !"
  fi
}

configure_mysql() {
  output "Configuration de MySQL.."

  create_db_user "$MYSQL_DBHOST_USER" "$MYSQL_DBHOST_PASSWORD" "$MYSQL_DBHOST_HOST"
  grant_all_privileges "*" "$MYSQL_DBHOST_USER" "$MYSQL_DBHOST_HOST"

  if [ "$MYSQL_DBHOST_HOST" != "127.0.0.1" ]; then
    echo "* Modification de l'adresse de liaison de MySQL.."

    case "$OS" in
    debian | ubuntu)
      sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mariadb.conf.d/50-server.cnf
      ;;
    rocky | almalinux)
      sed -ne 's/^#bind-address=0.0.0.0$/bind-address=0.0.0.0/' /etc/my.cnf.d/mariadb-server.cnf
      ;;
    esac

    systemctl restart mysqld
  fi

  success "MySQL configuré !"
}

# --------------- Fonctions principales --------------- #

perform_install() {
  output "Installation des ailes de Pterodactyl.."
  dep_install
  ptdl_dl
  systemd_file
  [ "$CONFIGURE_DBHOST" == true ] && configure_mysql
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  return 0
}

# ---------------- Installation ---------------- #

perform_install
