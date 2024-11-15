#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                    #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>            #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le          #
#   modifier selon les termes de la Licence publique générale GNU telle que          #
#   publiée par la Free Software Foundation, soit la version 3 de la Licence         #
#   ou toute version ultérieure.                                                    #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                      #
#   mais SANS AUCUNE GARANTIE, même sans la garantie implicite de                   #
#   QUALITÉ MARCHANDE ou d'ADÉQUATION À UN USAGE PARTICULIER. Consultez              #
#   la Licence publique générale GNU pour plus de détails.                           #
#                                                                                    #
#   Vous devriez avoir reçu une copie de la Licence publique générale GNU           #
#   avec ce programme. Si ce n'est pas le cas, consultez                              #
#   <https://www.gnu.org/licenses/>.                                                 #
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

export RM_PANEL=false
export RM_WINGS=false

# --------------- Fonctions principales --------------- #

main() {
  welcome ""

  if [ -d "/var/www/pterodactyl" ]; then
    output "Installation du panneau détectée."
    echo -e -n "* Voulez-vous supprimer le panneau ? (o/N) : "
    read -r RM_PANEL_INPUT
    [[ "$RM_PANEL_INPUT" =~ [Oo] ]] && RM_PANEL=true
  fi

  if [ -d "/etc/pterodactyl" ]; then
    output "Installation de Wings détectée."
    warning "Cela supprimera tous les serveurs !"
    echo -e -n "* Voulez-vous supprimer Wings (daemon) ? (o/N) : "
    read -r RM_WINGS_INPUT
    [[ "$RM_WINGS_INPUT" =~ [Oo] ]] && RM_WINGS=true
  fi

  if [ "$RM_PANEL" == false ] && [ "$RM_WINGS" == false ]; then
    error "Rien à désinstaller !"
    exit 1
  fi

  summary

  # Confirme la désinstallation
  echo -e -n "* Continuer avec la désinstallation ? (o/N) : "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Oo] ]]; then
    run_installer "uninstall"
  else
    error "Désinstallation abandonnée."
    exit 1
  fi
}

summary() {
  print_brake 30
  output "Désinstaller le panneau ? $RM_PANEL"
  output "Désinstaller Wings ? $RM_WINGS"
  print_brake 30
}

goodbye() {
  print_brake 62
  [ "$RM_PANEL" == true ] && output "Désinstallation du panneau terminée"
  [ "$RM_WINGS" == true ] && output "Désinstallation de Wings terminée"
  output "Merci d'avoir utilisé ce script."
  print_brake 62
}

main
goodbye