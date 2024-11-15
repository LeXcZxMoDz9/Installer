#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                     #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>              #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le modifier  #
#   selon les termes de la Licence publique générale GNU telle que publiée par la    #
#   Free Software Foundation, soit la version 3 de la Licence ou                     #
#   (à votre gré) toute version ultérieure.                                          #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile,                       #
#   mais SANS AUCUNE GARANTIE ; sans même la garantie tacite de                      #
#   QUALITÉ MARCHANDE ou d'ADAPTATION À UN USAGE PARTICULIER. Voir                   #
#   la Licence publique générale GNU pour plus de détails.                           #
#                                                                                    #
#   Vous devriez avoir reçu une copie de la Licence publique générale GNU            #
#   avec ce programme. Si ce n'est pas le cas, consultez                             #
#   <https://www.gnu.org/licenses/>.                                                 #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet Pterodactyl officiel.                        #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="v1.0.0"
export SCRIPT_RELEASE="v1.0.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/LeXcZxMoDz9/pterodactyl-installer"

CHEMIN_LOG="/var/log/pterodactyl-installer.log"

# Vérifier la présence de curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl est requis pour que ce script fonctionne."
  echo "* installez-le via apt (Debian et dérivés) ou yum/dnf (CentOS)"
  exit 1
fi

# Supprimer toujours lib.sh avant de le télécharger
rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/"$GITHUB_SOURCE"/lib/lib.sh
# shellcheck source=lib/lib.sh
source /tmp/lib.sh

executer() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >>$CHEMIN_LOG

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="master" && export SCRIPT_RELEASE="canary"
  update_lib_source
  run_ui "${1//_canary/}" |& tee -a $CHEMIN_LOG

  if [[ -n $2 ]]; then
    echo -e -n "* Installation de $1 terminée. Voulez-vous procéder à l'installation de $2 ? (o/N) : "
    read -r CONFIRMATION
    if [[ "$CONFIRMATION" =~ [Oo] ]]; then
      executer "$2"
    else
      error "Installation de $2 annulée."
      exit 1
    fi
  fi
}

welcome ""

termine=false
while [ "$termine" == false ]; do
  options=(
    "Installer le panneau"
    "Installer Wings"
    "Installer à la fois [0] et [1] sur la même machine (le script Wings s'exécute après le panneau)"
    # "Désinstaller le panneau ou Wings\n"

    "Installer le panneau avec la version canary du script (les versions dans master, peuvent être cassées !)"
    "Installer Wings avec la version canary du script (les versions dans master, peuvent être cassées !)"
    "Installer à la fois [3] et [4] sur la même machine (le script Wings s'exécute après le panneau)"
    "Désinstaller le panneau ou Wings avec la version canary du script (les versions dans master, peuvent être cassées !)"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    # "uninstall"

    "panel_canary"
    "wings_canary"
    "panel_canary;wings_canary"
    "uninstall_canary"
  )

  output "Que souhaitez-vous faire ?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Entrée 0-$((${#actions[@]} - 1)) : "
  read -r action

  [ -z "$action" ] && error "Une entrée est requise" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Option invalide"
  [[ " ${valid_input[*]} " =~ ${action} ]] && termine=true && IFS=";" read -r i1 i2 <<<"${actions[$action]}" && executer "$i1" "$i2"
done

# Supprime lib.sh, ainsi la prochaine exécution du script téléchargera la version la plus récente.
rm -rf /tmp/lib.sh