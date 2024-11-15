#!/bin/bash

set -e

# Vérifie si le script est chargé, le charge sinon échoue.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERREUR : Impossible de charger le script lib" && exit 1
fi

# ------------------ Variables ----------------- #

# Nom de domaine / IP
FQDN="${FQDN:-localhost}"

# Informations de connexion MySQL par défaut
MYSQL_DB="${MYSQL_DB:-panel}"
MYSQL_USER="${MYSQL_USER:-pterodactyl}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"

# Environnement
timezone="${timezone:-Europe/Stockholm}"

# Supposer SSL, récupère une configuration différente si vrai
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"

# Pare-feu
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# Doit être attribué pour fonctionner, pas de valeurs par défaut
email="${email:-}"
user_email="${user_email:-}"
user_username="${user_username:-}"
user_firstname="${user_firstname:-}"
user_lastname="${user_lastname:-}"
user_password="${user_password:-}"

if [[ -z "${email}" ]]; then
  error "L'email est requis"
  exit 1
fi

if [[ -z "${user_email}" ]]; then
  error "L'email de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_username}" ]]; then
  error "Le nom d'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_firstname}" ]]; then
  error "Le prénom de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_lastname}" ]]; then
  error "Le nom de famille de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_password}" ]]; then
  error "Le mot de passe de l'utilisateur est requis"
  exit 1
fi
# --------- Fonctions principales d'installation -------- #

install_composer() {
  output "Installation de Composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installé !"
}

ptdl_dl() {
  output "Téléchargement des fichiers du panneau Pterodactyl .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Fichiers du panneau Pterodactyl téléchargés !"
}

install_composer_deps() {
  output "Installation des dépendances de Composer.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Dépendances de Composer installées !"
}

# Configuration de l'environnement
configure() {
  output "Configuration de l'environnement.."

  local app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  # Générer la clé de chiffrement
  php artisan key:generate --force

  # Remplir automatiquement environment:setup
  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true

  # Remplir automatiquement environment:database avec les identifiants
  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  # Configurer la base de données
  php artisan migrate --seed --force

  # Créer le compte utilisateur
  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  success "Environnement configuré !"
}

# Définir les permissions de dossier appropriées en fonction du système d'exploitation et du serveur web
set_folder_permissions() {
  # Si le système d'exploitation est Ubuntu ou Debian, nous faisons cela
  case "$OS" in
  debian | ubuntu)
    chown -R www-data:www-data ./*
    ;;
  rocky | almalinux)
    chown -R nginx:nginx ./*
    ;;
  esac
}

insert_cronjob() {
  output "Installation de la tâche cron.. "

  crontab -l | {
    cat
    output "* * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -

  success "Tâche cron installée !"
}

install_pteroq() {
  output "Installation du service pteroq.."

  curl -o /etc/systemd/system/pteroq.service "$GITHUB_URL"/configs/pteroq.service

  case "$OS" in
  debian | ubuntu)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
    ;;
  rocky | almalinux)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
    ;;
  esac

  systemctl enable pteroq.service
  systemctl start pteroq

  success "Service pteroq installé !"
}

# ------ Fonctions d'installation spécifiques à l'OS ------- #

enable_services() {
  case "$OS" in
  ubuntu | debian)
    systemctl enable redis-server
    systemctl start redis-server
    ;;
  rocky | almalinux)
    systemctl enable redis
    systemctl start redis
    ;;
  esac
  systemctl enable nginx
  systemctl enable mariadb
  systemctl start mariadb
}
selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # Ces commandes peuvent échouer OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

php_fpm_conf() {
  curl -o /etc/php-fpm.d/www-pterodactyl.conf "$GITHUB_URL"/configs/www-pterodactyl.conf
  systemctl enable php-fpm
  systemctl start php-fpm
}

ubuntu_dep() {
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg"
  add-apt-repository universe -y
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
}

debian_dep() {
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"
  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

alma_rocky_dep() {
  install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
  dnf module enable -y php:remi-8.3
}

dep_install() {
  output "Installing dependencies for $OS $OS_VER..."

  update_repos
  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    [ "$OS" == "debian" ] && debian_dep
    update_repos
    install_packages "php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
      mariadb-common mariadb-server mariadb-client \
      nginx \
      redis-server \
      zip unzip tar \
      git cron"
    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"
    ;;
  rocky | almalinux)
    alma_rocky_dep
    install_packages "php php-{common,fpm,cli,json,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix} \
      mariadb mariadb-server \
      nginx \
      redis \
      zip unzip tar \
      git cronie"
    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"
    selinux_allow
    php_fpm_conf
    ;;
  esac

  enable_services
  success "Dependencies installed!"
}

# --------------- Autres fonctions -------------- #

firewall_ports() {
  output "Ouverture des ports : 22 (SSH), 80 (HTTP) et 443 (HTTPS)"

  firewall_allow_ports "22 80 443"

  success "Ports du pare-feu ouverts !"
}
letsencrypt() {
  FAILED=false

  output "Configuration de Let's Encrypt..."

  # Obtenir le certificat
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Vérifier si cela a réussi
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "Le processus d'obtention d'un certificat Let's Encrypt a échoué !"
    echo -n "* Toujours supposer SSL ? (y/N) : "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  else
    success "Le processus d'obtention d'un certificat Let's Encrypt a réussi !"
  fi
}

# ------ Fonctions de configuration du serveur Web ------- #

configure_nginx() {
  PHP_SOCKET="/run/php/php8.3-fpm.sock"
  CONFIG_PATH_AVAIL="/etc/nginx/sites-available"
  CONFIG_PATH_ENABL="/etc/nginx/sites-enabled"
  
  rm -rf "$CONFIG_PATH_ENABL"/default

  curl -o "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$GITHUB_URL"/configs/nginx.conf
  sed -i -e "s@<domain>@${FQDN}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf
  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf
  ln -sf "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$CONFIG_PATH_ENABL"/pterodactyl.conf
  systemctl restart nginx
  success "Nginx configured!"
  }

# --------------- Fonctions principales --------------- #

perform_install() {
  output "Démarrage de l'installation.. cela peut prendre un certain temps !"
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  return 0
}

# ------------------- Installation ------------------ #

perform_install
