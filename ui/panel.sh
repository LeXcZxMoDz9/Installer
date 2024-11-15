#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                    #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>            #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le modifier #
#   selon les termes de la Licence publique générale GNU telle que publiée par la    #
#   Free Software Foundation, soit la version 3 de la Licence ou                      #
#   (à votre gré) toute version ultérieure.                                          #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                       #
#   mais SANS AUCUNE GARANTIE ; sans même la garantie tacite de                      #
#   QUALITÉ MARCHANDE ou d'ADAPTATION À UN USAGE PARTICULIER. Voir                   #
#   la Licence publique générale GNU pour plus de détails.                           #
#                                                                                    #
#   Vous devriez avoir reçu une copie de la Licence publique générale GNU            #
#   avec ce programme. Si ce n'est pas le cas, consultez                              #
#   <https://www.gnu.org/licenses/>.                                                 #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet Pterodactyl officiel.                         #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

# Vérifier si le script est chargé, le charger si ce n'est pas le cas ou échouer sinon.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERREUR : Impossible de charger le script lib" && exit 1
fi

# ------------------ Variables ----------------- #

# Nom de domaine / IP
export FQDN=""

# Identifiants MySQL par défaut
export MYSQL_DB=""
export MYSQL_USER=""
export MYSQL_PASSWORD=""

# Environnement
export timezone=""
export email=""

# Compte administrateur initial
export user_email=""
export user_username=""
export user_firstname=""
export user_lastname=""
export user_password=""

# Supposer SSL, récupérera une configuration différente si vrai
export ASSUME_SSL=false
export CONFIGURE_LETSENCRYPT=false

# Pare-feu
export CONFIGURE_FIREWALL=false

# ------------ Fonctions de saisie utilisateur ------------ #

ask_letsencrypt() {
  if [ "$CONFIGURE_UFW" == false ] && [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
    warning "Let's Encrypt nécessite les ports 80/443 ouverts ! Vous avez choisi de ne pas configurer automatiquement le pare-feu ; utilisez cela à vos risques et périls (si les ports 80/443 sont fermés, le script échouera) !"
  fi

  echo -e -n "* Voulez-vous configurer automatiquement HTTPS avec Let's Encrypt ? (o/N) : "
  read -r CONFIRM_SSL

  if [[ "$CONFIRM_SSL" =~ [Oo] ]]; then
    CONFIGURE_LETSENCRYPT=true
    ASSUME_SSL=false
  fi
}
ask_assume_ssl() {
  output "Let's Encrypt ne sera pas configuré automatiquement par ce script (l'utilisateur a choisi de ne pas le faire)."
  output "Vous pouvez 'supposer' Let's Encrypt, ce qui signifie que le script téléchargera une configuration nginx configurée pour utiliser un certificat Let's Encrypt, mais le script ne l'obtiendra pas pour vous."
  output "Si vous supposez SSL et ne récupérez pas le certificat, votre installation ne fonctionnera pas."
  echo -n "* Supposer SSL ou non ? (o/N) : "
  read -r ASSUME_SSL_INPUT

  [[ "$ASSUME_SSL_INPUT" =~ [Oo] ]] && ASSUME_SSL=true
  true
}

check_FQDN_SSL() {
  if [[ $(invalid_ip "$FQDN") == 1 && $FQDN != 'localhost' ]]; then
    SSL_AVAILABLE=true
  else
    warning "* Let's Encrypt ne sera pas disponible pour les adresses IP."
    output "Pour utiliser Let's Encrypt, vous devez utiliser un nom de domaine valide."
  fi
}

main() {
  # Vérifier s'il existe déjà une installation détectée
  if [ -d "/var/www/pterodactyl" ]; then
    warning "Le script a détecté que vous avez déjà un panneau Pterodactyl sur votre système ! Vous ne pouvez pas exécuter le script plusieurs fois, cela échouera !"
    echo -e -n "* Êtes-vous sûr de vouloir continuer ? (o/N) : "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Oo] ]]; then
      error "Installation abandonnée !"
      exit 1
    fi
  fi

  welcome "panel"

  check_os_x86_64

  # Définir les identifiants de la base de données
  output "Configuration de la base de données."
  output ""
  output "Ce seront les identifiants utilisés pour la communication entre la base de données MySQL"
  output "et le panneau. Vous n'avez pas besoin de créer la base de données"
  output "avant d'exécuter ce script, le script le fera pour vous."
  output ""

  MYSQL_DB="-"
  while [[ "$MYSQL_DB" == *"-"* ]]; do
    required_input MYSQL_DB "Nom de la base de données (panel) : " "" "panel"
    [[ "$MYSQL_DB" == *"-"* ]] && error "Le nom de la base de données ne peut pas contenir de tirets"
  done

  MYSQL_USER="-"
  while [[ "$MYSQL_USER" == *"-"* ]]; do
    required_input MYSQL_USER "Nom d'utilisateur de la base de données (pterodactyl) : " "" "pterodactyl"
    [[ "$MYSQL_USER" == *"-"* ]] && error "L'utilisateur de la base de données ne peut pas contenir de tirets"
  done

  # Saisie du mot de passe MySQL
  rand_pw=$(gen_passwd 64)
  password_input MYSQL_PASSWORD "Mot de passe (appuyez sur Entrée pour utiliser un mot de passe généré aléatoirement) : " "Le mot de passe MySQL ne peut pas être vide" "$rand_pw"

  readarray -t valid_timezones <<<"$(curl -s "$GITHUB_URL"/configs/valid_timezones.txt)"
  output "Liste des fuseaux horaires valides ici $(hyperlink "https://www.php.net/manual/en/timezones.php")"

  while [ -z "$timezone" ]; do
    echo -n "* Sélectionnez le fuseau horaire [Europe/Paris] : "
    read -r timezone_input

    array_contains_element "$timezone_input" "${valid_timezones[@]}" && timezone="$timezone_input"
    [ -z "$timezone_input" ] && timezone="Europe/Paris" # parce que baguette !
  done

  email_input email "Fournissez l'adresse e-mail qui sera utilisée pour configurer Let's Encrypt et Pterodactyl : " "L'e-mail ne peut pas être vide ou invalide"

  # Compte administrateur initial
  email_input user_email "Adresse e-mail du compte administrateur initial : " "L'e-mail ne peut pas être vide ou invalide"
  required_input user_username "Nom d'utilisateur du compte administrateur initial : " "Le nom d'utilisateur ne peut pas être vide"
  required_input user_firstname "Prénom du compte administrateur initial : " "Le prénom ne peut pas être vide"
  required_input user_lastname "Nom de famille du compte administrateur initial : " "Le nom ne peut pas être vide"
  password_input user_password "Mot de passe du compte administrateur initial : " "Le mot de passe ne peut pas être vide"

  print_brake 72

  # Définir FQDN
  while [ -z "$FQDN" ]; do
    echo -n "* Définir le FQDN de ce panneau (panel.example.com) : "
    read -r FQDN
    [ -z "$FQDN" ] && error "Le FQDN ne peut pas être vide"
  done

  # Vérifier si SSL est disponible
  check_FQDN_SSL

  # Demander si un pare-feu est nécessaire
  ask_firewall CONFIGURE_FIREWALL

  # Poser des questions sur SSL uniquement s'il est disponible
  if [ "$SSL_AVAILABLE" == true ]; then
    # Demander si Let's Encrypt est nécessaire
    ask_letsencrypt
    # Si c'est déjà vrai, cela devrait être évident
    [ "$CONFIGURE_LETSENCRYPT" == false ] && ask_assume_ssl
  fi

  # Vérifier le FQDN si l'utilisateur a choisi de supposer SSL ou de configurer Let's Encrypt
  [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] && bash <(curl -s "$GITHUB_URL"/lib/verify-fqdn.sh) "$FQDN"

  # Résumé
  summary

  # Confirmer l'installation
  echo -e -n "\n* Configuration initiale terminée. Continuer avec l'installation ? (o/N) : "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Oo] ]]; then
    run_installer "panel"
  else
    error "Installation abandonnée."
    exit 1
  fi
}

summary() {
  print_brake 62
  output "Panneau Pterodactyl $PTERODACTYL_PANEL_VERSION avec nginx sur $OS"
  output "Nom de la base de données : $MYSQL_DB"
  output "Utilisateur de la base de données : $MYSQL_USER"
  output "Mot de passe de la base de données : (censuré)"
  output "Fuseau horaire : $timezone"
  output "Email : $email"
  output "Email de l'utilisateur : $user_email"
  output "Nom d'utilisateur : $user_username"
  output "Prénom : $user_firstname"
  output "Nom : $user_lastname"
  output "Mot de passe de l'utilisateur : (censuré)"
  output "Nom d'hôte/FQDN : $FQDN"
  output "Configurer le pare-feu ? $CONFIGURE_FIREWALL"
  output "Configurer Let's Encrypt ? $CONFIGURE_LETSENCRYPT"
  output "Supposer SSL ? $ASSUME_SSL"
  print_brake 62
}

goodbye() {
  print_brake 62
  output "Installation du panneau terminée"
  output ""

  [ "$CONFIGURE_LETSENCRYPT" == true ] && output "Votre panneau devrait être accessible depuis $(hyperlink "$FQDN")"
  [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && output "Vous avez choisi d'utiliser SSL, mais pas via Let's Encrypt automatiquement. Votre panneau ne fonctionnera pas tant que SSL ne sera pas configuré."
  [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && output "Votre panneau devrait être accessible depuis $(hyperlink "$FQDN")"

  output ""
  output "L'installation utilise nginx sur $OS"
  output "Merci d'avoir utilisé ce script."
  [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Remarque${COLOR_NC} : Si vous n'avez pas configuré le pare-feu : les ports 80/443 (HTTP/HTTPS) doivent être ouverts !"
  print_brake 62
}

# Exécuter le script
main
goodbye
