#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                     #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>              #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le           #
#   modifier selon les termes de la Licence publique générale GNU telle que          #
#   publiée par la Free Software Foundation, soit la version 3 de la Licence         #
#   ou toute version ultérieure.                                                     #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                       #
#   mais SANS AUCUNE GARANTIE, même sans la garantie implicite de                    #
#   QUALITÉ MARCHANDE ou d'ADÉQUATION À UN USAGE PARTICULIER. Consultez              #
#   la Licence publique générale GNU pour plus de détails.                           #
#                                                                                    #
#   Vous devriez avoir reçu une copie de la Licence publique générale GNU            #
#   avec ce programme. Si ce n'est pas le cas, consultez                             #
#   <https://www.gnu.org/licenses/>.                                                 #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet officiel Pterodactyl.                        #
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

# Installer mariadb
export INSTALL_MARIADB=false

# Pare-feu
export CONFIGURE_FIREWALL=false

# SSL (Let's Encrypt)
export CONFIGURE_LETSENCRYPT=false
export FQDN=""
export EMAIL=""

# Hôte de la base de données
export CONFIGURE_DBHOST=false
export CONFIGURE_DB_FIREWALL=false
export MYSQL_DBHOST_HOST="127.0.0.1"
export MYSQL_DBHOST_USER="pterodactyluser"
export MYSQL_DBHOST_PASSWORD=""

# ------------ Fonctions de saisie utilisateur ------------ #

ask_letsencrypt() {
  if [ "$CONFIGURE_UFW" == false ] && [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
    warning "Let's Encrypt nécessite l'ouverture des ports 80/443 ! Vous avez choisi de ne pas configurer automatiquement le pare-feu ; utilisez cela à vos risques et périls (si les ports 80/443 sont fermés, le script échouera) !"
  fi

  warning "Vous ne pouvez pas utiliser Let's Encrypt avec votre nom d'hôte comme adresse IP ! Il doit s'agir d'un FQDN (par exemple, node.example.org)."

  echo -e -n "* Voulez-vous configurer automatiquement HTTPS avec Let's Encrypt ? (o/N) : "
  read -r CONFIRM_SSL

  if [[ "$CONFIRM_SSL" =~ [Oo] ]]; then
    CONFIGURE_LETSENCRYPT=true
  fi
}

ask_database_user() {
  echo -n "* Voulez-vous configurer automatiquement un utilisateur pour les hôtes de base de données ? (o/N) : "
  read -r CONFIRM_DBHOST

  if [[ "$CONFIRM_DBHOST" =~ [Oo] ]]; then
    ask_database_external
    CONFIGURE_DBHOST=true
  fi
}

ask_database_external() {
  echo -n "* Voulez-vous configurer MySQL pour qu'il soit accessible de l'extérieur ? (o/N) : "
  read -r CONFIRM_DBEXTERNAL

  if [[ "$CONFIRM_DBEXTERNAL" =~ [Oo] ]]; then
    echo -n "* Entrez l'adresse du panneau (vide pour n'importe quelle adresse) : "
    read -r CONFIRM_DBEXTERNAL_HOST
    if [ "$CONFIRM_DBEXTERNAL_HOST" == "" ]; then
      MYSQL_DBHOST_HOST="%"
    else
      MYSQL_DBHOST_HOST="$CONFIRM_DBEXTERNAL_HOST"
    fi
    [ "$CONFIGURE_FIREWALL" == true ] && ask_database_firewall
    return 0
  fi
}

ask_database_firewall() {
  warning "Autoriser le trafic entrant sur le port 3306 (MySQL) peut potentiellement présenter un risque de sécurité, sauf si vous savez ce que vous faites !"
  echo -n "* Voulez-vous autoriser le trafic entrant sur le port 3306 ? (o/N) : "
  read -r CONFIRM_DB_FIREWALL
  if [[ "$CONFIRM_DB_FIREWALL" =~ [Oo] ]]; then
    CONFIGURE_DB_FIREWALL=true
  fi
}

###########################
## FONCTIONS PRINCIPALES ##
###########################

main() {
  # Vérifie si nous pouvons détecter une installation existante
  if [ -d "/etc/pterodactyl" ]; then
    warning "Le script a détecté que vous avez déjà Pterodactyl wings sur votre système ! Vous ne pouvez pas exécuter le script plusieurs fois, cela échouera !"
    echo -e -n "* Êtes-vous sûr de vouloir continuer ? (o/N) : "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Oo] ]]; then
      error "Installation abandonnée !"
      exit 1
    fi
  fi

  welcome "wings"

  check_virt

  echo "* "
  echo "* L'installateur installera Docker, les dépendances requises pour Wings"
  echo "* ainsi que Wings lui-même. Mais il est toujours nécessaire de créer le nœud"
  echo "* sur le panneau, puis de placer le fichier de configuration sur le nœud manuellement après"
  echo "* que l'installation soit terminée. En savoir plus sur ce processus sur le"
  echo "* documentation officielle : $(hyperlink 'https://pterodactyl.io/wings/1.0/installing.html#configure')"
  echo "* "
  echo -e "* ${COLOR_RED}Note${COLOR_NC} : ce script ne démarrera pas automatiquement Wings (installera le service systemd, ne le démarrera pas)."
  echo -e "* ${COLOR_RED}Note${COLOR_NC} : ce script n'activera pas le swap (pour docker)."
  print_brake 42

  ask_firewall CONFIGURE_FIREWALL

  ask_database_user

  if [ "$CONFIGURE_DBHOST" == true ]; then
    type mysql >/dev/null 2>&1 && HAS_MYSQL=true || HAS_MYSQL=false

    if [ "$HAS_MYSQL" == false ]; then
      INSTALL_MARIADB=true
    fi

    MYSQL_DBHOST_USER="-"
    while [[ "$MYSQL_DBHOST_USER" == *"-"* ]]; do
      required_input MYSQL_DBHOST_USER "Nom d'utilisateur de l'hôte de la base de données (pterodactyluser) : " "" "pterodactyluser"
      [[ "$MYSQL_DBHOST_USER" == *"-"* ]] && error "L'utilisateur de la base de données ne peut pas contenir de tirets"
    done

    password_input MYSQL_DBHOST_PASSWORD "Mot de passe de l'hôte de la base de données : " "Le mot de passe ne peut pas être vide"
  fi

  ask_letsencrypt

  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    while [ -z "$FQDN" ]; do
      echo -n "* Définir le FQDN à utiliser pour Let's Encrypt (node.example.com) : "
      read -r FQDN

      ASK=false

      [ -z "$FQDN" ] && error "Le FQDN ne peut pas être vide" # vérifie si le FQDN est vide
      bash <(curl -s "$GITHUB_URL"/lib/verify-fqdn.sh) "$FQDN" || ASK=true # vérifie si le FQDN est valide
      [ -d "/etc/letsencrypt/live/$FQDN/" ] && error "Un certificat avec ce FQDN existe déjà !" && ASK=true # vérifie si le certificat existe

      [ "$ASK" == true ] && FQDN=""
      [ "$ASK" == true ] && echo -e -n "* Voulez-vous toujours configurer automatiquement HTTPS avec Let's Encrypt ? (o/N) : "
      [ "$ASK" == true ] && read -r CONFIRM_SSL

      if [[ ! "$CONFIRM_SSL" =~ [Oo] ]] && [ "$ASK" == true ]; then
        CONFIGURE_LETSENCRYPT=false
        FQDN=""
      fi
    done
  fi

  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    # Définir EMAIL
    while ! valid_email "$EMAIL"; do
      echo -n "* Entrez une adresse e-mail pour Let's Encrypt : "
      read -r EMAIL

      valid_email "$EMAIL" || error "L'adresse e-mail ne peut pas être vide ou invalide"
    done
  fi

  echo -n "* Continuer avec l'installation ? (o/N) : "

  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Oo] ]]; then
    run_installer "wings"
  else
    error "Installation abandonnée."
    exit 1
  fi
}

function goodbye {
  echo ""
  print_brake 70
  echo "* Installation de Wings terminée"
  echo "*"
  echo "* Pour continuer, vous devez configurer Wings pour qu'il fonctionne avec votre panneau"
  echo "* Veuillez vous référer au guide officiel, $(hyperlink 'https://pterodactyl.io/wings/1.0/installing.html#configure')"
  echo "* "
  echo "* Vous pouvez soit copier le fichier de configuration du panneau manuellement vers /etc/pterodactyl/config.yml"
  echo "* ou, vous pouvez utiliser le bouton \"déploiement automatique\" du panneau et simplement coller la commande dans ce terminal"
  echo "* "
  echo "* Vous pouvez ensuite démarrer Wings manuellement pour vérifier qu'il fonctionne"
  echo "*"
  echo "* sudo wings"
  echo "*"
  echo "* Une fois que vous avez vérifié que cela fonctionne, utilisez CTRL+C puis démarrez Wings en tant que service (fonctionne en arrière-plan)"
  echo "*"
  echo "* systemctl start wings"
  echo "*"
  echo -e "* ${COLOR_RED}Note${COLOR_NC} : Il est recommandé d'activer le swap (pour Docker, en savoir plus dans la documentation officielle)."
  [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC} : Si vous n'avez pas configuré votre pare-feu, les ports 8080 et 2022 doivent être ouverts."
  print_brake 70
  echo ""
}

# Exécution du script
main
goodbye