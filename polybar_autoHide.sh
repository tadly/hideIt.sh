#!/usr/bin/env bash

# Default Variables.
dir=top
pxl=1
stp=1
polybarClass=polybar
nam=false

# Printing usage help.
function echo_help() {
    echo -e "\nA small script created for auto hiding polybar using hideIt.sh!\n"
    echo -e "Usage:\n\tHiding:\t\t ./script.sh -d [direction] -p [pixels] -s [steps] \n\tUnhiding:\t ./script -x 1\n\n"
    echo -e "\tYou can also give class name of bar using -b.\n"
    echo -e "Options:\n\n\t -d : \t In which direction the bar should hide (default: top) \n\t\t (top, bottom, left, right).\n"
    echo -e "\t -p : \tHow many pixels to show after hiding the bar (default: 1)."
    echo -e "\n\t -s : \tSteps in pixel used to move the window. The higher the value, the faster it will move (default: 1).\n"
    echo -e "\t -x : \tUnhides all bars. I don't know why but it takes an argument. Just do ./script -x 1\n"
    echo -e "\t -b : \tGive class name of bar to hide. Find using xprop"
    exit 1
}

# Unhiding all the hidden bars.
function unhide_all() {
    echo -e "\nUnhiding all bars...\n"
    pkill -f 'hideIt.sh'
    exit 1
}

# Taking user-defined values.
while getopts d:p:s:b:x:h flag
do
    case "${flag}" in
        d) dir=${OPTARG};;
        p) pxl=${OPTARG};;
        s) stp=${OPTARG};;
        b) bar=${OPTARG} nam=true;;
        x) unhide_all;;
        h) echo_help;;
    esac
done

if $nam; then
    # Finally hiding it.
    hideIt.sh -C $bar -d $dir -p $pxl --hover -s $stp > /dev/null 2>&1 &

    # Special config for bspwm
    # bspc config -m focused top_padding 2 &
else
    # Printing values to be used.
    echo -e "\nDirection: $dir"
    echo "Pixels: $pxl"
    echo -e "Steps: $stp \n"

    # Selecting Polybar to hide.
    echo "Click on active polybar instance."
    polybarClass=$(xprop | awk '/WM_CLASS/ {print $3}' | tr -d '",')
    echo -e "Polybar Class: $polybarClass \n"

    # Finally hiding it.
    hideIt.sh -C $polybarClass -d $dir -p $pxl --hover -s $stp > /dev/null 2>&1 &

    # Special config for bspwm
    # bspc config -m focused top_padding 2 &
fi

# You can setup sxhkd to turn the hiding feature on and off. For example:
# super + b
#   ./script -b polybar
# super + shift + b
#   ./script -x 1
#
# You can also do this in other WM's hotkey config.
