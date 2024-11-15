#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                    #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>             #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le modifier #
#   selon les termes de la Licence publique générale GNU telle que publiée par la    #
#   Free Software Foundation, version 3 de la licence ou ultérieure.                 #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                      #
#   mais SANS AUCUNE GARANTIE ; sans même la garantie implicite de                   #
#   QUALITÉ MARCHANDE ou d'ADÉQUATION À UN USAGE PARTICULIER. Voir la               #
#   Licence publique générale GNU pour plus de détails.                              #
#                                                                                    #
#   Vous devriez avoir reçu une copie de la Licence publique générale GNU           #
#   avec ce programme.  Sinon, consultez <https://www.gnu.org/licenses/>.            #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet officiel Pterodactyl.                         #
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

RM_PANEL="${RM_PANEL:-true}"
RM_WINGS="${RM_WINGS:-true}"

# ---------- Fonctions de désinstallation ---------- #

rm_panel_files() {
  output "Suppression des fichiers du panel..."
  rm -rf /var/www/pterodactyl /usr/local/bin/composer
  [ "$OS" != "centos" ] && unlink /etc/nginx/sites-enabled/pterodactyl.conf
  [ "$OS" != "centos" ] && rm -f /etc/nginx/sites-available/pterodactyl.conf
  [ "$OS" != "centos" ] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  [ "$OS" == "centos" ] && rm -f /etc/nginx/conf.d/pterodactyl.conf
  systemctl restart nginx
  success "Fichiers du panel supprimés."
}

rm_docker_containers() {
  output "Suppression des conteneurs et images Docker..."

  docker system prune -a -f

  success "Conteneurs et images Docker supprimés."
}

rm_wings_files() {
  output "Suppression des fichiers wings..."

  # Arrête et supprime le service wings
  systemctl disable --now wings
  rm -rf /etc/systemd/system/wings.service

  rm -rf /etc/pterodactyl /usr/local/bin/wings /var/lib/pterodactyl
  success "Fichiers wings supprimés."
}

rm_services() {
  output "Suppression des services..."
  systemctl disable --now pteroq
  rm -rf /etc/systemd/system/pteroq.service
  case "$OS" in
  debian | ubuntu)
    systemctl disable --now redis-server
    ;;
  centos)
    systemctl disable --now redis
    systemctl disable --now php-fpm
    rm -rf /etc/php-fpm.d/www-pterodactyl.conf
    ;;
  esac
  success "Services supprimés."
}

rm_cron() {
  output "Suppression des tâches cron..."
  crontab -l | grep -vF "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | crontab -
  success "Tâches cron supprimées."
}

rm_database() {
  output "Suppression de la base de données..."
  valid_db=$(mysql -u root -e "SELECT schema_name FROM information_schema.schemata;" | grep -v -E -- 'schema_name|information_schema|performance_schema|mysql')
  warning "Attention ! Cette base de données sera supprimée !"
  if [[ "$valid_db" == *"panel"* ]]; then
    echo -n "* Une base de données appelée panel a été détectée. S'agit-il de la base de données de Pterodactyl ? (y/N) : "
    read -r is_panel
    if [[ "$is_panel" =~ [Yy] ]]; then
      DATABASE=panel
    else
      print_list "$valid_db"
    fi
  else
    print_list "$valid_db"
  fi
  while [ -z "$DATABASE" ] || [[ $valid_db != *"$database_input"* ]]; do
    echo -n "* Choisissez la base de données du panel (pour ignorer, ne rien saisir) : "
    read -r database_input
    if [[ -n "$database_input" ]]; then
      DATABASE="$database_input"
    else
      break
    fi
  done
  [[ -n "$DATABASE" ]] && mysql -u root -e "DROP DATABASE $DATABASE;"
  # Exclure les noms d'utilisateur User et root (Espérons que personne n'utilise le nom d'utilisateur User)
  output "Suppression de l'utilisateur de la base de données..."
  valid_users=$(mysql -u root -e "SELECT user FROM mysql.user;" | grep -v -E -- 'user|root')
  warning "Attention ! Cet utilisateur sera supprimé !"
  if [[ "$valid_users" == *"pterodactyl"* ]]; then
    echo -n "* Un utilisateur appelé pterodactyl a été détecté. S'agit-il de l'utilisateur de Pterodactyl ? (y/N) : "
    read -r is_user
    if [[ "$is_user" =~ [Yy] ]]; then
      DB_USER=pterodactyl
    else
      print_list "$valid_users"
    fi
  else
    print_list "$valid_users"
  fi
  while [ -z "$DB_USER" ] || [[ $valid_users != *"$user_input"* ]]; do
    echo -n "* Choisissez l'utilisateur du panel (pour ignorer, ne rien saisir) : "
    read -r user_input
    if [[ -n "$user_input" ]]; then
      DB_USER=$user_input
    else
      break
    fi
  done
  [[ -n "$DB_USER" ]] && mysql -u root -e "DROP USER $DB_USER@'127.0.0.1';"
  mysql -u root -e "FLUSH PRIVILEGES;"
  success "Removed database and database user."
}

# --------------- Main functions --------------- #

perform_uninstall() {
  [ "$RM_PANEL" == true ] && rm_panel_files
  [ "$RM_PANEL" == true ] && rm_cron
  [ "$RM_PANEL" == true ] && rm_database
  [ "$RM_PANEL" == true ] && rm_services
  [ "$RM_WINGS" == true ] && rm_docker_containers
  [ "$RM_WINGS" == true ] && rm_wings_files

  return 0
}

# ------------------ Uninstall ----------------- #

perform_uninstall
