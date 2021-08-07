#!/bin/bash

### Note to anyone trying to edit:
### `main()` gets called at the end of this script.
### That's so we can setup helper functions like 'debug' and such at the end,
### Instead of cluttering things up here at the top.

# ---------------------------
# Environment Variables Setup 
# ---------------------------
DEBUG=1
STEP=1
DRIVER_VERSION="450.124"
VGPU_UNLOCK_PATH="/root/vgpu_unlock"
VGPU_UNLOCK_REPO="https://github.com/DualCoder/vgpu_unlock"
SELF_PATH=$PWD/${0##*/}
CRON_STARTFILE="/etc/cron.d/000_setup_sh"
# COMMSOCK=$PWD/setup-step$STEP.sock
if [[ -f $PWD/last_completed ]]; then
    LAST_COMPLETED_STEP=$(cat $PWD/last_completed)
else
    LAST_COMPLETED_STEP=0
fi

# ------------------------------------
# Parse arguments to overload defaults
# ------------------------------------

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    -s|--step)
      STEP="$2"
      shift # past argument
      shift # past value
      ;;
    -d|--debug)
      DEBUG="$2"
      shift # past argument
      shift # past value
      ;;
    -v|--driver-version)
      DRIVER_VERSION="$2"
      shift # past argument
      shift # past value
      ;;
    *)    # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done

# Systemd service files that need redirecting
SERVICE_FILES=(
    "/usr/lib/systemd/system/nvidia-vgpud.service" 
    "/usr/lib/nvidia/systemd/nvidia-vgpud.service" 
    "/usr/lib/systemd/system/nvidia-vgpu-mgr.service" 
    "/usr/lib/nvidia/systemd/nvidia-vgpu-mgr.service"
)

# Driver .run file
DRIVER_RUN_FILE="$PWD/NVIDIA-Linux-x86_64-$DRIVER_VERSION-vgpu-kvm.run"

# os-interface.c patch
HOOKS_AFTER='#include "nv-time.h"'
UNLOCK_HOOKS_PATH="$VGPU_UNLOCK_PATH/vgpu_unlock_hooks.c"
INTERFACE_FILE="/usr/src/nvidia-$DRIVER_VERSION/nvidia/os-interface.c"

# Kbuild patch
LDFLAGS_LINE="ldflags-y += -T $VGPU_UNLOCK_PATH/kern.ld"
KBUILD_FILE="/usr/src/nvidia-$DRIVER_VERSION/nvidia/nvidia.Kbuild"

if [[ ${DEBUG} = 0 ]]; then
    exec 3>&2
# elif [[ ${DEBUG} = 30 ]]; then
#     mkfifo -m 600 $COMMSOCK
#     exec 3>$COMMSOCK
else 
    exec 3>/dev/null
fi

# ------------------------------------------
# CALLED AT THE END OF SCRIPT TO DO THE WORK
# ------------------------------------------
main() {
    ensure_safety
    run_step $STEP
}

run_step() {
    # [[ $LAST_COMPLETED_STEP -lt $1 ]] || echocritical "We seem to be trying to repeat a completed step."

    step_$1
    echo $1 > $PWD/last_completed
    sed -i "/setup.sh/d" ~/.bashrc
}

step_1() {
    repository_setup
    dependency_installation
    reboot_step 2
}

step_2() {
    section_heading "Would run step 2 if we had one!"
}

step_3() {
    # update_service_files
    # patch_os_interface
    # patch_kbuild
    # reinstall_nvidia_kernel_module
    echo "bruh"
}

# --------------------------
# FUNCTIONS THAT DO THE WORK
# --------------------------

ensure_safety() {
    section_heading "Verifying install requirements"

    [[ -f "/usr/share/perl5/PVE/API2/Subscription.pm" ]] || echocritical "This script only supports Proxmox. Please make sure PVE is installed."
    echosuccess "Running on proxmox"

    [[ "6.4" == $(pveversion -v | grep pve-manager | awk '{print $2}' | sed 's/-/ /' | awk '{print $1}') ]] || echocritical "This script only supports proxmox 6.4."
    echosuccess "Proxmox version is 6.4"

    [[ -z $(qm list) ]] || echocritical "You don't want to run this script while VMs are running. It will reboot this host and cause problems."
    echosuccess "No running VMs"

    [[ -z $(pct list) ]] || echocritical "You don't want to run this script while CTs are running. It will reboot this and cause problems."
    echosuccess "No running containers"

    [[ $(whoami) == 'root' ]] || echocritical "Script must be run as root."
    echosuccess "Running as root"

    # [[ -f $DRIVER_RUN_FILE ]] || echocritical "No driver file at '$DRIVER_RUN_FILE'"
}

repository_setup() {
    section_heading "Ensuring repository configuration"
    substatus=$(pvesubscription get | grep status: | awk '{print $2}')
    if [ "$substatus" == "Found" ]; then
        echosuccess "You appear to already have a subscription, or a no-subscription patch."
        return 0;
    fi
    
    subscription_repo_file=/etc/apt/sources.list.d/pve-enterprise.list
    if [ -f "$subscription_repo_file" ]; then
        debug "$subscription_repo_file exists with no subscription!"
        debug "Moving $subscription_repo_file to be $subscription_repo_file.old"
        mv $subscription_repo_file "$subscription_repo_file.old" >&3 2>&3

        if [ $? -ne 0 ]
        then
            echofail "Could not move $subscription_repo_file to $subscription_repo_file.old. Got exit code '$?'"
        fi
    fi

    codename=$(cat /etc/os-release | grep VERSION_CODENAME | cut -d '=' -f2)
    nosubfile=/etc/apt/sources.list.d/pve-nosub.list
    if [[ ! -e $nosubfile ]] && [[ ! $(grep -q "/etc/apt/sources.list" "pve-no-subscription") ]]; then
        debug "Did not find pve-no-subscription repo, configuring it now by creating $nosubfile."
        echo "deb http://download.proxmox.com/debian/pve $codename pve-no-subscription" > $nosubfile 
        
        if [[ ! -e $nosubfile ]] && [[ ! $(grep -q "/etc/apt/sources.list" "pve-no-subscription") ]]; then
            echofail "Couldn't create a pve-no-subscription repo file for some reason!"
        fi
    fi

    echosuccess "Configured 'pve-no-subscription' repo. Applying no-nag patch..."
    result=$(curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/rickycodes/pve-no-subscription/main/no-subscription-warning.sh | sh)

    if [[ $result == *"patched"* ]] || [[ $result == *"all done"* ]]; then
        echosuccess "Patch applied."
        return 0;
    fi

    echofail "No-nag patch could not be applied."
}

dependency_installation() {
    section_heading "Installing dependencies..."

    apt_dependencies
    install_frida
    clone_vgpu_unlock
    install_mdevctl
}

apt_dependencies() {
    packages="python3 python3-pip git build-essential pve-headers dkms jq"
    missing=$(dpkg --get-selections $packages 2>&1 | grep -v 'install$' | awk '{ print $6 }')

    if [[ ! -z $missing ]]; then
        echosuccess "Installing missing packages '$missing'"
        apt update >&3 2>&3
        [[ $? -eq 0 ]] || 
        apt -y upgrade >&3 2>&3
        apt -y install $missing >&3 2>&3
    else
        echosuccess "No packages missing, all dependencies found."
    fi
}

install_frida() {
    frida_installed=$(pip3 list | grep -F frida)

    if [[ ! -z $frida_installed ]]; then
        pip3 install frida >&3 2>&3

        if [ $? -ne 0 ]; then
            echocritical "Couldn't install frida, got exit code $?"
        fi

        echosuccess "Successfully installed python module 'frida'"
    else
        echosuccess "Python module 'frida' is already installed."
    fi
}

clone_vgpu_unlock() {
    if [[ ! -e $VGPU_UNLOCK_PATH ]]; then
        git clone $VGPU_UNLOCK_REPO $VGPU_UNLOCK_PATH >&3 2>&3

        if [ $? -ne 0 ]; then
            echocritical "Er ... We couldn't 'git clone' the vgpu_unlock script. wat."
        fi
    fi

    original_dir=$PWD
    cd $VGPU_UNLOCK_PATH
    git checkout master >&3 2>&3
    git reset --hard origin/master >&3 2>&3
    chmod -R +x ./
    cd $original_dir

    echosuccess "$VGPU_UNLOCK_PATH is the latest version."

    line_number=$(($(awk '/Debug logs can be enabled here/{print NR}' $UNLOCK_HOOKS_PATH) + 1))

    if [ "$DEBUG" -lt "1" ]; then
        sed -i "$line_number"'s/.*/#if 1/' $UNLOCK_HOOKS_PATH >&3 2>&3
        echosuccess "Enabled debugging bit in $UNLOCK_HOOKS_PATH."
    else
        sed -i "$line_number"'s/.*/#if 0/' $UNLOCK_HOOKS_PATH >&3 2>&3
        echosuccess "Disabled debugging bit in $UNLOCK_HOOKS_PATH."
    fi
}

install_mdevctl() {
    if [[ -z $(dpkg -l | grep mdevctl) ]]; then
        [[ -f ./mdevctl_0.81-1_all.deb ]] || wget http://ftp.br.debian.org/debian/pool/main/m/mdevctl/mdevctl_0.81-1_all.deb >&3 2>&3
        dpkg -i mdevctl_0.81-1_all.deb >&3 2>&3

        [ $? -eq 0 ] || echocritical "Could not install mdevctl! Rerun with '--debug 0' to see more detail."

        echosuccess "mdevctl installed."
        return 0;
    fi
    
    echosuccess "mdevctl already installed"
}

update_service_files() {
    section_heading "Redirecting systemd service files"
    changed_a_file="0"

    for FILE in ${SERVICE_FILES[@]}
    do
        if ! grep -q "$VGPU_UNLOCK_PATH/vgpu_unlock" "$FILE"; then
            changed_a_file="1"

            sed -i "s#$VGPU_UNLOCK_PATH/vgpu_unlock ##g" $FILE
            sed -i "s#ExecStart=#ExecStart=$VGPU_UNLOCK_PATH/vgpu_unlock #" $FILE
            
            if ! grep -q "ExecStart=$VGPU_UNLOCK_PATH/vgpu_unlock /" "$FILE"; then
                red_echo $(print_divider);
                red_echo "Something doesn't seem right with $FILE."
                red_echo $(print_divider);

                red_echo "old: $(grep 'ExecStart=' $FILE)"
                red_echo "new: $(grep 'ExecStart=' $FILE)"
                echocritical "You're going to want to look at that a bit closer."
            fi

            debug $(print_divider)
            debug "New ExecStart in $FILE"
            debug "old: $(grep 'ExecStart=' $FILE)"
            debug "new: $(grep 'ExecStart=' $FILE)"
            debug $(print_divider)
            debug ""

        fi
    done

    if [ $changed_a_file -eq "1" ]; then
        echosuccess "systemd service files redirected"
        reload_systemd
    else
        echosuccess "systemd service files already redirected"
        echosuccess "no need to reload systemd"
    fi
}

reload_systemd() {
    systemctl daemon-reload >&3 2>&3

    if [ $? -gt 0 ]; then
        echocritical "systemctl daemon-reload failed"
    fi
    echosuccess "systemctl daemon-reload succeeded."
}

patch_os_interface() {
    section_heading "Updating $INTERFACE_FILE"
    if ! grep -q "\"$UNLOCK_HOOKS_PATH\"" "$INTERFACE_FILE"; then
        unlock_hooks_replace="$UNLOCK_HOOKS_PATH"
        echo "Did not find hooks in driver os-interface.c, adding."

        echo '1;/'"$HOOKS_AFTER"'/{ print "#include ""\042""'"$unlock_hooks_replace"'""\042"}'
        awk -i inplace '1;/'"$HOOKS_AFTER"'/{ print "#include ""\042""'"$unlock_hooks_replace"'""\042"}' $INTERFACE_FILE >&3 2>&3

        if ! grep -q "$UNLOCK_HOOKS_PATH" "$INTERFACE_FILE"; then
            echofail "$INTERFACE_FILE was not successfully patched."
        fi
        echosuccess "$INTERFACE_FILE successfully patched."
    else
        echosuccess "$INTERFACE_FILE appears to already be patched."
    fi

    if [ "$DEBUG" -lt "1" ]; then
        echo "(Debug) Confirm that you see '$UNLOCK_HOOKS_PATH' under '$HOOKS_AFTER' below:"

        print_divider
        grep -n -B 3 -A 2 --color "$UNLOCK_HOOKS_PATH" "$INTERFACE_FILE"
        print_divider

        confirm 'If the above looks good, press any key to continue.'
    fi
}

patch_kbuild() {
    section_heading "Updating $KBUILD_FILE"
    if ! grep -q "$LDFLAGS_LINE" "$KBUILD_FILE"; then
        echo "$LDFLAGS_LINE" >> "$KBUILD_FILE"

        if ! grep -q "$LDFLAGS_LINE" "$KBUILD_FILE"; then
            echocritical "Error patching kbuild file."
        fi

        echosuccess "kbuild file patched."
    else
        echosuccess "kbuild file appears to already be patched."
    fi
}

reinstall_nvidia_kernel_module() {
    status=$(dkms status)

    # We only want to try uninstalling it if it is, in fact, installed.
    # We also want to uninstall if another version is installed.
    # So find out the version installed and uninstall it.
    if [[ "$status" == *"nvidia"*"installed"* ]]; then
        section_heading "Removing existing kernel module".
        statusparts=(${status//", "/ })
        version=${statusparts[1]};

        dkms remove -m nvidia -v "$version" --all >&3 2>&3

        if [ $? -eq 0 ]; then
            echosuccess "nvidia dkms module version $version removed."
        else
            echocritical "Something went wrong while removing existing dkms driver version $version."
        fi
    fi

    # Ok, so we don't have one installed (or we uninstalled if we did)
    # Time to rebuild!
    section_heading "Rebuilding kernel module"

    dkms install nvidia -v "$DRIVER_VERSION" >&3 2>&3

    if [ $? -gt 0 ]; then
        errorlog="/var/lib/dkms/nvidia/$DRIVER_VERSION/build/make.log"
        echofail "Something went wrong building DKMS driver. Here's the output of $errorlog"
        cat "$errorlog"
        echocritical "Try again once you know how to fix it."
    fi

    echosuccess "nvidia dkms module installed."
}

# -----------------------
# HELPER FUNCTIONS
# -----------------------
debug() {
    if [ "$DEBUG" -lt "1" ]; then
        echo "$@"
    fi
}

red_echo() {
    echo -e "\x1b[1;31m$1\e[0m"
}

green_echo() {
    echo -e "\x1b[1;32m$1\e[0m"
}

echosuccess() {
    green_echo '☑ '"$@"
}

echofail() {
    red_echo '☒ '"$@"
}

echocritical() {
    echofail "$@"
    red_echo "---The above error is critical. Cannot continue.---"
    [ -f $CRON_STARTFILE ] && rm $CRON_STARTFILE
    [ -f  ]
    exit 1;
}

print_divider() {
    printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
}

divider_heading() {
    print_divider
    echo $1
    print_divider
}

bump() {
    reps=${1:-'1'}
    eval $(echo printf '"\n%0.s"' {1..$reps})
}

confirm() {
    read -rep "$1"$'\n'
}

section_heading() {
    len=`expr length "$1"`
    minlen='40'
    len=$(( $len > $minlen ? $len : $minlen ))
    headinglen=`expr $len + '1'`
    len=`expr $len + 3`

    bump
    OUTPUT=$(printf '%s%*s%s\n' '+' "$len" '+' '' | tr ' ' -)
    green_echo "$OUTPUT"
    # OUTPUT=$(printf '%s%*s%s\n' '|' "$len" '|' '' | tr ' ' ' ')
    # green_echo "$OUTPUT"
    OUTPUT=$(printf "| %-${headinglen}s|\n" "$1" | tr ' ' ' ')
    green_echo "$OUTPUT"
    # OUTPUT=$(printf '%s%*s%s\n' '|' "$len" '|' '' | tr ' ' ' ')
    # green_echo "$OUTPUT"
    OUTPUT=$(printf '%s%*s%s\n' '+' "$len" '+' '' | tr ' ' -)
    green_echo "$OUTPUT"
}

reboot_step() {
    # echo "@reboot " > /etc/cron.d/000_setup_sh
    echo "[[ \$- == *i* ]] && $SELF_PATH --driver-version '$DRIVER_VERSION' --step '$1' --debug $DEBUG" >> ~/.bashrc
    reboot
}

# Run the thing
main "$@"