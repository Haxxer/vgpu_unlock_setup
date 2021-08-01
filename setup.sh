#!/bin/bash

# Set up environment
DRIVER_VERSION=${1:-"450.124"}
DEBUG=${2:-0}
VGPU_UNLOCK_PATH="/root/vgpu_unlock"

# Systemd service files that need redirecting
SERVICE_FILES=(
    "/usr/lib/systemd/system/nvidia-vgpud.service" 
    "/usr/lib/nvidia/systemd/nvidia-vgpud.service" 
    "/usr/lib/systemd/system/nvidia-vgpu-mgr.service" 
    "/usr/lib/nvidia/systemd/nvidia-vgpu-mgr.service"
)

# os-interface.c patch
HOOKS_AFTER='#include "nv-time.h"'
UNLOCK_HOOKS_PATH="$VGPU_UNLOCK_PATH/vgpu_unlock_hooks.c"
INTERFACE_FILE="/usr/src/nvidia-$DRIVER_VERSION/nvidia/os-interface.c"

# Kbuild patch
LDFLAGS_LINE="ldflags-y += -T $VGPU_UNLOCK_PATH/kern.ld"
KBUILD_FILE="/usr/src/nvidia-$DRIVER_VERSION/nvidia/nvidia.Kbuild"

# Called at the end of our script to do the work
main() {
    update_service_files
    patch_os_interface
    patch_kbuild
    reinstall_nvidia_kernel_module
}

# --------------------------
# FUNCTIONS THAT DO THE WORK
# --------------------------

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
                exit 1;
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
    systemctl daemon-reload

    if [ $? -gt 0 ]; then
        echofail "systemctl daemon-reload failed"
        exit 1;
    fi
    echosuccess "systemctl daemon-reload succeeded."
}

patch_os_interface() {
    section_heading "Updating $INTERFACE_FILE"
    if ! grep -q "\"$UNLOCK_HOOKS_PATH\"" "$INTERFACE_FILE"; then
        unlock_hooks_replace="$UNLOCK_HOOKS_PATH"
        echo "Did not find hooks in driver os-interface.c, adding."

        echo '1;/'"$HOOKS_AFTER"'/{ print "#include ""\042""'"$unlock_hooks_replace"'""\042"}'
        awk -i inplace '1;/'"$HOOKS_AFTER"'/{ print "#include ""\042""'"$unlock_hooks_replace"'""\042"}' $INTERFACE_FILE

        if ! grep -q "$UNLOCK_HOOKS_PATH" "$INTERFACE_FILE"; then
            echofail "$INTERFACE_FILE was not successfully patched."
        fi
        echosuccess "$INTERFACE_FILE successfully patched."
    else
        echosuccess "$INTERFACE_FILE appears to already be patched."
    fi

    if [ "$DEBUG" -eq "1" ]; then
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
            echofail "Error patching kbuild file."
            exit 1;
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

        if [ "$DEBUG" -eq "1" ]; then
            dkms remove -m nvidia -v "$version" --all
        else
            dkms remove -m nvidia -v "$version" --all > /dev/null
        fi

        if [ $? -eq 0 ]; then
            echosuccess "nvidia dkms module version $version removed."
        else
            echofail "Something went wrong while removing existing dkms driver version $version."
            exit 1;
        fi
    fi

    # Ok, so we don't have one installed (or we uninstalled if we did)
    # Time to rebuild!
    section_heading "Rebuilding kernel module"

    if [ "$DEBUG" -eq "1" ]; then
        dkms install nvidia -v "$DRIVER_VERSION"
    else
        dkms install nvidia -v "$DRIVER_VERSION" > /dev/null
    fi

    if [ $? -gt 0 ]; then
        errorlog="/var/lib/dkms/nvidia/450.124/build/make.log"
        echofail "Something went wrong building DKMS driver. Here's the output of $errorlog"
        cat "$errorlog"
        exit 1;
    fi

    echosuccess "nvidia dkms module installed."
}

# -----------------------
# HELPER FUNCTIONS
# -----------------------
debug() {
    if [ "$DEBUG" -eq "1" ]; then
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

# Run the thing
main "$@"